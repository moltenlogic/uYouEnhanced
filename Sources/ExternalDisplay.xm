// ExternalDisplay.xm
//
// Keep YouTube video playing on a wired external display (e.g. Xreal glasses over
// USB-C DisplayPort) while the phone is locked.
//
// How VLC for iOS does it (VLCNonInteractiveWindowSceneDelegate + VLCPlaybackService):
//   1. Info.plist declares a UIWindowSceneSessionRoleExternalDisplayNonInteractive scene,
//      so iOS gives the app its own scene on the external display instead of mirroring.
//   2. The video output view is moved into a window on that scene.
//   3. On background/lock, playback is not stopped while an external window exists.
//      The external scene keeps rendering while the phone is locked; mirroring does not.
//
// YouTube 21.x already contains a dormant version of step 2: YTHDMIServiceImpl moves the
// player's renderingView into a second window ("fullscreen HDMI playback"). It is gated
// behind the server hot-config flag fullscreenHdmiHamplayer, and it uses the legacy
// -[UIWindow setScreen:] API, which does nothing in a scene-based app. So we:
//   - add the external display scene (Info.plist patch in the build workflow + the
//     UYTExternalSceneDelegate class below),
//   - force the flag on, point the service at our scene's screen and attach its window
//     to our scene,
//   - stop MLHAMQueuePlayer dropping its video renderer when the app backgrounds while
//     the video is on the external display.
//
// The external scene is also requested in code via -[YTAppDelegate
// application:configurationForConnectingSceneSession:options:] (as VLCAppDelegate does), so it
// does not depend only on the Info.plist patch surviving re-signing.

#import "uYouPlus.h"
#import "UYTLog.h"
#import <objc/runtime.h>
#import <YouTubeHeader/YTHotConfig.h>

@interface YTHotConfig (UYTExternalDisplay)
- (BOOL)iosClientGlobalConfigFullscreenHdmiHamplayer;
@end

@interface YTHotConfigIosClientGlobalConfigImpl : NSObject
- (BOOL)fullscreenHdmiHamplayer;
@end

@interface YTHDMIServiceImpl : NSObject
- (void)prepareIfNeeded;
- (void)enableHDMIPlayback:(id)playbackController;
- (void)disableHDMIPlayback;
- (BOOL)setViewToMirror:(id)view playbackController:(id)playbackController;
- (void)stopMirroring;
- (void)detectExternalScreen;
@end

@interface YTHDMIServicePlaybackObserverImpl : NSObject
- (void)observePlaybackController:(id)controller;
- (void)playerViewController:(id)controller didActivateVideo:(id)video;
@end

@interface MLHAMQueuePlayer (UYTExternalDisplay)
- (void)appDidEnterBackground;
@end

static __weak UIWindowScene *gUYTExtScene;
static __weak YTHDMIServiceImpl *gUYTHDMIService;
static __weak id gUYTLastPlayerViewController;

static BOOL UYTExtEnabled(void) {
    return IS_ENABLED(kExternalDisplayPlayback);
}

static id UYTGetIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    return iv ? object_getIvar(obj, iv) : nil;
}

static void UYTSetIvar(id obj, const char *name, id value) {
    if (!obj) return;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (iv) object_setIvar(obj, iv, value);
}

static BOOL UYTExtMirroring(void) {
    return UYTGetIvar(gUYTHDMIService, "_secondWindow") != nil;
}

static BOOL UYTExtPlaybackActive(void) {
    return UYTExtEnabled() && gUYTExtScene != nil && UYTExtMirroring();
}

// Move the current video onto the external scene if everything is ready.
// Called when the scene connects (glasses plugged in mid-video).
static void UYTExtAttach(void) {
    if (!UYTExtEnabled() || !gUYTExtScene) return;
    YTHDMIServiceImpl *svc = gUYTHDMIService;
    if (!svc) {
        UYTDebugWarn(@"[ExternalDisplay] scene connected but YTHDMIServiceImpl not created yet; will attach on next video");
        return;
    }
    [svc prepareIfNeeded];
    [svc detectExternalScreen];
    id pvc = gUYTLastPlayerViewController;
    if (pvc && !UYTExtMirroring()) {
        UYTDebugInfo(@"[ExternalDisplay] moving current video to external display");
        [svc enableHDMIPlayback:pvc];
    }
}

