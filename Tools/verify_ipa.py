#!/usr/bin/env python3
"""
verify_ipa.py - prove a decrypted YouTube IPA is Google's original, byte for byte.

How it works (no trust in the download site needed):
  * Every App Store binary carries Apple's signature (CMS) over a "CodeDirectory".
  * The CodeDirectory holds a SHA-256 hash of every 4/16 KB page of the code,
    plus hashes of Info.plist and _CodeSignature/CodeResources.
  * CodeResources holds a hash of every other file in the app.
  * Decrypting only flips one field (cryptid 1 -> 0). We flip it back in
    memory, then re-hash every page. A single changed byte anywhere = FAIL.

Checks:
  1. Apple signature valid, chains to the pinned Apple Root CA.
  2. Leaf certificate is "Apple iPhone OS Application Signing" (App Store
     only - a developer certificate would NOT pass).
  3. Team ID is Google's (EQHXZ8M8AV) for every executable.
  4. Every code page, Info.plist, CodeResources and every resource file match.
  5. No extra/unsealed files (except FairPlay SC_Info, which is expected).

Usage:  python3 verify_ipa.py YouTube.ipa      (exit code 0 = genuine)
Needs:  pip install cryptography asn1crypto
"""
import hashlib
import os
import plistlib
import re
import struct
import sys
import tempfile
import zipfile

from asn1crypto import cms, x509 as ax509
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa

APPLE_ROOT_SHA256 = "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024"
APP_STORE_LEAF_CN = "Apple iPhone OS Application Signing"
EXPECTED_TEAM = os.environ.get("EXPECTED_TEAM_ID", "EQHXZ8M8AV")  # Google LLC

LC_CODE_SIGNATURE = 0x1D
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSSLOT_CODEDIRECTORY = 0
CSSLOT_ALTERNATE_FIRST = 0x1000
CSSLOT_SIGNATURESLOT = 0x10000
HASH_FUNCS = {1: hashlib.sha1, 2: hashlib.sha256, 3: hashlib.sha256, 4: hashlib.sha384}
HASH_NAMES = {1: "sha1", 2: "sha256", 3: "sha256-trunc", 4: "sha384"}
OID_CDHASHES_PLIST = "1.2.840.113635.100.9.1"


class VerifyError(Exception):
    pass


problems = []
notes = []


def fail(msg):
    problems.append(msg)
    print("  FAIL  " + msg)


# ---------------------------------------------------------------- Mach-O
def macho_slices(data):
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        n = struct.unpack(">I", data[4:8])[0]
        out = []
        for i in range(n):
            if magic == 0xCAFEBABE:
                cpu, sub, off, size, align = struct.unpack(">5I", data[8 + i * 20: 28 + i * 20])
            else:
                cpu, sub, off, size, align, _ = struct.unpack(">2I2Q2I", data[8 + i * 32: 40 + i * 32])
            out.append((off, size))
        return out
    return [(0, len(data))]


def is_macho(path):
    try:
        with open(path, "rb") as f:
            m = f.read(4)
    except OSError:
        return False
    return m in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")


def parse_slice(sl):
    magic = struct.unpack("<I", sl[:4])[0]
    if magic == 0xFEEDFACF:
        hdr = 32
    elif magic == 0xFEEDFACE:
        hdr = 28
    else:
        raise VerifyError("not a little-endian Mach-O slice")
    ncmds = struct.unpack("<I", sl[16:20])[0]
    off = hdr
    sig = None
    crypt = None
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", sl[off:off + 8])
        if cmd == LC_CODE_SIGNATURE:
            sig = struct.unpack("<II", sl[off + 8:off + 16])
        elif cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
            cryptoff, cryptsize, cryptid = struct.unpack("<III", sl[off + 8:off + 20])
            crypt = (off + 16, cryptid, cryptoff, cryptsize)
        off += size
    if not sig:
        raise VerifyError("no code signature")
    return sig, crypt


