// FeedFilters.xm
//
// Diagnostics only: logs a short summary of every feed section (class + EML template ids)
// to the uYouEnhanced debug log, so shelves like "Most relevant" can be identified from an
// export. It does not modify the feed.
//
// It used to remove Shorts / "Most relevant" items itself, by mutating section contents and
// rewriting _sectionRenderers via KVC on top of uYouPlus.xm's own filteredShortsArray hook on
// the same methods. That double filtering after layout is the main suspect for the
// Subscriptions tab bouncing back to Home and for glitchy scrolling, so it was removed.
// Shorts hiding is left to uYou + uYouPlus.xm (hideShortsCells), which works on its own.

#import "uYouPlus.h"
#import "UYTLog.h"

static NSInteger gUYTFeedLogBudget = 400;
static NSInteger gUYTFeedHeadBudget = 30;

static NSString *UYTFeedEmlIds(NSString *desc) {
    if (desc.length == 0) return @"";
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"[A-Za-z0-9_\\-\\.]+\\.eml[A-Za-z0-9_\\-\\.]*" options:0 error:nil];
    });
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
    NSUInteger limit = MIN(desc.length, (NSUInteger)20000);
    [re enumerateMatchesInString:desc options:0 range:NSMakeRange(0, limit) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        [ids addObject:[desc substringWithRange:m.range]];
        if (ids.count >= 8) *stop = YES;
    }];
    return [ids.array componentsJoinedByString:@","];
}

// Header-ish sections are where a "Most relevant" title would live. Dump a slice of their
// description so the real identifier shows up in the log.
static BOOL UYTDescLooksLikeHeader(NSString *d) {
    return [d rangeOfString:@"relevant" options:NSCaseInsensitiveSearch].location != NSNotFound
        || [d containsString:@"header"]
        || [d containsString:@"Header"];
}

static void UYTFeedLog(NSArray *sections, NSString *where) {
    if (gUYTFeedLogBudget <= 0 || ![sections isKindOfClass:[NSArray class]] || sections.count == 0) return;
    gUYTFeedLogBudget--;
    UYTDebugInfo(@"[Feed] %@: %lu section(s)", where, (unsigned long)sections.count);

    NSUInteger idx = 0;
    for (id section in sections) {
        idx++;
        if (gUYTFeedLogBudget <= 0) return;
        gUYTFeedLogBudget--;
        NSString *desc = [section description] ?: @"";
        NSString *items = @"";
        if ([section isKindOfClass:%c(YTIItemSectionRenderer)]) {
            NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
            for (YTIItemSectionSupportedRenderers *item in ((YTIItemSectionRenderer *)section).contentsArray) {
                NSString *itemIds = UYTFeedEmlIds([item.elementRenderer description] ?: [item description]);
                if (itemIds.length) [ids addObject:itemIds];
            }
            items = [NSString stringWithFormat:@" items=%lu [%@]", (unsigned long)((YTIItemSectionRenderer *)section).contentsArray.count,
                     [ids.array componentsJoinedByString:@" | "]];
        }
        UYTDebugInfo(@"[Feed]   s%lu %@ len=%lu ids=[%@]%@", (unsigned long)idx, NSStringFromClass([section class]),
                     (unsigned long)desc.length, UYTFeedEmlIds(desc), items);
        if (gUYTFeedHeadBudget > 0 && UYTDescLooksLikeHeader(desc)) {
            gUYTFeedHeadBudget--;
            UYTDebugInfo(@"[Feed]   s%lu head: %@", (unsigned long)idx,
                         [[desc substringToIndex:MIN(desc.length, (NSUInteger)1500)] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
        }
    }
}

%hook YTInnerTubeCollectionViewController

- (void)addSectionsFromArray:(NSArray *)array {
    UYTFeedLog(array, NSStringFromClass([self class]));
    %orig;
}

%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"hideShortsCells"] == nil) {
        [defaults setBool:YES forKey:@"hideShortsCells"];
    }
    %init;
}