#pragma mark - External display scene (referenced by name from Info.plist)

@interface UYTExternalSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation UYTExternalSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    gUYTExtScene = windowScene;
    UYTDebugInfo(@"[ExternalDisplay] external scene connected (role=%@, %@)", session.role,
                 NSStringFromCGRect(windowScene.coordinateSpace.bounds));

    // Placeholder shown when no video is on the external display.
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.blackColor;
    UILabel *label = [UILabel new];
    label.text = UYTExtEnabled()
        ? @"Play a video on your phone to show it here"
        : @"External display playback is off (uYouEnhanced settings)";
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    label.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.frame = vc.view.bounds;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:label];

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:windowScene];
    window.rootViewController = vc;
    window.hidden = NO;
    self.window = window;

    dispatch_async(dispatch_get_main_queue(), ^{ UYTExtAttach(); });
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    UYTDebugInfo(@"[ExternalDisplay] external scene disconnected");
    YTHDMIServiceImpl *svc = gUYTHDMIService;
    BOOL wasMirroring = UYTExtMirroring();
    gUYTExtScene = nil;
    if (svc && wasMirroring) {
        // Puts the rendering view back into the phone's player.
        [svc stopMirroring];
    }
    self.window = nil;
}

@end

#pragma mark - Scene configuration (code path, independent of the Info.plist patch)

static BOOL UYTIsExternalRole(NSString *role) {
    // String literals: the NonInteractive constant is iOS 16+, the legacy one is deprecated.
    return [role isEqualToString:@"UIWindowSceneSessionRoleExternalDisplayNonInteractive"]
        || [role isEqualToString:@"UIWindowSceneSessionRoleExternalDisplay"];
}

static BOOL gUYTYouTubeHasConfigMethod;
typedef UISceneConfiguration *(*UYTConfigForSessionIMP)(id, SEL, UIApplication *, UISceneSession *, UISceneConnectionOptions *);
static UYTConfigForSessionIMP UYTOrigConfigForSession;

static UISceneConfiguration *UYTConfigForSession(id self, SEL _cmd, UIApplication *app, UISceneSession *session, UISceneConnectionOptions *options) {
    if (UYTIsExternalRole(session.role)) {
        UYTDebugInfo(@"[ExternalDisplay] scene session requested: role=%@ enabled=%d plistConfig=%@/%@",
                     session.role, UYTExtEnabled(), session.configuration.name,
                     NSStringFromClass(session.configuration.delegateClass));
        if (UYTExtEnabled()) {
            UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"UYTExternalDisplay" sessionRole:session.role];
            config.sceneClass = [UIWindowScene class];
            config.delegateClass = [UYTExternalSceneDelegate class];
            return config;
        }
    }
    if (UYTOrigConfigForSession) return UYTOrigConfigForSession(self, _cmd, app, session, options);
    return session.configuration;
}

// YouTube may or may not implement this UIApplicationDelegate method, so hook or add it at runtime.
static void UYTExtInstallSceneConfigHook(void) {
    Class cls = objc_getClass("YTAppDelegate");
    SEL sel = @selector(application:configurationForConnectingSceneSession:options:);
    if (!cls) {
        UYTDebugWarn(@"[ExternalDisplay] YTAppDelegate not found; scene config hook not installed");
        return;
    }
    Method inherited = class_getInstanceMethod(cls, sel);
    IMP previous = inherited ? method_getImplementation(inherited) : NULL;
    if (class_addMethod(cls, sel, (IMP)UYTConfigForSession, "@40@0:8@16@24@32")) {
        gUYTYouTubeHasConfigMethod = previous != NULL;
        UYTOrigConfigForSession = (UYTConfigForSessionIMP)previous;
    } else {
        gUYTYouTubeHasConfigMethod = YES;
        UYTOrigConfigForSession = (UYTConfigForSessionIMP)method_setImplementation(class_getInstanceMethod(cls, sel), (IMP)UYTConfigForSession);
    }
}

