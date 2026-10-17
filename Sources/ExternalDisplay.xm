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

#pragma mark - Hooks

%hook YTHotConfigIosClientGlobalConfigImpl
- (BOOL)fullscreenHdmiHamplayer {
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
    return self;
}

- (void)prepareIfNeeded {
    gUYTHDMIService = self;
    %orig;
}

// Original uses [UIScreen screens][1]. Use our scene's screen instead (nil when no
// external display) so the service only mirrors when our scene exists.
- (void)detectExternalScreen {
    if (!UYTExtEnabled()) { %orig; return; }
    UIWindowScene *scene = gUYTExtScene;
    UYTSetIvar(self, "_secondScreen", scene.screen);
}

- (void)enableHDMIPlayback:(id)playbackController {
    gUYTLastPlayerViewController = playbackController;
    %orig;
}

// Original creates its window with -setScreen:, which is ignored in a scene-based app.
// Attach that window to our external scene.
- (BOOL)setViewToMirror:(id)view playbackController:(id)playbackController {
    BOOL ok = %orig;
    UIWindowScene *scene = gUYTExtScene;
    UIWindow *window = UYTGetIvar(self, "_secondWindow");
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

%ctor {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kExternalDisplayPlayback] == nil) {
        [defaults setBool:YES forKey:kExternalDisplayPlayback];
    }
    %init;
}
