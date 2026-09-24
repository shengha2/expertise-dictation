// Standalone diagnostic only. No dictation code, credentials, or installed-app access.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#import <fcntl.h>
#import <unistd.h>

@interface FeedProbe : NSObject <NSApplicationDelegate, SPUUpdaterDelegate, SPUUserDriver>
@property SPUUpdater *updater;
@property NSMutableArray<NSDictionary *> *events;
@property NSString *expectation;
@property NSString *expectedVersion;
@property NSString *foundVersion;
@property NSString *latestVersion;
@property NSDate *started;
@property NSTimeInterval timeout;
@property NSInteger noUpdateReason;
@property BOOL loadedVerifiedFeed;
@property BOOL finished;
@property int reportFD;
@end

@implementation FeedProbe
- (NSDictionary *)itemDetails:(SUAppcastItem *)item {
    if (!item) return @{};
    return @{ @"version": item.versionString, @"downloadURL": item.fileURL.absoluteString ?: @"",
              @"contentLength": @(item.contentLength), @"minimumSystemVersion": item.minimumSystemVersion ?: @"",
              @"signingValidationStatus": @(item.signingValidationStatus) };
}
- (NSDictionary *)errorDetails:(NSError *)error {
    if (!error) return @{};
    NSMutableDictionary *value = [@{ @"domain": error.domain, @"code": @(error.code),
                                      @"description": error.localizedDescription } mutableCopy];
    NSNumber *reason = error.userInfo[SPUNoUpdateFoundReasonKey];
    if (reason) value[@"noUpdateReason"] = reason;
    SUAppcastItem *latest = error.userInfo[SPULatestAppcastItemFoundKey];
    if ([latest isKindOfClass:SUAppcastItem.class]) value[@"latestItem"] = [self itemDetails:latest];
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:NSError.class]) {
        value[@"underlying"] = @{ @"domain": underlying.domain, @"code": @(underlying.code),
                                  @"description": underlying.localizedDescription };
    }
    return value;
}
- (void)event:(NSString *)name details:(NSDictionary *)details {
    [self.events addObject:@{ @"callback": name, @"elapsedSeconds": @(-self.started.timeIntervalSinceNow),
                             @"details": details ?: @{} }];
}
- (void)finish:(int)status message:(NSString *)message {
    if (self.finished) return;
    self.finished = YES;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSDictionary *report = @{
        @"schemaVersion": @1, @"probe": @"Sparkle.checkForUpdateInformation", @"success": @(status == 0),
        @"exitCode": @(status), @"message": message, @"startedUTC": [NSISO8601DateFormatter.new stringFromDate:self.started],
        @"elapsedSeconds": @(-self.started.timeIntervalSinceNow), @"diagnosticBundleID": NSBundle.mainBundle.bundleIdentifier,
        @"currentVersion": info[@"CFBundleVersion"], @"expectedOutcome": self.expectation,
        @"expectedVersion": self.expectedVersion, @"feedURL": info[@"SUFeedURL"], @"publicKey": info[@"SUPublicEDKey"],
        @"verifiedSignedFeed": @(self.loadedVerifiedFeed), @"foundVersion": self.foundVersion ?: NSNull.null,
        @"latestVersion": self.latestVersion ?: NSNull.null, @"events": self.events,
        @"scope": @"Hosted feed fetch, Sparkle signature validation and version selection only; no archive download, installation or relaunch.",
        @"automaticChecks": @NO, @"automaticDownloads": @NO, @"installationAllowed": @NO
    };
    NSError *error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data || ftruncate(self.reportFD, 0) != 0 || lseek(self.reportFD, 0, SEEK_SET) < 0) {
        fprintf(stderr, "Could not encode or write probe report.\n");
        exit(74);
    }
    const uint8_t *bytes = data.bytes;
    NSUInteger written = 0;
    while (written < data.length) {
        ssize_t count = write(self.reportFD, bytes + written, data.length - written);
        if (count <= 0) { fprintf(stderr, "Could not write probe report.\n"); exit(74); }
        written += (NSUInteger)count;
    }
    if (write(self.reportFD, "\n", 1) != 1 || fsync(self.reportFD) != 0) exit(74);
    close(self.reportFD);
    printf("%s: %s\n", status == 0 ? "PASS" : "FAIL", message.UTF8String);
    // Exiting this diagnostic cannot trigger an install: no update was offered,
    // all non-probe checks are denied, and the user driver never accepts one.
    exit(status);
}
- (void)unexpected:(NSString *)operation {
    [self event:@"blockedUnexpectedOperation" details:@{ @"operation": operation }];
    [self finish:3 message:@"Sparkle requested a non-probe operation; execution stopped."];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.updater = [[SPUUpdater alloc] initWithHostBundle:NSBundle.mainBundle
                                      applicationBundle:NSBundle.mainBundle userDriver:self delegate:self];
    self.updater.automaticallyChecksForUpdates = NO;
    self.updater.automaticallyDownloadsUpdates = NO;
    self.updater.sendsSystemProfile = NO;
    [self event:@"probeStart" details:@{ @"currentVersion": NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] }];
    [NSTimer scheduledTimerWithTimeInterval:self.timeout repeats:NO block:^(NSTimer *timer) {
        [self event:@"timeout" details:@{ @"seconds": @(self.timeout) }];
        [self finish:124 message:@"Feed probe timed out."];
    }];
    NSError *error;
    if (![self.updater startUpdater:&error]) {
        [self event:@"startUpdaterFailed" details:[self errorDetails:error]];
        [self finish:2 message:@"Sparkle could not start the isolated feed probe."];
        return;
    }
    // The documented API supports this immediately after start, before the next
    // run-loop cycle. No checkForUpdates/install APIs are ever invoked.
    [self.updater checkForUpdateInformation];
}
- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    [self event:@"mayPerformUpdateCheck" details:@{ @"checkType": @(check) }];
    if (check == SPUUpdateCheckUpdateInformation) return YES;
    if (error) *error = [NSError errorWithDomain:@"ExpertiseFeedProbe" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Only information probing is allowed."}];
    [self unexpected:@"nonInformationUpdateCheck"];
    return NO;
}
- (BOOL)updater:(SPUUpdater *)updater shouldProceedWithUpdate:(SUAppcastItem *)item updateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    if (check == SPUUpdateCheckUpdateInformation) return YES;
    if (error) *error = [NSError errorWithDomain:@"ExpertiseFeedProbe" code:3 userInfo:nil];
    [self unexpected:@"proceedWithNonInformationUpdate"];
    return NO;
}
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater { return NO; }
- (NSArray<NSString *> *)allowedSystemProfileKeysForUpdater:(SPUUpdater *)updater { return @[]; }
- (void)updater:(SPUUpdater *)updater didFinishLoadingAppcast:(SUAppcast *)appcast {
    self.loadedVerifiedFeed = appcast.signingValidationStatus == SPUAppcastSigningValidationStatusSucceeded;
    NSMutableArray *items = NSMutableArray.new;
    for (SUAppcastItem *item in appcast.items) [items addObject:[self itemDetails:item]];
    [self event:@"didFinishLoadingAppcast" details:@{ @"signingValidationStatus": @(appcast.signingValidationStatus), @"items": items }];
}
- (void)updater:(SPUUpdater *)updater didFindValidUpdate:(SUAppcastItem *)item {
    self.foundVersion = item.versionString;
    [self event:@"didFindValidUpdate" details:[self itemDetails:item]];
}
- (void)updaterDidNotFindUpdate:(SPUUpdater *)updater error:(NSError *)error {
    self.noUpdateReason = [error.userInfo[SPUNoUpdateFoundReasonKey] integerValue];
    SUAppcastItem *latest = error.userInfo[SPULatestAppcastItemFoundKey];
    if ([latest isKindOfClass:SUAppcastItem.class]) self.latestVersion = latest.versionString;
    [self event:@"didNotFindUpdate" details:[self errorDetails:error]];
}
- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error {
    [self event:@"didAbortWithError" details:[self errorDetails:error]];
}
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    [self event:@"didFinishUpdateCycle" details:@{ @"checkType": @(check), @"error": [self errorDetails:error] }];
    if (check != SPUUpdateCheckUpdateInformation) { [self unexpected:@"nonInformationCompletion"]; return; }
    if (!self.loadedVerifiedFeed) { [self finish:2 message:@"A successfully verified signed feed was not observed."]; return; }
    if ([self.expectation isEqualToString:@"update"]) {
        BOOL match = !error && [self.foundVersion isEqualToString:self.expectedVersion];
        [self finish:match ? 0 : 1 message:match ? @"Sparkle verified the hosted feed and found the expected update." : @"The feed did not produce the expected update."];
    } else {
        BOOL benign = !error || ([error.domain isEqualToString:SUSparkleErrorDomain] && error.code == SUNoUpdateError);
        BOOL match = benign && !self.foundVersion && self.noUpdateReason == SPUNoUpdateFoundReasonOnLatestVersion && [self.latestVersion isEqualToString:self.expectedVersion];
        [self finish:match ? 0 : 1 message:match ? @"Sparkle verified the hosted feed and confirmed the current version is latest." : @"No-update result was not the expected latest-version outcome."];
    }
}
- (void)updater:(SPUUpdater *)updater willInstallUpdate:(SUAppcastItem *)item { [self unexpected:@"willInstallUpdate"]; }
- (BOOL)updaterShouldRelaunchApplication:(SPUUpdater *)updater { return NO; }

