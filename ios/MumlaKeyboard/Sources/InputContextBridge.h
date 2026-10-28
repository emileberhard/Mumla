#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class UIInputViewController;

FOUNDATION_EXPORT NSString * _Nullable WCResolveHostBundleIdentifier(
    UIInputViewController *controller
) __attribute__((visibility("hidden")));

/// Process ID of the app currently hosting the keyboard, or 0. Unlike the
/// resolved bundle identifier this stays stable across transitions, so it is
/// the key a resolved identifier is remembered under.
FOUNDATION_EXPORT int WCResolveHostProcessIdentifier(
    UIInputViewController *controller
) __attribute__((visibility("hidden")));

#if DEBUG
/// Runs every known host-identity strategy and reports each one's result, so a
/// device run can rank them on the current OS. Values are bundle identifiers or
/// a short failure reason. Debug-only: it touches private runtime surface that
/// must never ship.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *WCProbeHostBundleIdentifiers(
    UIInputViewController *controller,
    NSString * _Nullable resolvedBundleIdentifier
) __attribute__((visibility("hidden")));
#endif

NS_ASSUME_NONNULL_END
