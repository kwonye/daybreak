#import "EvergreenStoreBridge.h"
#import <Security/Authorization.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <unistd.h>

// Only the selectors used here are declared. Frameworks are loaded at runtime,
// so an incompatible macOS version can continue using the public catalog.
@interface NSObject (DBCommerce)
+ (id)sharedDownloadQueue;
+ (id)sharedPurchaseController;
+ (id)purchaseWithBuyParameters:(NSString *)parameters;
- (void)setIsRedownload:(BOOL)flag;
- (void)setIsUpdate:(BOOL)flag;
- (void)setItemIdentifier:(uint64_t)identifier;
- (void)setDownloadMetadata:(id)metadata;
- (NSString *)addObserver:(id)observer;
- (void)removeObserver:(NSString *)token;
- (id)downloadForItemIdentifier:(uint64_t)identifier;
- (void)performPurchase:(id)purchase withOptions:(uint64_t)options
      completionHandler:(void (^)(id, BOOL, NSError *, id))handler;
- (NSArray *)downloads;
- (id)metadata;
- (uint64_t)itemIdentifier;
- (NSError *)error;
- (BOOL)isFailed;
- (BOOL)isCancelled;
@end

@protocol DBStoreDownload
- (id)status;
@end

@protocol DBStoreMetadata
- (instancetype)initWithKind:(NSString *)kind;
@end

typedef NSString *(*DownloadDirectory)(NSString *);
static DownloadDirectory downloadDirectory;
static BOOL loadCommerce(void) {
    static dispatch_once_t once;
    static BOOL available;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/StoreFoundation.framework/StoreFoundation", RTLD_LAZY | RTLD_LOCAL);
        void *commerce = dlopen("/System/Library/PrivateFrameworks/CommerceKit.framework/CommerceKit", RTLD_LAZY | RTLD_LOCAL);
        if (!commerce) return;
        downloadDirectory = (DownloadDirectory)dlsym(commerce, "CKDownloadDirectory");
        Class queue = NSClassFromString(@"CKDownloadQueue");
        Class controller = NSClassFromString(@"CKPurchaseController");
        Class purchase = NSClassFromString(@"SSPurchase");
        Class metadata = NSClassFromString(@"SSDownloadMetadata");
        Class download = NSClassFromString(@"SSDownload");
        Class status = NSClassFromString(@"SSDownloadStatus");
        available = downloadDirectory
            && [queue respondsToSelector:@selector(sharedDownloadQueue)]
            && [queue instancesRespondToSelector:@selector(addObserver:)]
            && [queue instancesRespondToSelector:@selector(removeObserver:)]
            && [queue instancesRespondToSelector:@selector(downloadForItemIdentifier:)]
            && [controller respondsToSelector:@selector(sharedPurchaseController)]
            && [controller instancesRespondToSelector:@selector(performPurchase:withOptions:completionHandler:)]
            && [purchase respondsToSelector:@selector(purchaseWithBuyParameters:)]
            && [purchase instancesRespondToSelector:@selector(setIsRedownload:)]
            && [purchase instancesRespondToSelector:@selector(setIsUpdate:)]
            && [purchase instancesRespondToSelector:@selector(setItemIdentifier:)]
            && [purchase instancesRespondToSelector:@selector(setDownloadMetadata:)]
            && [metadata instancesRespondToSelector:@selector(initWithKind:)]
            && [metadata instancesRespondToSelector:@selector(setItemIdentifier:)]
            && [metadata instancesRespondToSelector:@selector(itemIdentifier)]
            && [download instancesRespondToSelector:@selector(metadata)]
            && [download instancesRespondToSelector:@selector(status)]
            && [status instancesRespondToSelector:@selector(error)]
            && [status instancesRespondToSelector:@selector(isCancelled)]
            && [status instancesRespondToSelector:@selector(isFailed)];
    });
    return available;
}

BOOL DBStoreIsAvailable(void) { return loadCommerce(); }