// YouTube 21.x has ios27SceneDelegate* hot-config flags (e.g. ...IgnoreNonRoleApplicationWindows).
// Log their values once so a device log shows how YouTube treats non-application scenes on
// iOS 27. Not overridden: "ignore non-application windows" sounds like it keeps YouTube's own
// window handling away from our external window, so forcing it off could make things worse.
static void UYTExtLogIOS27SceneFlags(void) {
    NSMutableSet<NSString *> *images = [NSMutableSet set];
    for (NSString *name in @[@"YTHotConfig", @"YTHotConfigIosClientGlobalConfigImpl", @"YTColdConfig"]) {
        Class c = objc_getClass(name.UTF8String);
        const char *image = c ? class_getImageName(c) : NULL;
        if (image) [images addObject:@(image)];
    }
    NSUInteger found = 0;
    for (NSString *image in images) {
        unsigned int classCount = 0;
        const char **names = objc_copyClassNamesForImage(image.UTF8String, &classCount);
        for (unsigned int i = 0; i < classCount; i++) {
            if (strncmp(names[i], "YTHotConfig", 11) != 0 && strncmp(names[i], "YTColdConfig", 12) != 0) continue;
            Class cls = objc_getClass(names[i]);
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            for (unsigned int j = 0; j < methodCount; j++) {
                SEL sel = method_getName(methods[j]);
                NSString *selName = NSStringFromSelector(sel);
                if ([selName rangeOfString:@"ios27SceneDelegate" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
                char ret[8] = {0};
                method_getReturnType(methods[j], ret, sizeof(ret));
                if (method_getNumberOfArguments(methods[j]) != 2 || (ret[0] != 'B' && ret[0] != 'c')) continue;
                found++;
                IMP orig = method_getImplementation(methods[j]);
                NSString *label = [NSString stringWithFormat:@"%s.%@", names[i], selName];
                __block BOOL logged = NO;
                method_setImplementation(methods[j], imp_implementationWithBlock(^BOOL(id me) {
                    BOOL value = ((BOOL (*)(id, SEL))orig)(me, sel);
                    if (!logged) {
                        logged = YES;
                        UYTDebugInfo(@"[ExternalDisplay] hot config %@ = %d", label, value);
                    }
                    return value;
                }));
            }
            free(methods);
        }
        free(names);
    }
    UYTDebugInfo(@"[ExternalDisplay] watching %lu ios27SceneDelegate flag(s)", (unsigned long)found);
}

#pragma mark - Hooks

%hook YTHotConfigIosClientGlobalConfigImpl
- (BOOL)fullscreenHdmiHamplayer {
    static BOOL logged;
    if (!logged) {
        logged = YES;
        UYTDebugInfo(@"[ExternalDisplay] hot config fullscreenHdmiHamplayer queried (forcing=%d)", UYTExtEnabled());
    }
    return UYTExtEnabled() ? YES : %orig;
}
%end

%hook YTHotConfig
- (BOOL)iosClientGlobalConfigFullscreenHdmiHamplayer {
    return UYTExtEnabled() ? YES : %orig;
}
%end

%hook YTHDMIServiceImpl

- (id)init {
    self = %orig;
    gUYTHDMIService = self;
    UYTDebugInfo(@"[ExternalDisplay] YTHDMIServiceImpl created");
    return self;
}

- (void)prepareIfNeeded {
    gUYTHDMIService = self;
    %orig;
}

// Original reads the second entry of UIScreen.screens. Use our scene's screen instead
// (nil when no external display) so the service only mirrors when our scene exists.
- (void)detectExternalScreen {
    if (!UYTExtEnabled()) {
        %orig;
        return;
    }
    UIWindowScene *scene = gUYTExtScene;
    UYTSetIvar(self, "_secondScreen", scene.screen);
}

- (void)enableHDMIPlayback:(id)playbackController {
    gUYTLastPlayerViewController = playbackController;
    UYTDebugInfo(@"[ExternalDisplay] enableHDMIPlayback: pvc=%@ scene=%d screen=%d",
                 NSStringFromClass([playbackController class]), gUYTExtScene != nil,
                 UYTGetIvar(self, "_secondScreen") != nil);
    %orig;
}

- (void)disableHDMIPlayback {
    UYTDebugInfo(@"[ExternalDisplay] disableHDMIPlayback");
    %orig;
}

// Original creates its window with -setScreen:, which is ignored in a scene-based app.
// Attach that window to our external scene.
- (BOOL)setViewToMirror:(id)view playbackController:(id)playbackController {
    BOOL ok = %orig;
    UIWindowScene *scene = gUYTExtScene;
    UIWindow *window = UYTGetIvar(self, "_secondWindow");
    UYTDebugInfo(@"[ExternalDisplay] setViewToMirror: ok=%d view=%@ window=%d scene=%d",
                 ok, NSStringFromClass([view class]), window != nil, scene != nil);
    if (UYTExtEnabled() && scene && window && window.windowScene != scene) {
        window.windowScene = scene;
        window.frame = scene.coordinateSpace.bounds;
        window.windowLevel = UIWindowLevelNormal + 1; // above the placeholder
        window.backgroundColor = UIColor.blackColor;
        window.hidden = NO;
        UYTDebugInfo(@"[ExternalDisplay] video window attached to external scene");
    }
    return ok;
}

%end

%hook YTHDMIServicePlaybackObserverImpl
- (void)observePlaybackController:(id)controller {
    gUYTLastPlayerViewController = controller;
    %orig;
}
- (void)playerViewController:(id)controller didActivateVideo:(id)video {
    gUYTLastPlayerViewController = controller;
    %orig;
}
%end

// On background MLHAMQueuePlayer sets _isInBackground and drops the video track renderer
// (updateActiveTrackRenderers). Locking the phone backgrounds the app, so skip that while
// the video is on the external display. Audio-only background play is unchanged otherwise.
%hook MLHAMQueuePlayer
- (void)appDidEnterBackground {
    if (UYTExtPlaybackActive()) {
        UYTDebugInfo(@"[ExternalDisplay] app backgrounded/locked: keeping video renderer for external display");
        return;
    }
    %orig;
}
%end

static void UYTExtLogEnvironment(NSString *why) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableArray *scenes = [NSMutableArray array];
    for (UIScene *s in app.connectedScenes) {
        [scenes addObject:[NSString stringWithFormat:@"%@/%@/state=%ld", NSStringFromClass([s.delegate class]),
                           s.session.role, (long)s.activationState]];
    }
    NSMutableArray *sessions = [NSMutableArray array];
    for (UISceneSession *session in app.openSessions) {
        [sessions addObject:[NSString stringWithFormat:@"%@(%@)", session.role, session.scene ? @"connected" : @"no scene"]];
    }
    NSDictionary *plistRoles = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIApplicationSceneManifest"][@"UISceneConfigurations"];
    UYTDebugInfo(@"[ExternalDisplay] %@: enabled=%d screens=%lu scenes=[%@] sessions=[%@] plistRoles=[%@] ytConfigMethod=%d service=%d mirroring=%d appState=%ld",
                 why, UYTExtEnabled(), (unsigned long)UIScreen.screens.count, [scenes componentsJoinedByString:@"; "],
                 [sessions componentsJoinedByString:@", "], [plistRoles.allKeys componentsJoinedByString:@", "],
                 gUYTYouTubeHasConfigMethod, gUYTHDMIService != nil, UYTExtMirroring(), (long)app.applicationState);
}

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kExternalDisplayPlayback] == nil) {
        [defaults setBool:YES forKey:kExternalDisplayPlayback];
    }
    %init;
    UYTExtInstallSceneConfigHook();
    UYTExtLogIOS27SceneFlags();

    NSDictionary *roles = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIApplicationSceneManifest"][@"UISceneConfigurations"];
    UYTDebugInfo(@"[ExternalDisplay] loaded; Info.plist scene roles: %@; YouTube implements configurationForConnecting: %d",
                 [[roles allKeys] componentsJoinedByString:@", "], gUYTYouTubeHasConfigMethod);

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    NSArray *names = @[UIScreenDidConnectNotification, UIScreenDidDisconnectNotification,
                       UISceneWillConnectNotification, UISceneDidDisconnectNotification,
                       UIApplicationDidEnterBackgroundNotification, UIApplicationWillEnterForegroundNotification,
                       UIApplicationDidBecomeActiveNotification];
    for (NSString *name in names) {
        [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            UYTExtLogEnvironment(note.name);
        }];
    }
}
