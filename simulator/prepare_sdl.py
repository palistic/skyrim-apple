#!/usr/bin/env python3
"""Create an owned SDL2 source overlay for the modern UIKit scene lifecycle.

The pinned vendor source stays untouched. These are native UIKit platform
adaptations, not a dynamic code translator or game patch.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/"android/app/jni/SDL2"


def replace_once(text,before,after):
    if text.count(before)!=1:
        raise ValueError("Pinned SDL scene adaptation no longer matches its expected source")
    return text.replace(before,after,1)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output",type=Path)
    args=parser.parse_args()
    output=args.output.resolve()
    if ROOT not in output.parents or "build" not in output.relative_to(ROOT).parts:
        parser.error("The SDL overlay must stay in this checkout's ignored build tree")
    shutil.copytree(SOURCE,output,dirs_exist_ok=True,copy_function=shutil.copy2)
    delegate=output/"src/video/uikit/SDL_uikitappdelegate.m"
    window=output/"src/video/uikit/SDL_uikitwindow.m"
    original_delegate=delegate.read_text()
    original_window=window.read_text()
    text=original_delegate
    scene_code=r'''
/* Skyrim Apple port overlay: scene lifecycle required by the current iOS SDK. */
static BOOL skyrim_scene_main_started;
#include "SDL_uikitevents.h"
@interface SDLUIKitSceneDelegate : NSObject<UIWindowSceneDelegate>
@end
@implementation SDLUIKitSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)scene; (void)session; (void)options;
    [[SDLUIKitDelegate sharedAppDelegate] performSelector:@selector(postFinishLaunch) withObject:nil afterDelay:0.0];
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    (void)scene;
    SDL_OnApplicationDidBecomeActive();
}
- (void)sceneWillResignActive:(UIScene *)scene {
    (void)scene;
    SDL_OnApplicationWillResignActive();
}
- (void)sceneWillEnterForeground:(UIScene *)scene {
    (void)scene;
    SDL_OnApplicationWillEnterForeground();
}
- (void)sceneDidEnterBackground:(UIScene *)scene {
    (void)scene;
    SDL_OnApplicationDidEnterBackground();
}
@end
'''
    text=replace_once(text,"static int exit_status;","static int exit_status;\n"+scene_code)
    text=replace_once(text,"- (void)postFinishLaunch\n{",'''- (void)postFinishLaunch
{
    if (skyrim_scene_main_started) return;
    BOOL scene_ready = NO;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class]) scene_ready = YES;
    if (!scene_ready) return;
    skyrim_scene_main_started = YES;''')
    text=replace_once(text,"- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions",'''- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options
{
    (void)application; (void)options;
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Skyrim SDL Scene" sessionRole:session.role];
    configuration.delegateClass = SDLUIKitSceneDelegate.class;
    return configuration;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions''')
    text=text.replace("#ifdef SDL_IPHONE_LAUNCHSCREEN","#if defined(SDL_IPHONE_LAUNCHSCREEN) && !defined(SKYRIM_UIKIT_SCENE_LIFECYCLE)")
    delegate.write_text(text)
    text=replace_once(original_window,"UIWindow *uiwindow = [[SDL_uikitwindow alloc] initWithFrame:data.uiscreen.bounds];",'''/* Skyrim Apple port overlay: attach SDL's real window to its UIKit scene. */
        UIWindowScene *window_scene = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] && ((UIWindowScene *)scene).screen == data.uiscreen) {
                window_scene = (UIWindowScene *)scene;
                break;
            }
        }
        if (!window_scene) return SDL_SetError("No connected UIKit window scene for SDL");
        UIWindow *uiwindow = [[SDL_uikitwindow alloc] initWithWindowScene:window_scene];''')
    window.write_text(text)
    receipt={"scope":"native-uikit-scene-overlay","vendor_modified":False,"files":{}}
    for name,before in [("src/video/uikit/SDL_uikitappdelegate.m",original_delegate),("src/video/uikit/SDL_uikitwindow.m",original_window)]:
        receipt["files"][name]={"original_sha256":hashlib.sha256(before.encode()).hexdigest(),"overlay_sha256":hashlib.sha256((output/name).read_bytes()).hexdigest()}
    (output.parent/"sdl-scene-overlay.json").write_text(json.dumps(receipt,indent=2)+"\n")


if __name__=="__main__":
    main()
