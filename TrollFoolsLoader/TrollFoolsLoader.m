#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <stdlib.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

static NSString *const TFLoaderManifestName = @"TrollFoolsLoader.plist";
static NSString *const TFLoaderManifestPluginsKey = @"Plugins";

typedef struct TFSetterGuardFrame {
    const void *object;
    const void *token;
    struct TFSetterGuardFrame *previous;
} TFSetterGuardFrame;

static __thread TFSetterGuardFrame *TFActiveSetterGuardFrame;

static BOOL TFSetterGuardIsActive(id object, id token)
{
    const void *objectPointer = (__bridge const void *)object;
    const void *tokenPointer = (__bridge const void *)token;
    for (TFSetterGuardFrame *frame = TFActiveSetterGuardFrame; frame != NULL; frame = frame->previous) {
        if (frame->object == objectPointer && frame->token == tokenPointer) {
            return YES;
        }
    }
    return NO;
}

static void *TFStripImplementationPointer(IMP implementation)
{
    void *address = (void *)implementation;
#if __has_feature(ptrauth_calls)
    address = ptrauth_strip(address, ptrauth_key_function_pointer);
#endif
    return address;
}

static BOOL TFImplementationBelongsToImage(IMP implementation, NSString *imagePath)
{
    Dl_info info = { 0 };
    if (dladdr(TFStripImplementationPointer(implementation), &info) == 0 || info.dli_fname == NULL) {
        return NO;
    }

    NSString *implementationPath = [[NSString stringWithUTF8String:info.dli_fname]
        stringByResolvingSymlinksInPath];
    return [implementationPath isEqualToString:imagePath];
}

static BOOL TFClassInheritsFromClass(Class candidateClass, Class baseClass)
{
    for (Class currentClass = candidateClass; currentClass != Nil; currentClass = class_getSuperclass(currentClass)) {
        if (currentClass == baseClass) {
            return YES;
        }
    }
    return NO;
}

static void TFCallSuperBoolSetter(id object, Class guardedClass, SEL selector, BOOL value)
{
    Class superclass = class_getSuperclass(guardedClass);
    if (superclass == Nil) {
        return;
    }
    struct objc_super superInfo = { object, superclass };
    ((void (*)(struct objc_super *, SEL, BOOL))(void *)objc_msgSendSuper)(&superInfo, selector, value);
}

static void TFCallSuperFloatSetter(id object, Class guardedClass, SEL selector, CGFloat value)
{
    Class superclass = class_getSuperclass(guardedClass);
    if (superclass == Nil) {
        return;
    }
    struct objc_super superInfo = { object, superclass };
    ((void (*)(struct objc_super *, SEL, CGFloat))(void *)objc_msgSendSuper)(&superInfo, selector, value);
}

static void TFInstallBoolSetterGuard(Class guardedClass, Method method)
{
    SEL selector = method_getName(method);
    IMP plugInImplementation = method_getImplementation(method);
    const char *typeEncoding = method_getTypeEncoding(method);
    NSObject *guardToken = [NSObject new];
    IMP guardedImplementation = imp_implementationWithBlock(^(id object, BOOL value) {
        if (TFSetterGuardIsActive(object, guardToken)) {
            TFCallSuperBoolSetter(object, guardedClass, selector, value);
            return;
        }

        TFSetterGuardFrame frame = {
            .object = (__bridge const void *)object,
            .token = (__bridge const void *)guardToken,
            .previous = TFActiveSetterGuardFrame,
        };
        TFActiveSetterGuardFrame = &frame;
        @try {
            ((void (*)(id, SEL, BOOL))plugInImplementation)(object, selector, value);
        } @finally {
            TFActiveSetterGuardFrame = frame.previous;
        }
    });
    class_replaceMethod(guardedClass, selector, guardedImplementation, typeEncoding);
}

static void TFInstallFloatSetterGuard(Class guardedClass, Method method)
{
    SEL selector = method_getName(method);
    IMP plugInImplementation = method_getImplementation(method);
    const char *typeEncoding = method_getTypeEncoding(method);
    NSObject *guardToken = [NSObject new];
    IMP guardedImplementation = imp_implementationWithBlock(^(id object, CGFloat value) {
        if (TFSetterGuardIsActive(object, guardToken)) {
            TFCallSuperFloatSetter(object, guardedClass, selector, value);
            return;
        }

        TFSetterGuardFrame frame = {
            .object = (__bridge const void *)object,
            .token = (__bridge const void *)guardToken,
            .previous = TFActiveSetterGuardFrame,
        };
        TFActiveSetterGuardFrame = &frame;
        @try {
            ((void (*)(id, SEL, CGFloat))plugInImplementation)(object, selector, value);
        } @finally {
            TFActiveSetterGuardFrame = frame.previous;
        }
    });
    class_replaceMethod(guardedClass, selector, guardedImplementation, typeEncoding);
}

static NSUInteger TFInstallReentrantUIKitSetterGuards(NSString *plugInPath)
{
    NSString *resolvedPlugInPath = [plugInPath stringByResolvingSymlinksInPath];
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        return 0;
    }

    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc(
        (size_t)classCount, sizeof(Class));
    if (classes == NULL) {
        return 0;
    }

    int returnedClassCount = objc_getClassList(classes, classCount);
    classCount = MIN(classCount, returnedClassCount);
    NSUInteger guardedMethodCount = 0;
    SEL setHiddenSelector = @selector(setHidden:);
    SEL setUserInteractionEnabledSelector = @selector(setUserInteractionEnabled:);
    SEL setAlphaSelector = @selector(setAlpha:);

    for (int classIndex = 0; classIndex < classCount; classIndex++) {
        Class candidateClass = classes[classIndex];
        if (!TFClassInheritsFromClass(candidateClass, [UIView class])) {
            continue;
        }

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(candidateClass, &methodCount);
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
            Method method = methods[methodIndex];
            SEL selector = method_getName(method);
            BOOL isBoolSetter = selector == setHiddenSelector || selector == setUserInteractionEnabledSelector;
            BOOL isFloatSetter = selector == setAlphaSelector;
            if ((!isBoolSetter && !isFloatSetter) ||
                !TFImplementationBelongsToImage(method_getImplementation(method), resolvedPlugInPath))
            {
                continue;
            }

            if (isBoolSetter) {
                TFInstallBoolSetterGuard(candidateClass, method);
            } else {
                TFInstallFloatSetterGuard(candidateClass, method);
            }
            guardedMethodCount++;
        }
        free(methods);
    }
    free(classes);
    return guardedMethodCount;
}

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
                    NSUInteger guardedCount = TFInstallReentrantUIKitSetterGuards(plugInPath);
                    if (guardedCount > 0) {
                        NSLog(@"[TrollFoolsLoader] Guarded %lu reentrant UIKit setter hook(s) from %@",
                              (unsigned long)guardedCount, relativePath);
                    }
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
