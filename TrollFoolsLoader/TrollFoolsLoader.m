#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdint.h>

static NSString *const TFLoaderManifestName = @"TrollFoolsLoader.plist";
static NSString *const TFLoaderManifestPluginsKey = @"Plugins";

static void TFLoadDeferredPlugIns(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            NSString *frameworksPath = [[[NSBundle mainBundle] bundlePath]
                stringByAppendingPathComponent:@"Frameworks"];
            NSString *manifestPath = [frameworksPath stringByAppendingPathComponent:TFLoaderManifestName];
            NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
            NSArray *plugIns = [manifest[TFLoaderManifestPluginsKey] isKindOfClass:[NSArray class]]
                ? manifest[TFLoaderManifestPluginsKey]
                : @[];

            for (id item in plugIns) {
                if (![item isKindOfClass:[NSString class]]) {
                    continue;
                }

                NSString *relativePath = (NSString *)item;
                if (relativePath.length == 0 || [relativePath hasPrefix:@"/"] ||
                    [relativePath.pathComponents containsObject:@".."])
                {
                    NSLog(@"[TrollFoolsLoader] Rejected invalid plug-in path: %@", relativePath);
                    continue;
                }

                NSString *plugInPath = [frameworksPath stringByAppendingPathComponent:relativePath];
                void *handle = dlopen(plugInPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
                if (handle == NULL) {
                    const char *error = dlerror();
                    NSLog(@"[TrollFoolsLoader] Failed to load %@: %s", relativePath, error ?: "unknown error");
                } else {
                    NSLog(@"[TrollFoolsLoader] Loaded %@", relativePath);
                }
            }
        }
    });
}

static int TFDeferredUIApplicationMain(int argc, char * _Nullable argv[], NSString * _Nullable principalClassName,
                                       NSString * _Nullable delegateClassName)
{
    TFLoadDeferredPlugIns();
    return UIApplicationMain(argc, argv, principalClassName, delegateClassName);
}

#define TF_DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _tf_interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&_replacement, (const void *)(uintptr_t)&_replacee \
    }

TF_DYLD_INTERPOSE(TFDeferredUIApplicationMain, UIApplicationMain);

__attribute__((constructor))
static void TFInstallLaunchFallback(void)
{
    @autoreleasepool {
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
                        TFLoadDeferredPlugIns();
                    }];
    }
}
