#import "InputContextBridge.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <UIKit/UIKit.h>

static id WCObjectResult(id object, NSString *selectorName) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;

    @try {
        id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        return send(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id WCValue(id object, NSString *key) {
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// Rejects identifiers that are never a valid place to return to: this
// extension, its containing app (the arbiter names Mumla whenever the
// keyboard is used inside Mumla), and SpringBoard, which the arbiter
// reports transiently after the App Switcher or Home Screen has been on
// screen even though a real app still hosts the keyboard.
static BOOL WCIsUsableBundleIdentifier(NSString *value) {
    if (value.length == 0 || ![value containsString:@"."]) return NO;
    if ([value isEqualToString:@"com.apple.springboard"]) return NO;

    NSString *extensionIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if ([value isEqualToString:extensionIdentifier]) return NO;

    // An app extension's bundle ID is its containing app's plus one component.
    NSString *containingAppPrefix = [value stringByAppendingString:@"."];
    return ![extensionIdentifier hasPrefix:containingAppPrefix];
}

// The view-service parent carries the host process ID. It updates as soon as
// the keyboard is rehosted, which makes it the freshest signal available and
// therefore the reference the arbiter state is validated against.
static int WCHostProcessIdentifier(UIInputViewController *controller) {
    id hostController = controller.parentViewController;
    if (!hostController
        || !class_getInstanceVariable(object_getClass(hostController), "_hostPID")) {
        return 0;
    }

    id value = WCValue(hostController, @"_hostPID");
    if (![value respondsToSelector:@selector(intValue)]) return 0;
    int pid = [value intValue];
    return pid > 0 ? pid : 0;
}

static BOOL WCArbiterEnabledOverride(__unused id self, __unused SEL _cmd) {
    return YES;
}

// UIKit disables the keyboard arbiter client inside keyboard extensions, so the
// override is what lets the extension observe arbiter state at all. Applied
// once, and only when host identity is actually requested.
static void WCForceArbiterEnabled(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class arbiter = NSClassFromString(@"_UIKeyboardArbiterClient");
        if (!arbiter) return;
        Method method = class_getClassMethod(arbiter, NSSelectorFromString(@"enabled"));
        if (!method) return;
        method_setImplementation(method, (IMP)WCArbiterEnabledOverride);
    });
}

// Pulls current arbiter state rather than caching a swizzled callback, so there
// is nothing to go stale between reads. Verified on iOS 27.0 against
// third-party and Apple hosts alike; Apple bundle IDs are deliberately not
// filtered out. The state can briefly still describe the previous host right
// after an app switch, which is why callers resolve at the moment they need
// the value rather than reusing an appearance-time reading. Its
// hostProcessIdentifier is always 0 on iOS 27 and so cannot cross-check it.
static NSString *WCArbiterHostBundleIdentifier(void) {
    Class arbiterClass = NSClassFromString(@"_UIKeyboardArbiterClient");
    if (!arbiterClass) return nil;

    WCForceArbiterEnabled();

    @try {
        id client = WCObjectResult(arbiterClass, @"automaticSharedArbiterClient");
        if (!client) return nil;

        // The connection is cold on the first appearance in a new host; the
        // ping brings it up so the state read below has something to return.
        WCObjectResult(client, @"checkConnection");

        id state = WCObjectResult(client, @"currentClientState");
        if (!state) return nil;

        NSString *identifier = WCObjectResult(state, @"sourceBundleIdentifier");
        if (!WCIsUsableBundleIdentifier(identifier)) {
            identifier = WCObjectResult(state, @"hostBundleIdentifier");
        }
        return WCIsUsableBundleIdentifier(identifier) ? identifier : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// iOS 26.4 stopped resolving the host through this XPC route; it is retained
// only as a fallback for runtimes where the arbiter surface is absent.
static NSString *WCPlugInKitHostBundleIdentifier(int hostProcessIdentifier) {
    if (hostProcessIdentifier <= 0) return nil;

    Class serviceClass = NSClassFromString(@"PKService");
    id service = WCObjectResult(serviceClass, @"defaultService");
    id personalities = WCObjectResult(service, @"personalities");
    NSString *extensionIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (![personalities isKindOfClass:NSDictionary.class]
        || extensionIdentifier.length == 0) {
        return nil;
    }

    id extensionPersonality = ((NSDictionary *)personalities)[extensionIdentifier];
    if (![extensionPersonality isKindOfClass:NSDictionary.class]) return nil;

    id hostInfo = ((NSDictionary *)extensionPersonality)[@(hostProcessIdentifier)];
    id connection = WCObjectResult(hostInfo, @"connection");
    id transport = WCObjectResult(connection, @"_xpcConnection");
    if (!transport) return nil;

    void *library = dlopen("/usr/lib/libc.dylib", RTLD_NOW);
    if (!library) return nil;

    typedef char *(*WCCopyBundleIdentifier)(void *);
    WCCopyBundleIdentifier copyBundleIdentifier =
        (WCCopyBundleIdentifier)dlsym(library, "xpc_connection_copy_bundle_id");
    if (!copyBundleIdentifier) {
        dlclose(library);
        return nil;
    }

    char *copiedIdentifier = copyBundleIdentifier((__bridge void *)transport);
    NSString *bundleIdentifier = copiedIdentifier
        ? [NSString stringWithUTF8String:copiedIdentifier]
        : nil;
    free(copiedIdentifier);
    dlclose(library);

    return WCIsUsableBundleIdentifier(bundleIdentifier) ? bundleIdentifier : nil;
}

// Keyboard extensions have no public host-identity API. Both strategies return
// nil on any unsupported runtime state, so the manual return flow stays intact
// whenever the host cannot be identified.
NSString *WCResolveHostBundleIdentifier(UIInputViewController *controller) {
    int hostProcessIdentifier = WCHostProcessIdentifier(controller);

    NSString *identifier = WCArbiterHostBundleIdentifier();
    if (identifier) return identifier;

    return WCPlugInKitHostBundleIdentifier(hostProcessIdentifier);
}

int WCResolveHostProcessIdentifier(UIInputViewController *controller) {
    return WCHostProcessIdentifier(controller);
}


#if DEBUG

// Diagnostics for the host-identity mechanism, which depends on undocumented
// runtime state and therefore needs re-verification on every new OS. Reports
// the resolver's answer next to the raw arbiter reading it came from.
NSDictionary<NSString *, NSString *> *WCProbeHostBundleIdentifiers(
    UIInputViewController *controller,
    NSString *resolvedBundleIdentifier
) {
    int hostProcessIdentifier = WCHostProcessIdentifier(controller);

    NSString *arbiterState = @"- unavailable";
    NSString *arbiterProcessIdentifier = @"- unavailable";
    Class arbiterClass = NSClassFromString(@"_UIKeyboardArbiterClient");
    if (arbiterClass) {
        WCForceArbiterEnabled();
        @try {
            id client = WCObjectResult(arbiterClass, @"automaticSharedArbiterClient");
            WCObjectResult(client, @"checkConnection");
            id state = WCObjectResult(client, @"currentClientState");
            if (state) {
                NSString *source = WCObjectResult(state, @"sourceBundleIdentifier");
                arbiterState = source.length > 0 ? source : @"- no sourceBundleIdentifier";
                id statePID = WCValue(state, @"hostProcessIdentifier");
                if ([statePID respondsToSelector:@selector(intValue)]) {
                    arbiterProcessIdentifier = @([statePID intValue]).stringValue;
                }
            } else {
                arbiterState = @"- no currentClientState";
            }
        } @catch (NSException *exception) {
            arbiterState = [@"- exception: " stringByAppendingString:exception.name];
        }
    }

    return @{
        @"resolved": resolvedBundleIdentifier.length > 0
            ? resolvedBundleIdentifier
            : @"- nil",
        @"arbiter_raw": arbiterState,
        @"arbiter_hostPID": arbiterProcessIdentifier,
        @"viewService_hostPID": hostProcessIdentifier > 0
            ? @(hostProcessIdentifier).stringValue
            : @"- unavailable",
        @"os": UIDevice.currentDevice.systemVersion,
    };
}

#endif
