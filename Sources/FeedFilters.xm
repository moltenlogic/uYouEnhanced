// FeedFilters.xm
//
// Item-level feed filtering for the Subscriptions feed (and any other InnerTube feed):
//   - Shorts shelf   (uYou's "hideShortsCells" switch)
//   - "Most relevant" shelf (kHideMostRelevant)
//
// uYou's own filter (uYouPlus.xm filteredShortsArray) works on whole sections and only knows
// the older identifiers, so the 21.x Subscriptions shelves slip through. This filter removes
// individual items inside YTIItemSectionRenderer sections and drops a section only if it ends
// up empty, so normal videos sharing a section are never lost.
//
// It also logs a short summary of every feed section (class + EML template ids) to the
// uYouEnhanced debug log, so shelves YouTube renames later can be identified from an export.

#import "uYouPlus.h"
#import "UYTLog.h"

static NSInteger gUYTFeedLogBudget = 400;

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

static BOOL UYTDescIsShorts(NSString *d) {
    return [d containsString:@"shorts_shelf"]
        || [d containsString:@"shorts_video_cell"]
        || [d containsString:@"shorts_grid"]
        || [d containsString:@"shorts_lockup"]
        || [d containsString:@"reel_shelf"]
        || [d containsString:@"reel_item"]
        || [d containsString:@"ShortsLockupView"];
}

static BOOL UYTDescIsMostRelevant(NSString *d) {
    return [d containsString:@"Most relevant"]
        || [d containsString:@"most_relevant"]
        || [d containsString:@"MostRelevant"];
}

typedef NS_ENUM(NSInteger, UYTFeedVerdict) { UYTFeedKeep, UYTFeedShorts, UYTFeedMostRelevant };

static UYTFeedVerdict UYTFeedJudge(NSString *desc, BOOL hideShorts, BOOL hideMostRelevant) {
    if (hideShorts && UYTDescIsShorts(desc)) return UYTFeedShorts;
    if (hideMostRelevant && UYTDescIsMostRelevant(desc)) return UYTFeedMostRelevant;
    return UYTFeedKeep;
}

static NSArray *UYTFeedFilter(NSArray *sections, NSString *where) {
    if (![sections isKindOfClass:[NSArray class]] || sections.count == 0) return sections;
    BOOL hideShorts = IS_ENABLED(@"hideShortsCells");
    BOOL hideMostRelevant = IS_ENABLED(kHideMostRelevant);
    BOOL logging = gUYTFeedLogBudget > 0;
    if (!hideShorts && !hideMostRelevant && !logging) return sections;

    if (logging) {
        gUYTFeedLogBudget--;
        UYTDebugInfo(@"[Feed] %@: %lu section(s) shorts=%d mostRelevant=%d", where, (unsigned long)sections.count, hideShorts, hideMostRelevant);
    }

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:sections.count];
    NSUInteger idx = 0;
    for (id section in sections) {
        idx++;
        NSString *desc = [section description] ?: @"";

        if ([section isKindOfClass:%c(YTIItemSectionRenderer)]) {
            YTIItemSectionRenderer *itemSection = section;
            NSMutableArray *contents = itemSection.contentsArray;
            NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];
            [contents enumerateObjectsUsingBlock:^(YTIItemSectionSupportedRenderers *item, NSUInteger i, BOOL *stop) {
                NSString *itemDesc = [item.elementRenderer description] ?: [item description] ?: @"";
                UYTFeedVerdict v = UYTFeedJudge(itemDesc, hideShorts, hideMostRelevant);
                if (gUYTFeedLogBudget > 0) {
                    gUYTFeedLogBudget--;
                    UYTDebugInfo(@"[Feed]   s%lu.i%lu ids=[%@] mr=%d -> %@", (unsigned long)idx, (unsigned long)i,
                                 UYTFeedEmlIds(itemDesc), UYTDescIsMostRelevant(itemDesc),
                                 v == UYTFeedKeep ? @"keep" : (v == UYTFeedShorts ? @"HIDE shorts" : @"HIDE most-relevant"));
                }
                if (v != UYTFeedKeep) [drop addIndex:i];
            }];
            if (drop.count > 0) {
                [contents removeObjectsAtIndexes:drop];
                if (contents.count == 0) continue;
            }
            [out addObject:section];
            continue;
        }

        UYTFeedVerdict v = UYTFeedJudge(desc, hideShorts, hideMostRelevant);
        if (gUYTFeedLogBudget > 0) {
            gUYTFeedLogBudget--;
            UYTDebugInfo(@"[Feed]   s%lu %@ ids=[%@] mr=%d -> %@", (unsigned long)idx, NSStringFromClass([section class]),
                         UYTFeedEmlIds(desc), UYTDescIsMostRelevant(desc), v == UYTFeedKeep ? @"keep" : @"HIDE");
        }
        if (v == UYTFeedKeep) [out addObject:section];
    }
    return out;
}

%hook YTInnerTubeCollectionViewController

- (void)addSectionsFromArray:(NSArray *)array {
    %orig(UYTFeedFilter(array, NSStringFromClass([self class])));
}

- (void)displaySectionsWithReloadingSectionControllerByRenderer:(id)renderer {
    NSArray *sections = [self valueForKey:@"_sectionRenderers"];
    if ([sections isKindOfClass:[NSArray class]]) {
        NSArray *filtered = UYTFeedFilter(sections, [NSStringFromClass([self class]) stringByAppendingString:@"(display)"]);
        if (filtered.count != sections.count) {
            [self setValue:[filtered mutableCopy] forKey:@"_sectionRenderers"];
        }
    }
    %orig;
}

%end

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kHideMostRelevant] == nil) {
        [defaults setBool:YES forKey:kHideMostRelevant];
    }
    if ([defaults objectForKey:@"hideShortsCells"] == nil) {
        [defaults setBool:YES forKey:@"hideShortsCells"];
    }
    %init;
}
