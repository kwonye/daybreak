#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A successful system install has no fallback artifacts. The package and receipt
// are provided together only when PackageKit requires a local installation.
typedef void (^DBStoreCompletion)(BOOL installed, NSURL * _Nullable package,
                                  NSURL * _Nullable receipt, NSString * _Nullable message);

BOOL DBStoreIsAvailable(void);
void DBStoreUpdate(uint64_t identifier, NSURL *staging, DBStoreCompletion reply);

// Returns a fixed status message from the one-shot installer, or an OSStatus.
int32_t DBRunStoreInstaller(const char *tool, NSArray<NSString *> *arguments,
                            NSString * _Nullable * _Nonnull response);

NS_ASSUME_NONNULL_END
