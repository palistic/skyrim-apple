/* Skyrim Apple port overlay: visionOS stand-ins for the iOS-only UIKit screen APIs that the
 * pinned SDL 2.30 UIKit backend uses. visionOS has no UIScreen; each window scene is its own
 * window in the Shared Space. SDL sees one display whose size and scale come from the app's
 * window scene. Included first by every SDL UIKit source in the visionOS overlay only (see
 * simulator/prepare_sdl.py --platform visionos); the iOS build never sees this file. */
#ifndef SDL_uikit_xros_h_
#define SDL_uikit_xros_h_

#include <TargetConditionals.h>
#if TARGET_OS_VISION && defined(__OBJC__)
#import <UIKit/UIKit.h>

/* Nominal display when no window scene is connected yet: the default visionOS window size. */
#define SDL_XR_DEFAULT_WIDTH 1280.0
#define SDL_XR_DEFAULT_HEIGHT 720.0
#define SDL_XR_REFRESH_RATE 90

@interface SDLXRScreenMode : NSObject
@property (nonatomic) CGSize size;
@end

@interface SDLXRScreen : NSObject
+ (SDLXRScreen *)mainScreen;
+ (NSArray<SDLXRScreen *> *)screens;
@property (nonatomic, readonly) CGRect bounds;
@property (nonatomic, readonly) CGRect nativeBounds;
@property (nonatomic, readonly) CGFloat scale;
@property (nonatomic, readonly) CGFloat nativeScale;
@property (nonatomic) SDLXRScreenMode *currentMode; /* setting it is a no-op: the scene owns the size */
@property (nonatomic, readonly) SDLXRScreenMode *preferredMode;
@property (nonatomic, readonly) NSArray<SDLXRScreenMode *> *availableModes;
@property (nonatomic, readonly) NSInteger maximumFramesPerSecond;
@property (nonatomic, readonly) UIEdgeInsets safeAreaInsets;
@property (nonatomic, readonly) id<UICoordinateSpace> coordinateSpace;
@property (nonatomic, readonly) id<UICoordinateSpace> fixedCoordinateSpace;
@end

@interface UIView (SDLXRScreen)
@property (nonatomic, readonly) SDLXRScreen *sdlxr_screen;
@end
@interface UIWindow (SDLXRScreen)
- (void)sdlxr_setScreen:(SDLXRScreen *)screen;
@end
@interface UIWindowScene (SDLXRScreen)
@property (nonatomic, readonly) SDLXRScreen *sdlxr_screen;
@end
@interface UIViewController (SDLXRScreen)
- (void)sdlxr_setNeedsStatusBarAppearanceUpdate;
@end
@interface UIApplication (SDLXRScreen)
@property (nonatomic, readonly) UIInterfaceOrientation sdlxr_statusBarOrientation;
@property (nonatomic) BOOL sdlxr_statusBarHidden;
@property (nonatomic) UIStatusBarStyle sdlxr_statusBarStyle;
@end

/* The window scene that hosts the game: the launcher's WindowGroup scene, registered from SwiftUI through
 * skyrim_sdl_set_game_scene (apple/Sources/App/GameSceneReporter.swift). nil until registered, or once that
 * scene has disconnected. Other scenes, such as an ImmersiveSpace, are never chosen for SDL's window. */
UIWindowScene *SDLXR_GameScene(void);
/* C entry point for Swift: window_scene is a UIWindowScene * passed unretained (held weakly here). */
void skyrim_sdl_set_game_scene(void *window_scene);

extern NSNotificationName const SDLXRScreenDidConnectNotification;
extern NSNotificationName const SDLXRScreenDidDisconnectNotification;
extern NSNotificationName const SDLXRStatusBarOrientationNotification;

/* The window scene the game shows in: the registered game scene, else an application-role window scene. */
extern UIWindowScene *SDLXR_ActiveScene(void);

/* Trackpad pointer over the game window, for the edge turn: x runs from -1 (left edge) to 1 (right edge). */
void SDLXR_PointerMoved(float x);
void SDLXR_PointerLeft(void);
/* A GCMouse delta arrived; called on GameController's handler queue. */
void SDLXR_MouseDelta(void);
/* GCMouse button (pressed or released) and scroll, counted for the pointer log. */
void SDLXR_MouseButton(int pressed);
void SDLXR_MouseScroll(void);
/* C entry for Swift: 1 while immersive play runs (SDL's window nearly invisible), 0 to show it again. */
void skyrim_sdl_set_window_ghost(int on);

/* Token renames, scoped to the SDL UIKit sources that include this header. */
#define UIScreenMode SDLXRScreenMode
#define UIScreen SDLXRScreen
#define UIScreenDidConnectNotification SDLXRScreenDidConnectNotification
#define UIScreenDidDisconnectNotification SDLXRScreenDidDisconnectNotification
#define UIApplicationDidChangeStatusBarOrientationNotification SDLXRStatusBarOrientationNotification
#define screen sdlxr_screen
#define setScreen sdlxr_setScreen
#define statusBarOrientation sdlxr_statusBarOrientation
#define statusBarHidden sdlxr_statusBarHidden
#define statusBarStyle sdlxr_statusBarStyle
#define setNeedsStatusBarAppearanceUpdate sdlxr_setNeedsStatusBarAppearanceUpdate
#undef UI_USER_INTERFACE_IDIOM
#define UI_USER_INTERFACE_IDIOM() (UIDevice.currentDevice.userInterfaceIdiom)

#endif /* TARGET_OS_VISION && __OBJC__ */
#endif /* SDL_uikit_xros_h_ */