def parse_cd(blob):
    (magic, length, version, flags, hash_off, ident_off, n_special, n_code,
     code_limit, hash_size, hash_type, platform, page_log2) = struct.unpack(">IIIIIIIIIBBBB", blob[:40])
    if magic != CSMAGIC_CODEDIRECTORY:
        raise VerifyError("bad CodeDirectory magic")
    team = None
    if version >= 0x20200:
        team_off = struct.unpack(">I", blob[48:52])[0]
        if team_off:
            team = blob[team_off:blob.index(b"\0", team_off)].decode()
    if version >= 0x20300 and len(blob) >= 64:
        code_limit_64 = struct.unpack(">Q", blob[56:64])[0]
        if code_limit_64:
            code_limit = code_limit_64
    ident = blob[ident_off:blob.index(b"\0", ident_off)].decode()
    return dict(version=version, hash_off=hash_off, n_special=n_special, n_code=n_code,
                code_limit=code_limit, hash_size=hash_size, hash_type=hash_type,
                page_size=(1 << page_log2) if page_log2 else 0, ident=ident, team=team,
                blob=blob)


def cd_slot(cd, slot):
    """slot >= 0 code page, slot < 0 special slot."""
    start = cd["hash_off"] + slot * cd["hash_size"]
    return cd["blob"][start:start + cd["hash_size"]]


# ---------------------------------------------------------------- CMS
def _verify_sig(pubkey, signature, data, hash_algo):
    h = {"sha1": hashes.SHA1(), "sha256": hashes.SHA256(), "sha384": hashes.SHA384(),
         "sha512": hashes.SHA512()}[hash_algo]
    if isinstance(pubkey, rsa.RSAPublicKey):
        pubkey.verify(signature, data, padding.PKCS1v15(), h)
    elif isinstance(pubkey, ec.EllipticCurvePublicKey):
        pubkey.verify(signature, data, ec.ECDSA(h))
    else:
        raise VerifyError("unsupported key type")


def verify_cms(cms_der, cd0_blob):
    """Returns set of trusted truncated (20-byte) cdhashes."""
    ci = cms.ContentInfo.load(cms_der)
    sd = ci["content"]
    certs = [c.chosen for c in sd["certificates"]]
    si = sd["signer_infos"][0]
    digest_algo = si["digest_algorithm"]["algorithm"].native
    attrs = si["signed_attrs"]
    md = None
    cdhashes = []
    for a in attrs:
        t = a["type"].dotted
        if a["type"].native == "message_digest":
            md = a["values"][0].native
        elif t == OID_CDHASHES_PLIST:
            pl = plistlib.loads(a["values"][0].native)
            cdhashes = [bytes(h) for h in pl.get("cdhashes", [])]
    if md is None:
        raise VerifyError("CMS has no messageDigest")
    if hashlib.new(digest_algo, cd0_blob).digest() != md:
        raise VerifyError("Apple signature does not cover this CodeDirectory (modified)")

    # signer cert
    sid = si["sid"].chosen
    leaf = None
    for c in certs:
        if c.serial_number == sid["serial_number"].native and c.issuer == sid["issuer"]:
            leaf = c
    if leaf is None:
        raise VerifyError("signer certificate missing")
    signed_data = attrs.dump(force=True)
    signed_data = b"\x31" + signed_data[1:]  # IMPLICIT [0] -> SET OF for signing
    sig_algo = si["signature_algorithm"].signature_algo
    leaf_c = x509.load_der_x509_certificate(leaf.dump())
    try:
        _verify_sig(leaf_c.public_key(), si["signature"].native, signed_data, digest_algo)
    except InvalidSignature:
        raise VerifyError("Apple signature is invalid")

    # chain up to pinned root
    cn = leaf.subject.native.get("common_name", "")
    if cn != APP_STORE_LEAF_CN:
        raise VerifyError("not an App Store signature (leaf is %r)" % cn)
    by_subject = {c.subject.dump(): c for c in certs}
    cur = leaf
    for _ in range(5):
        if cur.self_signed in ("maybe", "yes") and cur.subject == cur.issuer:
            fp = hashlib.sha256(cur.dump()).hexdigest()
            if fp != APPLE_ROOT_SHA256:
                raise VerifyError("chain does not end at Apple Root CA")
            break
        issuer = by_subject.get(cur.issuer.dump())
        if issuer is None:
            raise VerifyError("incomplete certificate chain")
        ic = x509.load_der_x509_certificate(issuer.dump())
        cc = x509.load_der_x509_certificate(cur.dump())
        try:
            _verify_sig(ic.public_key(), cc.signature, cc.tbs_certificate_bytes,
                        cc.signature_hash_algorithm.name)
        except InvalidSignature:
            raise VerifyError("certificate chain signature invalid")
        cur = issuer
    else:
        raise VerifyError("certificate chain too long")
    return set(cdhashes), digest_algo


