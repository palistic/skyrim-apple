/* Skyrim Apple port overlay: implementation of the visionOS screen stand-ins (SDL_uikit_xros.h). */
#include "../../SDL_internal.h"
#include "SDL_uikit_xros.h"

#if TARGET_OS_VISION && defined(__OBJC__)
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>

NSNotificationName const SDLXRScreenDidConnectNotification = @"SDLXRScreenDidConnectNotification";
NSNotificationName const SDLXRScreenDidDisconnectNotification = @"SDLXRScreenDidDisconnectNotification";
NSNotificationName const SDLXRStatusBarOrientationNotification = @"SDLXRStatusBarOrientationNotification";

/* Main thread only: set from SwiftUI's didMoveToWindow, read while SDL creates and sizes its window. */
static __weak UIWindowScene *sdlxr_game_scene;

void skyrim_sdl_set_game_scene(void *window_scene)
{
    UIWindowScene *scene = (__bridge UIWindowScene *)window_scene;
    if (scene && ![scene isKindOfClass:UIWindowScene.class]) return;
    sdlxr_game_scene = scene;
}

UIWindowScene *SDLXR_GameScene(void)
{
    UIWindowScene *scene = sdlxr_game_scene;
    if (scene && scene.activationState != UISceneActivationStateUnattached &&
        [UIApplication.sharedApplication.connectedScenes containsObject:scene])
        return scene;
    return nil;
}

/* The window scene the game shows in: the registered game scene; before registration, a foreground-active
 * application-role window scene, else any application-role one. Immersive-space scenes are never returned. */
UIWindowScene *SDLXR_ActiveScene(void)
{
    UIWindowScene *game = SDLXR_GameScene();
    if (game) return game;
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (![scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
        if (!fallback) fallback = (UIWindowScene *)scene;
    }
    return fallback;
}

@implementation SDLXRScreenMode
@end

@implementation SDLXRScreen

+ (SDLXRScreen *)mainScreen
{
    static SDLXRScreen *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[SDLXRScreen alloc] init]; });
    return shared;
}

+ (NSArray<SDLXRScreen *> *)screens
{
    return @[ [SDLXRScreen mainScreen] ];
}

- (CGRect)bounds
{
    UIWindowScene *scene = SDLXR_ActiveScene();
    CGRect bounds = scene ? scene.coordinateSpace.bounds : CGRectZero;
    if (bounds.size.width < 1.0 || bounds.size.height < 1.0)
        bounds = CGRectMake(0, 0, SDL_XR_DEFAULT_WIDTH, SDL_XR_DEFAULT_HEIGHT);
    return bounds;
}

- (CGFloat)scale
{
    UIWindowScene *scene = SDLXR_ActiveScene();
    CGFloat scale = scene ? scene.traitCollection.displayScale : 0.0;
    return scale > 0.0 ? scale : 2.0;
}

- (CGFloat)nativeScale { return self.scale; }

- (CGRect)nativeBounds
{
    CGRect b = self.bounds;
    CGFloat s = self.scale;
    return CGRectMake(0, 0, b.size.width * s, b.size.height * s);
}

- (SDLXRScreenMode *)currentMode
{
    SDLXRScreenMode *mode = [[SDLXRScreenMode alloc] init];
    mode.size = self.nativeBounds.size;
    return mode;
}

- (void)setCurrentMode:(SDLXRScreenMode *)mode { (void)mode; }
- (SDLXRScreenMode *)preferredMode { return self.currentMode; }
- (NSArray<SDLXRScreenMode *> *)availableModes { return @[ self.currentMode ]; }
- (NSInteger)maximumFramesPerSecond { return SDL_XR_REFRESH_RATE; }
- (UIEdgeInsets)safeAreaInsets { return UIEdgeInsetsZero; }

- (id<UICoordinateSpace>)coordinateSpace
{
    UIWindowScene *scene = SDLXR_ActiveScene();
    return scene ? scene.coordinateSpace : nil;
}

- (id<UICoordinateSpace>)fixedCoordinateSpace { return self.coordinateSpace; }

@end

@implementation UIView (SDLXRScreen)
- (SDLXRScreen *)sdlxr_screen { return [SDLXRScreen mainScreen]; }
@end

@implementation UIWindow (SDLXRScreen)
- (void)sdlxr_setScreen:(SDLXRScreen *)screen { (void)screen; }
@end