@interface DBStoreRequest : NSObject
@property (nonatomic) uint64_t identifier;
@property (nonatomic, strong) id queue;
@property (nonatomic, copy) NSString *observer;
@property (nonatomic, strong) NSURL *staging;
@property (nonatomic, strong) NSURL *downloadFolder;
@property (nonatomic, copy) DBStoreCompletion completion;
@end

@implementation DBStoreRequest

- (void)finishInstalled:(BOOL)installed package:(NSURL *)package receipt:(NSURL *)receipt message:(NSString *)message {
    if (!self.completion) return;
    DBStoreCompletion completion = self.completion;
    self.completion = nil;
    if (self.observer) [self.queue removeObserver:self.observer];
    self.observer = nil;
    completion(installed, package, receipt, message);
}

// Preserve the store's files before it removes its temporary download directory.
- (void)saveLink:(NSURL *)source named:(NSString *)name {
    struct stat sourceInfo, savedInfo;
    NSURL *saved = [self.staging URLByAppendingPathComponent:name];
    if (lstat(source.fileSystemRepresentation, &sourceInfo) != 0 || !S_ISREG(sourceInfo.st_mode)) return;
    if (lstat(saved.fileSystemRepresentation, &savedInfo) == 0 &&
        sourceInfo.st_dev == savedInfo.st_dev && sourceInfo.st_ino == savedInfo.st_ino) return;
    NSURL *pending = [self.staging URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (link(source.fileSystemRepresentation, pending.fileSystemRepresentation) == 0) {
        rename(pending.fileSystemRepresentation, saved.fileSystemRepresentation);
        unlink(pending.fileSystemRepresentation);
    }
}

- (void)captureFiles {
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.downloadFolder
        includingPropertiesForKeys:@[] options:0 error:NULL];
    NSArray<NSURL *> *packages = [files filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSURL *file, NSDictionary *bindings) {
            return [file.pathExtension isEqualToString:@"pkg"];
        }]];
    // Multiple packages are ambiguous and aren't suitable for the local fallback.
    if (packages.count == 1) [self saveLink:packages.firstObject named:@"update.pkg"];
    else if (packages.count > 1) {
        NSURL *saved = [self.staging URLByAppendingPathComponent:@"update.pkg"];
        unlink(saved.fileSystemRepresentation);
    }
    [self saveLink:[self.downloadFolder URLByAppendingPathComponent:@"receipt"] named:@"receipt"];
}

- (void)downloadQueue:(id)queue changedWithAddition:(id)download {
    [self downloadQueue:queue statusChangedForDownload:download];
}

- (void)downloadQueue:(id)queue statusChangedForDownload:(id)download {
    if ([[download metadata] itemIdentifier] != self.identifier) return;
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.completion) [self captureFiles]; });
}

- (void)downloadQueue:(id)queue changedWithRemoval:(id)download {
    if ([[download metadata] itemIdentifier] != self.identifier) return;
    id status = [(id<DBStoreDownload>)download status];
    NSError *error = [status error];
    BOOL failed = !status || [status isFailed] || [status isCancelled];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.completion) return;
        if ([error.domain isEqualToString:@"PKInstallErrorDomain"] && error.code == 201) {
            [self captureFiles];
            NSURL *package = [self.staging URLByAppendingPathComponent:@"update.pkg"];
            NSURL *receipt = [self.staging URLByAppendingPathComponent:@"receipt"];
            if ([NSFileManager.defaultManager fileExistsAtPath:package.path] &&
                [NSFileManager.defaultManager fileExistsAtPath:receipt.path]) {
                [self finishInstalled:NO package:package receipt:receipt message:nil];
                return;
            }
        }
        [self finishInstalled:!failed && !error package:nil receipt:nil
                      message:(failed || error) ? @"The App Store couldn’t complete this update. Open the App Store to try again." : nil];
    });
}
@end

