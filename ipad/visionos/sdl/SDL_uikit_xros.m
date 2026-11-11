/* Skyrim Apple port overlay: implementation of the visionOS screen stand-ins (SDL_uikit_xros.h). */
#include "../../SDL_internal.h"
#include "SDL_uikit_xros.h"

#if TARGET_OS_VISION && defined(__OBJC__)
#import <QuartzCore/QuartzCore.h>
#import <GameController/GameController.h>
#include "SDL_mouse.h"
#include <string.h>
#include <stdlib.h>
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

/* Clicks and scroll from GCMouse, counted like the deltas (docs/VISIONOS_POINTER_PLAN.md step 1). */
static _Atomic int xr_clicks_over, xr_clicks_off, xr_scroll_over, xr_scroll_off;
static _Atomic double xr_press_at;
void SDLXR_MouseButton(int pressed)
{
    if (!pressed) return;
    xr_press_at = CACurrentMediaTime();
    if (xr_over) xr_clicks_over++; else xr_clicks_off++;
}
void SDLXR_MouseScroll(void)
{
    if (xr_over) xr_scroll_over++; else xr_scroll_off++;
}

/* SDL's window and its view controller: the window in the game scene whose root controller is SDL's. */
static UIWindow *xr_sdl_window(void)
{
    for (UIWindow *w in SDLXR_ActiveScene().windows)
        if ([NSStringFromClass(w.rootViewController.class) hasPrefix:@"SDL_"]) return w;
    return nil;
}

/* Immersive play: SDL's window stays as the trackpad's pointer surface but is nearly invisible (alpha 0.02 still
 * takes pointer input; below 0.01 UIKit stops hit-testing it), so it doesn't cover the immersive picture. */
void skyrim_sdl_set_window_ghost(int on)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = xr_sdl_window();
        /* Nearly invisible rather than hidden: a hidden UIWindow could cost SDL its keyboard focus and with it
         * relative mode, which GCMouse motion needs. At 0.02 UIKit still hit-tests it (below 0.01 it stops), so
         * it stays the pointer surface over the window's near-invisible fill. */
        w.alpha = on ? 0.02 : 1.0;
        fprintf(stderr, "pointer: game window %s\n", w ? (on ? "ghosted for immersive" : "shown") : "not found");
    });
}

/* The SwiftUI pointer surface's hover position (GameSurface.swift), for the edge turn. Main thread. */
void skyrim_xr_hover(float x) { SDLXR_PointerMoved(x); }
void skyrim_xr_hover_left(void) { SDLXR_PointerLeft(); }

/* When GCMouse last pressed a button, so a spatial click from the same press isn't counted twice. */
double skyrim_xr_last_mouse_press(void) { return xr_press_at; }

/* LB_POINTER_LOCK: "1" (default) leaves SDL's request as it is; "key" also makes SDL's window the key window and
 * asks UIKit to re-read the lock preference, in case UIKit asks the key window's root controller and that was
 * SwiftUI's. Main thread, every 2 s while relative mode is on. */
static void xr_pointer_lock_variant(double now)
{
    static int mode = -1;
    static double last;
    if (mode < 0) {
        const char *v = getenv("LB_POINTER_LOCK");
        mode = v && !strcmp(v, "key") ? 1 : 0;
        fprintf(stderr, "pointer: lock variant %s\n", mode ? "key" : "default");
        [NSNotificationCenter.defaultCenter addObserverForName:UIPointerLockStateDidChangeNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                UIPointerLockState *state = note.object;
                fprintf(stderr, "pointer: lock state changed, locked %d\n", state.isLocked ? 1 : 0);
            }];
    }
    if (!mode || now - last < 2.0 || !SDL_GetRelativeMouseMode()) return;
    last = now;
    UIWindow *w = xr_sdl_window();
    if (!w) return;
    if (!w.isKeyWindow) [w makeKeyWindow];
    [w.rootViewController setNeedsUpdateOfPrefersPointerLocked];
}

/* Turning wanted this frame, -1 (left) to 1 (right); 0 when the pointer is locked or not at an edge. Main thread. */
float skyrim_xr_pointer_edge(void)
{
    static double reported_at;
    static int edge_frames, reported_lock = -1;
    double now = CACurrentMediaTime(), delta_at = xr_delta_at;
    double last = xr_moved_at > delta_at ? xr_moved_at : delta_at;
    xr_pointer_lock_variant(now);
    int locked = SDLXR_ActiveScene().pointerLockState.isLocked ? 1 : 0;
    float edge = 0.0f;
    if (!locked && xr_seen && xr_arrived && now - last < XR_HOLD && fabsf(xr_x) > XR_EDGE) {
        edge = (fabsf(xr_x) - XR_EDGE) / (1.0f - XR_EDGE) * (xr_x > 0 ? 1.0f : -1.0f);
        edge_frames++;
    }
    if (locked != reported_lock || now - reported_at >= 10.0) {
        int moves = atomic_exchange(&xr_moves, 0), over = atomic_exchange(&xr_deltas_over, 0);
        int off = atomic_exchange(&xr_deltas_off, 0);
        int c_over = atomic_exchange(&xr_clicks_over, 0), c_off = atomic_exchange(&xr_clicks_off, 0);
        int s_over = atomic_exchange(&xr_scroll_over, 0), s_off = atomic_exchange(&xr_scroll_off, 0);
        if (locked != reported_lock || moves || over || off || edge_frames || c_over || c_off || s_over || s_off) {
            UIWindowScene *scene = SDLXR_ActiveScene();
            UIWindow *key = nil;
            for (UIWindow *w in scene.windows) if (w.isKeyWindow) key = w;
            UIWindow *sdl = xr_sdl_window();
            fprintf(stderr, "pointer: locked %d (state %s), hover moves %d, mouse deltas %d over window / %d off, "
                    "clicks %d/%d, scroll %d/%d, edge turn %d frames; scene %ld, %lu windows, key %s (%s), "
                    "SDL prefers lock %d, relative %d, mice %lu\n",
                    locked, scene.pointerLockState ? "set" : "nil", moves, over, off, c_over, c_off, s_over, s_off,
                    edge_frames, (long)scene.activationState, (unsigned long)scene.windows.count,
                    key == nil ? "none" : key == sdl ? "SDL" : "other",
                    key ? NSStringFromClass(key.rootViewController.class).UTF8String : "-",
                    sdl ? (sdl.rootViewController.prefersPointerLocked ? 1 : 0) : -1,
                    SDL_GetRelativeMouseMode() ? 1 : 0, (unsigned long)GCMouse.mice.count);
        }
        reported_lock = locked;
        reported_at = now;
        edge_frames = 0;
    }
    return edge;
}

#endif /* TARGET_OS_VISION && __OBJC__ */