// Deliberately no GUI and no .install reply. These are fail-closed defenses;
// checkForUpdateInformation normally uses only the updater delegate callbacks.
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply { [self unexpected:@"permissionUI"]; }
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { cancellation(); [self unexpected:@"interactiveCheck"]; }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply { reply(SPUUserUpdateChoiceSkip); [self unexpected:@"offerUpdate"]; }
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data { [self unexpected:@"releaseNotes"]; }
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error { [self unexpected:@"releaseNotesFailure"]; }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement { [self event:@"userDriverNoUpdate" details:[self errorDetails:error]]; acknowledgement(); }
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement { [self event:@"userDriverError" details:[self errorDetails:error]]; acknowledgement(); }
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation { cancellation(); [self unexpected:@"archiveDownload"]; }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length { [self unexpected:@"archiveLength"]; }
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length { [self unexpected:@"archiveData"]; }
- (void)showDownloadDidStartExtractingUpdate { [self unexpected:@"archiveExtraction"]; }
- (void)showExtractionReceivedProgress:(double)progress { [self unexpected:@"extractionProgress"]; }
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { reply(SPUUserUpdateChoiceSkip); [self unexpected:@"readyToInstall"]; }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry { [self unexpected:@"installing"]; }
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement { [self unexpected:@"installed"]; }
- (void)dismissUpdateInstallation { [self event:@"dismissUpdateInstallation" details:@{}]; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableDictionary<NSString *, NSString *> *options = NSMutableDictionary.new;
        for (int i = 1; i < argc; i += 2) {
            if (i + 1 >= argc) { fprintf(stderr, "Expected --expect update|no-update --expected-version VERSION --report PATH [--timeout SECONDS].\n"); return 64; }
            options[@(argv[i])] = @(argv[i + 1]);
        }
        NSSet *allowed = [NSSet setWithArray:@[@"--expect", @"--expected-version", @"--report", @"--timeout"]];
        for (NSString *key in options) if (![allowed containsObject:key]) return 64;
        NSString *expectation = options[@"--expect"];
        NSString *report = options[@"--report"];
        NSTimeInterval timeout = options[@"--timeout"] ? options[@"--timeout"].doubleValue : 90;
        if (![@[@"update", @"no-update"] containsObject:expectation ?: @""] || !options[@"--expected-version"].length || !report.isAbsolutePath || timeout < 1 || timeout > 300) return 64;
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        if (![NSBundle.mainBundle.bundleIdentifier hasPrefix:@"com.hao.expertise-dictation.feed-probe."] ||
            [info[@"SUEnableAutomaticChecks"] boolValue] || [info[@"SUAutomaticallyUpdate"] boolValue] ||
            ![info[@"SURequireSignedFeed"] boolValue] || ![info[@"SUVerifyUpdateBeforeExtraction"] boolValue]) return 64;
        int fd = open(report.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (fd < 0) { perror("Cannot create new report (existing files are never replaced)"); return 73; }
        FeedProbe *probe = FeedProbe.new;
        probe.events = NSMutableArray.new; probe.started = NSDate.date; probe.expectation = expectation;
        probe.expectedVersion = options[@"--expected-version"]; probe.reportFD = fd;
        probe.timeout = timeout; probe.noUpdateReason = -1;
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        app.delegate = probe;
        [app run];
        return 3;
    }
}