# ---------------------------------------------------------------- binary check
def verify_macho(path, label):
    data = open(path, "rb").read()
    trusted_cdhashes = set()
    for (soff, ssize) in macho_slices(data):
        sl = bytearray(data[soff:soff + ssize])
        (sigoff, sigsize), crypt = parse_slice(sl)
        sb = bytes(sl[sigoff:sigoff + sigsize])
        magic, length, count = struct.unpack(">III", sb[:12])
        if magic != CSMAGIC_EMBEDDED_SIGNATURE:
            raise VerifyError("bad signature superblob")
        cds, cms_der = [], None
        for i in range(count):
            typ, off = struct.unpack(">II", sb[12 + i * 8:20 + i * 8])
            blen = struct.unpack(">I", sb[off + 4:off + 8])[0]
            blob = sb[off:off + blen]
            if typ == CSSLOT_CODEDIRECTORY or CSSLOT_ALTERNATE_FIRST <= typ < CSSLOT_ALTERNATE_FIRST + 5:
                cds.append((typ, parse_cd(blob)))
            elif typ == CSSLOT_SIGNATURESLOT:
                cms_der = blob[8:]
        if not cms_der or len(cms_der) < 16:
            raise VerifyError("unsigned (no Apple signature)")
        cd0 = [cd for t, cd in cds if t == CSSLOT_CODEDIRECTORY][0]
        listed, _ = verify_cms(cms_der, cd0["blob"])
        trusted = [cd0]
        for t, cd in cds:
            if t == CSSLOT_CODEDIRECTORY:
                continue
            h = HASH_FUNCS[cd["hash_type"]](cd["blob"]).digest()[:20]
            if h in listed:
                trusted.append(cd)
        best = max(trusted, key=lambda c: c["hash_size"])
        for cd in trusted:
            trusted_cdhashes.add(HASH_FUNCS[cd["hash_type"]](cd["blob"]).digest()[:20])
        if EXPECTED_TEAM and best["team"] != EXPECTED_TEAM:
            raise VerifyError("team ID %r is not Google's (%s)" % (best["team"], EXPECTED_TEAM))

        # restore cryptid for hashing (decrypters set it to 0)
        variants = [bytes(sl)]
        if crypt and crypt[1] == 0:
            patched = bytearray(sl)
            struct.pack_into("<I", patched, crypt[0], 1)
            variants.insert(0, bytes(patched))
        hf = HASH_FUNCS[best["hash_type"]]
        ps = best["page_size"]
        bad = 0
        for i in range(best["n_code"]):
            s, e = i * ps, min((i + 1) * ps, best["code_limit"])
            want = cd_slot(best, i)
            if not any(hf(v[s:e]).digest()[:best["hash_size"]] == want for v in variants):
                bad += 1
        if bad:
            raise VerifyError("%d of %d code pages differ from Google's original" % (bad, best["n_code"]))
        enc = "decrypted" if crypt and crypt[1] == 0 else ("ENCRYPTED" if crypt and crypt[1] else "plain")
        print("  OK    %-45s %s  %d pages %s  team %s  [%s]" % (
            label, best["ident"], best["n_code"], HASH_NAMES[best["hash_type"]], best["team"], enc))
        if crypt and crypt[1] != 0:
            notes.append("%s is still encrypted - this IPA is NOT decrypted and won't run sideloaded" % label)
    return best, trusted_cdhashes


# ---------------------------------------------------------------- bundle check
def file_hash(path, algo):
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.digest()