void DBStoreUpdate(uint64_t identifier, NSURL *staging, DBStoreCompletion reply) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!identifier || !loadCommerce()) {
            reply(NO, nil, nil, @"Direct App Store updates are unavailable on this Mac.");
            return;
        }
        id queue = [NSClassFromString(@"CKDownloadQueue") sharedDownloadQueue];
        NSString *folder = downloadDirectory(nil);
        if (!queue || !folder.isAbsolutePath || [queue downloadForItemIdentifier:identifier]) {
            reply(NO, nil, nil, @"An App Store download may already be in progress. Open the App Store to check.");
            return;
        }
        DBStoreRequest *request = [DBStoreRequest new];
        request.identifier = identifier;
        request.queue = queue;
        request.staging = staging;
        request.downloadFolder = [[NSURL fileURLWithPath:folder isDirectory:YES]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"%llu", identifier] isDirectory:YES];
        request.completion = reply;
        request.observer = [queue addObserver:request];
        if (!request.observer.length) {
            [request finishInstalled:NO package:nil receipt:nil message:@"Evergreen couldn’t observe the App Store download."];
            return;
        }

        // The store handles account ownership and any sign-in UI.
        NSString *query = [NSString stringWithFormat:
            @"productType=C&price=0&pg=default&appExtVrsId=0&pricingParameters=STDRDL&salableAdamId=%llu", identifier];
        id purchase = [NSClassFromString(@"SSPurchase") purchaseWithBuyParameters:query];
        [purchase setIsRedownload:YES];
        [purchase setIsUpdate:YES];
        [purchase setItemIdentifier:identifier];
        id<DBStoreMetadata> allocated = [NSClassFromString(@"SSDownloadMetadata") alloc];
        id metadata = [allocated initWithKind:@"software"];
        [metadata setItemIdentifier:identifier];
        [purchase setDownloadMetadata:metadata];
        id controller = [NSClassFromString(@"CKPurchaseController") sharedPurchaseController];
        if (!purchase || !metadata || !controller) {
            [request finishInstalled:NO package:nil receipt:nil message:@"The App Store couldn’t start this update."];
            return;
        }
        [controller performPurchase:purchase withOptions:0 completionHandler:^(id ignored, BOOL completed, NSError *error, id response) {
            if (!error && [response respondsToSelector:@selector(downloads)] && [[response downloads] count] > 0) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [request finishInstalled:NO package:nil receipt:nil
                    message:@"The App Store didn’t start this update. Check that you’re signed in with the account that acquired the app."];
            });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [request finishInstalled:NO package:nil receipt:nil
                message:@"The App Store hasn’t reported completion. Check its Updates page before trying again."];
        });
    });
}

int32_t DBRunStoreInstaller(const char *tool, NSArray<NSString *> *arguments, NSString **response) {
    AuthorizationRef authorization = NULL;
    OSStatus result = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &authorization);
    if (result != errAuthorizationSuccess) return result;
    AuthorizationItem item = { kAuthorizationRightExecute, (UInt32)strlen(tool) + 1, (void *)tool, 0 };
    AuthorizationRights rights = { 1, &item };
    result = AuthorizationCopyRights(authorization, &rights, kAuthorizationEmptyEnvironment,
        kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize, NULL);
    if (result == errAuthorizationSuccess) {
        char *argv[arguments.count + 1];
        for (NSUInteger i = 0; i < arguments.count; i++) argv[i] = (char *)arguments[i].fileSystemRepresentation;
        argv[arguments.count] = NULL;
        FILE *pipe = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // A one-shot installer. No resident service or credentials in Evergreen.
        result = AuthorizationExecuteWithPrivileges(authorization, tool, kAuthorizationFlagDefaults, argv, &pipe);
#pragma clang diagnostic pop
        if (result == errAuthorizationSuccess && pipe) {
            char message[512] = {0};
            if (fgets(message, sizeof(message), pipe)) *response = [NSString stringWithUTF8String:message];
            fclose(pipe);
        }
    }
    AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
    return result;
}
