#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <string.h>

#ifndef SKYRIM_SIM_MANIFEST_SHA256
#error This game frontend must be bound to its verified generated-code manifest.
#endif

static NSString *uniqueFile(NSString *directory,NSString *name) {
    NSArray<NSString *> *items=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
    NSString *match=nil;
    for(NSString *item in items) {
        if([item caseInsensitiveCompare:name]!=NSOrderedSame) continue;
        if(match) return nil;
        match=[directory stringByAppendingPathComponent:item];
    }
    return match;
}

static NSString *sha256(NSString *path) {
    FILE *file=fopen(path.fileSystemRepresentation,"rb");
    if(!file) return nil;
    CC_SHA256_CTX context;CC_SHA256_Init(&context);
    unsigned char buffer[65536];size_t count;
    while((count=fread(buffer,1,sizeof buffer,file))>0) CC_SHA256_Update(&context,buffer,(CC_LONG)count);
    bool failed=ferror(file);fclose(file);if(failed) return nil;
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(bytes,&context);
    char text[CC_SHA256_DIGEST_LENGTH*2+1];
    for(unsigned i=0;i<sizeof bytes;i++) snprintf(text+i*2,3,"%02x",bytes[i]);
    return [NSString stringWithUTF8String:text];
}

extern "C" int simulator_validate_game_inputs(char *game,size_t game_size,char *save,size_t save_size,char *error,size_t error_size) {
    @autoreleasepool {
        auto fail=[&](NSString *message) {snprintf(error,error_size,"%s",message.UTF8String);return 0;};
        NSString *manifestPath=[NSBundle.mainBundle pathForResource:@"game-input-manifest" ofType:@"json"];
        if(!manifestPath) return fail(@"This app has no generated-code input identity. Rebuild the private game target.");
        NSData *data=[NSData dataWithContentsOfFile:manifestPath];
        NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if(![manifest isKindOfClass:NSDictionary.class] || [manifest[@"schema"] integerValue]!=1 ||
           ![manifest[@"generated_manifest_sha256"] isEqualToString:@SKYRIM_SIM_MANIFEST_SHA256])
            return fail(@"The bundled game input identity does not match the compiled executable.");
        NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSString *gamePath=[documents stringByAppendingPathComponent:@"Skyrim"];
        NSDictionary *modules=manifest[@"modules"];
        NSArray *required=@[@"TESV.exe",@"TESV_unpacked.exe",@"d3dx9_42.dll",@"binkw32.dll",@"X3DAudio1_7.dll"];
        for(NSString *name in required) {
            NSString *path=uniqueFile(gamePath,name);
            NSString *expected=modules[name];
            if(!path || ![expected isKindOfClass:NSString.class] || ![sha256(path) isEqualToString:expected])
                return fail([NSString stringWithFormat:@"Place the exact Windows %@ used to build this app in Documents/Skyrim.",name]);
        }
        NSString *dataPath=uniqueFile(gamePath,@"Data");
        NSDictionary *essentials=manifest[@"essential_data"];
        for(NSString *name in @[@"Skyrim.esm",@"Update.esm"]) {
            NSString *path=dataPath?uniqueFile(dataPath,name):nil;
            NSString *expected=essentials[name];
            if(!path || ![expected isKindOfClass:NSString.class] || ![sha256(path) isEqualToString:expected])
                return fail([NSString stringWithFormat:@"Documents/Skyrim/Data/%@ does not match the private build inputs.",name]);
        }
        BOOL hasArchive=NO;
        for(NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dataPath error:nil])
            if([name.pathExtension caseInsensitiveCompare:@"bsa"]==NSOrderedSame) hasArchive=YES;
        if(!hasArchive) return fail(@"Copy the full Data directory, including its BSA archives, into Documents/Skyrim.");
        NSString *savePath=[documents stringByAppendingPathComponent:@"SkyrimSaves"];
        if(![[NSFileManager defaultManager] createDirectoryAtPath:savePath withIntermediateDirectories:YES attributes:nil error:nil])
            return fail(@"Cannot create the separate Documents/SkyrimSaves directory.");
        if(strlen(gamePath.fileSystemRepresentation)>=game_size || strlen(savePath.fileSystemRepresentation)>=save_size)
            return fail(@"The private game or save directory path is too long.");
        snprintf(game,game_size,"%s",gamePath.fileSystemRepresentation);
        snprintf(save,save_size,"%s",savePath.fileSystemRepresentation);
        return 1;
    }
}