def verify_bundle(bundle, label):
    info_path = os.path.join(bundle, "Info.plist")
    info = plistlib.load(open(info_path, "rb"))
    exe_name = info["CFBundleExecutable"]
    exe = os.path.join(bundle, exe_name)
    try:
        cd, own_hashes = verify_macho(exe, label + "/" + exe_name)
    except VerifyError as e:
        fail("%s/%s: %s" % (label, exe_name, e))
        return set()
    hf = HASH_FUNCS[cd["hash_type"]]
    hs = cd["hash_size"]
    if cd["n_special"] >= 1 and hf(open(info_path, "rb").read()).digest()[:hs] != cd_slot(cd, -1):
        fail(label + "/Info.plist modified")
    cr_path = os.path.join(bundle, "_CodeSignature", "CodeResources")
    if hf(open(cr_path, "rb").read()).digest()[:hs] != cd_slot(cd, -3):
        fail(label + "/_CodeSignature/CodeResources modified")
        return set()
    cr = plistlib.load(open(cr_path, "rb"))
    files2 = cr.get("files2", {})
    omit_rules = [re.compile(k) for k, v in cr.get("rules2", {}).items()
                  if isinstance(v, dict) and v.get("omit")]

    nested_dirs = set()
    for rel, entry in files2.items():
        full = os.path.join(bundle, rel)
        if isinstance(entry, dict) and "cdhash" in entry:
            if os.path.isdir(full):
                nested_dirs.add(rel)
                got = verify_bundle(full, label + "/" + rel)
            else:
                try:
                    _, got = verify_macho(full, label + "/" + rel)
                except VerifyError as e:
                    fail("%s/%s: %s" % (label, rel, e))
                    continue
            if bytes(entry["cdhash"]) not in got:
                fail("%s/%s: nested code differs from what Google sealed" % (label, rel))
            continue
        if isinstance(entry, dict) and "symlink" in entry:
            if not os.path.islink(full) or os.readlink(full) != entry["symlink"]:
                fail("%s/%s: symlink changed" % (label, rel))
            continue
        if not os.path.exists(full):
            if not (isinstance(entry, dict) and entry.get("optional")):
                fail("%s/%s: missing" % (label, rel))
            continue
        if isinstance(entry, dict):
            if "hash2" in entry:
                ok = file_hash(full, "sha256") == bytes(entry["hash2"])
            else:
                ok = file_hash(full, "sha1") == bytes(entry["hash"])
        else:
            ok = file_hash(full, "sha1") == bytes(entry)
        if not ok:
            fail("%s/%s: content modified" % (label, rel))

    # look for extra, unsealed files
    for root, dirs, files in os.walk(bundle):
        relroot = os.path.relpath(root, bundle)
        relroot = "" if relroot == "." else relroot + "/"
        dirs[:] = [d for d in dirs if (relroot + d) not in nested_dirs]
        for fn in files:
            rel = relroot + fn
            if rel in files2 or rel in (exe_name, "_CodeSignature/CodeResources"):
                continue
            if rel.startswith("SC_Info/"):
                continue  # FairPlay data, expected in App Store downloads
            if any(r.search(rel) for r in omit_rules):
                continue
            full = os.path.join(root, fn)
            if is_macho(full):
                fail("%s/%s: EXTRA executable code not from Google" % (label, rel))
            else:
                fail("%s/%s: extra file not sealed by Google" % (label, rel))
    return _cdhashes_of(exe)


def _cdhashes_of(exe):
    try:
        return verify_macho_quiet(exe)
    except VerifyError:
        return set()


def verify_macho_quiet(exe):
    import io, contextlib
    with contextlib.redirect_stdout(io.StringIO()):
        _, h = verify_macho(exe, "")
    return h


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    src = sys.argv[1]
    tmp = None
    if os.path.isfile(src):
        tmp = tempfile.mkdtemp(prefix="verify_ipa_")
        with zipfile.ZipFile(src) as z:
            for n in z.namelist():
                if ".." in n.split("/"):
                    print("FAIL: unsafe path in IPA: " + n)
                    sys.exit(1)
            z.extractall(tmp)
        root = tmp
    else:
        root = src
    payload = os.path.join(root, "Payload")
    apps = [d for d in os.listdir(payload) if d.endswith(".app")]
    if len(apps) != 1:
        print("FAIL: expected exactly one .app in Payload, found %r" % apps)
        sys.exit(1)
    app = os.path.join(payload, apps[0])
    info = plistlib.load(open(os.path.join(app, "Info.plist"), "rb"))
    print("Checking %s %s (%s)" % (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"),
                                   apps[0]))
    extra_top = [d for d in os.listdir(payload) if d != apps[0] and not d.startswith(".")]
    for d in extra_top:
        fail("Payload/%s: extra item next to the app" % d)
    verify_bundle(app, apps[0])
    print()
    for n in notes:
        print("NOTE: " + n)
    if problems:
        print("RESULT: NOT GENUINE - %d problem(s). Do not use this IPA." % len(problems))
        sys.exit(1)
    if any("still encrypted" in n for n in notes):
        print("RESULT: genuine Google code, but still encrypted - unusable for sideloading.")
        sys.exit(3)
    print("RESULT: GENUINE - every byte of code and every file matches Google's App Store release.")
    sys.exit(0)


if __name__ == "__main__":
    main()
