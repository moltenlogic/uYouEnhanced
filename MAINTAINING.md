# Maintaining this fork (no coding needed)

This is a hardened copy of arichornlover/uYouEnhanced.

## What's different from upstream
- uYou is downloaded from MiRO92's official server and **checked against a fixed fingerprint**
  (`Tools/uyou-sha256.txt`). Upstream used a Dropbox copy that was really 3.0.3 relabelled as 3.0.5.
- The YouTube IPA you supply is **proved genuine** before building (`Tools/verify_ipa.py`):
  Apple's App Store signature, Google's team ID, and a hash of every code page and file.
  If the download site tampered with even one byte, the build stops.
- Build tools are pinned to exact versions so they can't silently change.

## Build a new version
1. Get a decrypted YouTube IPA download link (decrypt.day).
2. GitHub app or website > this repo > **Actions** > **Build and Release uYouEnhanced** > **Run workflow**.
3. Paste the link into "Direct URL of the decrypted YouTube IPA". Leave the rest as is.
4. Wait (first run up to 90 min, later ~15 min). If the "Verify YouTube IPA" step is red, the IPA is
   not genuine - don't use it, get it elsewhere.
5. **Releases** > open the newest draft > download the `.ipa` > open with SideStore.

Drafts are private to you. Don't publish them (that would share YouTube's app publicly).

## Get upstream updates
GitHub repo page > **Sync fork**. If it reports conflicts, ask Hermes to merge them.