@implementation UIWindowScene (SDLXRScreen)
- (SDLXRScreen *)sdlxr_screen { return [SDLXRScreen mainScreen]; }
@end

@implementation UIViewController (SDLXRScreen)
- (void)sdlxr_setNeedsStatusBarAppearanceUpdate {}
@end

@implementation UIApplication (SDLXRScreen)
/* Follows the window's shape, so SDL's landscape/portrait width-height swaps never fire. */
- (UIInterfaceOrientation)sdlxr_statusBarOrientation
{
    CGSize size = [SDLXRScreen mainScreen].bounds.size;
    return size.width >= size.height ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationPortrait;
}
- (BOOL)sdlxr_statusBarHidden { return YES; }
- (void)setSdlxr_statusBarHidden:(BOOL)hidden { (void)hidden; }
- (UIStatusBarStyle)sdlxr_statusBarStyle { return UIStatusBarStyleDefault; }
- (void)setSdlxr_statusBarStyle:(UIStatusBarStyle)style { (void)style; }
@end

/* Edge turn. A Shared Space window may not hold the system pointer, which then stops at (or leaves) the window and
 * mouselook runs out. While the pointer is pushed against a side edge, the runtime keeps turning. A step larger than
 * XR_JUMP is the system moving the pointer (it follows the wearer's gaze), not the trackpad, so it never starts a
 * turn. The turn ends XR_HOLD seconds after the trackpad last moved. Pointer state is main thread only. */
#define XR_JUMP 0.25f
#define XR_EDGE 0.8f
#define XR_HOLD 1.0

static float xr_x;
static BOOL xr_seen, xr_arrived;
static double xr_moved_at;
static _Atomic int xr_over, xr_moves, xr_deltas_over, xr_deltas_off;
static _Atomic double xr_delta_at;

void SDLXR_PointerMoved(float x)
{
    x = x < -1.0f ? -1.0f : x > 1.0f ? 1.0f : x;
    xr_moves++;
    if (xr_over && xr_seen && fabsf(x - xr_x) <= XR_JUMP) {
        if (x != xr_x) {
            xr_moved_at = CACurrentMediaTime();
            xr_arrived = YES;
        }
    } else {
        xr_arrived = NO;
    }
    xr_x = x;
    xr_seen = YES;
    xr_over = 1;
}

void SDLXR_PointerLeft(void)
{
    xr_over = 0;
    if (xr_seen && xr_arrived && fabsf(xr_x) >= 0.85f) {
        xr_x = xr_x > 0 ? 1.0f : -1.0f; /* pushed out past a side edge: keep that side */
    } else {
        xr_seen = NO;
        xr_arrived = NO;
    }
}

void SDLXR_MouseDelta(void)
{
    xr_delta_at = CACurrentMediaTime();
    if (xr_over) xr_deltas_over++; else xr_deltas_off++;
}

/* Turning wanted this frame, -1 (left) to 1 (right); 0 when the pointer is locked or not at an edge. Main thread. */
float skyrim_xr_pointer_edge(void)
{
    static double reported_at;
    static int edge_frames, reported_lock = -1;
    double now = CACurrentMediaTime(), delta_at = xr_delta_at;
    double last = xr_moved_at > delta_at ? xr_moved_at : delta_at;
    int locked = SDLXR_ActiveScene().pointerLockState.isLocked ? 1 : 0;
    float edge = 0.0f;
    if (!locked && xr_seen && xr_arrived && now - last < XR_HOLD && fabsf(xr_x) > XR_EDGE) {
        edge = (fabsf(xr_x) - XR_EDGE) / (1.0f - XR_EDGE) * (xr_x > 0 ? 1.0f : -1.0f);
        edge_frames++;
    }
    if (locked != reported_lock || now - reported_at >= 10.0) {
        int moves = atomic_exchange(&xr_moves, 0), over = atomic_exchange(&xr_deltas_over, 0);
        int off = atomic_exchange(&xr_deltas_off, 0);
        if (locked != reported_lock || moves || over || off || edge_frames) {
            fprintf(stderr, "pointer: locked %d, hover moves %d, mouse deltas %d over window / %d off, edge turn %d frames\n",
                    locked, moves, over, off, edge_frames);
        }
        reported_lock = locked;
        reported_at = now;
        edge_frames = 0;
    }
    return edge;
}

#endif /* TARGET_OS_VISION && __OBJC__ */
