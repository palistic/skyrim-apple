#import <UIKit/UIKit.h>
#include <stdio.h>
#include <string.h>

extern "C" int simulator_fixture_path(const char *name,char *path,size_t size) {
    NSString *source=[NSBundle.mainBundle pathForResource:[NSString stringWithUTF8String:name] ofType:nil inDirectory:@"AudioFixtures"];
    if(!source || strlen(source.fileSystemRepresentation)>=size) return 0;
    snprintf(path,size,"%s",source.fileSystemRepresentation);
    return 1;
}

extern "C" void simulator_prepare_paths(char *game_dir, size_t game_size, char *save_dir, size_t save_size) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *save = [documents stringByAppendingPathComponent:@"RuntimeProbe"];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:save withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "Cannot create diagnostic data directory: %s\n", error.localizedDescription.UTF8String);
        abort();
    }
    snprintf(game_dir, game_size, "%s", documents.fileSystemRepresentation);
    snprintf(save_dir, save_size, "%s", save.fileSystemRepresentation);
}

extern "C" void simulator_show_status(const char *text) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (window) break;
    }
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;
    if (!window) return;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(24, 20, window.bounds.size.width - 48, 170)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    label.numberOfLines = 0;
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    label.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightMedium];
    label.text = [NSString stringWithUTF8String:text];
    label.accessibilityIdentifier = @"skyrim-runtime-probe-status";
    [window addSubview:label];
}
