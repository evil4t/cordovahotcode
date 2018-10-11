//
//  HCPUpdateLoaderWorker.m
//
//  Created by Nikolay Demyankov on 11.08.15.
//

#import "HCPCheckUpdateWorker.h"
#import "NSJSONSerialization+HCPExtension.h"
#import "HCPApplicationConfigStorage.h"
#import "HCPFileDownloader.h"
#import "HCPDataDownloader.h"
#import "HCPEvents.h"
#import "NSError+HCPExtension.h"
#import "HCPUpdateInstaller.h"
#import "HCPContentManifest.h"
#import "HCPLog.h"

@interface HCPCheckUpdateWorker() {
    NSURL *_configURL;
    HCPFilesStructure *_pluginFiles;
    NSUInteger _nativeInterfaceVersion;
    
    id<HCPConfigFileStorage> _appConfigStorage;
    id<HCPConfigFileStorage> _manifestStorage;
    
    HCPApplicationConfig *_oldAppConfig;
    HCPContentManifest *_oldManifest;
    
    NSDictionary *_requestHeaders;
    
    void (^_complitionBlock)(void);
}

@property (nonatomic, strong, readwrite) NSString *workerId;

@end

@implementation HCPCheckUpdateWorker

#pragma mark Public API

- (instancetype)initWithRequest:(HCPUpdateRequest *)request {
    self = [super init];
    if (self) {
        _configURL = [request.configURL copy];
        _requestHeaders = [request.requestHeaders copy];
        _nativeInterfaceVersion = request.currentNativeVersion;
        _workerId = [self generateWorkerId];
        _pluginFiles = [[HCPFilesStructure alloc] initWithReleaseVersion:request.currentWebVersion];
        _appConfigStorage = [[HCPApplicationConfigStorage alloc] initWithFileStructure:_pluginFiles];
        NSLog(@"HCP_LOG : HCPUpdateLoaderWorker init configURL %@ nativeInterfaceVersion %ld workerId %@", [_configURL absoluteString], _nativeInterfaceVersion, _workerId);
    }
    
    return self;
}

- (void)run {
    [self runWithComplitionBlock:nil];
}

// TODO: refactoring is required after merging https://github.com/nordnet/cordova-hot-code-push/pull/55.
// To reduce merge conflicts leaving it as it is for now.
- (void)runWithComplitionBlock:(void (^)(void))updateLoaderComplitionBlock {
    NSLog(@"HCP_LOG : HCPCheckUpdateWorker runWithComplitionBlock");
    _complitionBlock = updateLoaderComplitionBlock;
    // initialize before the run
    NSError *error = nil;
    if (![self loadLocalConfigs:&error]) {
        [self notifyWithError:error applicationConfig:nil];
        return;
    }
    
    HCPDataDownloader *configDownloader = [[HCPDataDownloader alloc] init];
    
    // download new application config
    [configDownloader downloadDataFromUrl:_configURL requestHeaders:_requestHeaders completionBlock:^(NSData *data, NSError *error) {
        NSLog(@"HCP_LOG : HCPCheckUpdateWorker configURL %@", [_configURL absoluteString]);
        HCPApplicationConfig *newAppConfig = [self getApplicationConfigFromData:data error:&error];
        if (newAppConfig == nil) {
            NSLog(@"HCP_LOG : HCPCheckUpdateWorker newAppConfig null --> notifyWithError code %ld", kHCPFailedToDownloadApplicationConfigErrorCode);
            [self notifyWithError:[NSError errorWithCode:kHCPFailedToDownloadApplicationConfigErrorCode descriptionFromError:error]
                applicationConfig:nil];
            return;
        }
        // check if new version is available
        if ([newAppConfig.contentConfig.releaseVersion isEqualToString:_oldAppConfig.contentConfig.releaseVersion]) {
            NSLog(@"HCP_LOG : HCPCheckUpdateWorker check if new version is available --> notifyNothingToUpdate");
            [self notifyNothingToUpdate:newAppConfig];
            return;
        }
        
        // check if current native version supports new content
        if (newAppConfig.contentConfig.minimumNativeVersion > _nativeInterfaceVersion) {
            NSLog(@"HCP_LOG : HCPCheckUpdateWorker Application build version is too low for this update %ld > %ld --> notifyWithError code %ld", newAppConfig.contentConfig.minimumNativeVersion, _nativeInterfaceVersion, kHCPApplicationBuildVersionTooLowErrorCode);
            [self notifyWithError:[NSError errorWithCode:kHCPApplicationBuildVersionTooLowErrorCode
                                             description:@"Application build version is too low for this update"]
                applicationConfig:newAppConfig];
            return;
        }
        
        [self notifyCheckUpdateSuccess:newAppConfig];
    }];

}

#pragma mark Private API

- (HCPApplicationConfig *)getApplicationConfigFromData:(NSData *)data error:(NSError **)error {
    if (*error) {
        NSLog(@"HCP_LOG : HCPCheckUpdateWorker getApplicationConfigFromData error %@", [*error localizedDescription]);
        return nil;
    }
    
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:error];
    if (*error) {
        NSLog(@"HCP_LOG : HCPCheckUpdateWorker getApplicationConfigFromData NSJSONSerialization error %@", [*error localizedDescription]);
        return nil;
    }
    NSLog(@"HCP_LOG : HCPCheckUpdateWorker HCPApplicationConfig instanceFromJsonObject %@", json);
    return [HCPApplicationConfig instanceFromJsonObject:json];
}

/**
 *  Load configuration files from the file system.
 *
 *  @param error object to fill with error data if something will go wrong
 *
 *  @return <code>YES</code> if configs are loaded; <code>NO</code> - if some of the configs not found on file system
 */
- (BOOL)loadLocalConfigs:(NSError **)error {
    *error = nil;
    _oldAppConfig = [_appConfigStorage loadFromFolder:_pluginFiles.wwwFolder];
    if (_oldAppConfig == nil) {
        *error = [NSError errorWithCode:kHCPLocalVersionOfApplicationConfigNotFoundErrorCode
                            description:@"Failed to load current application config"];
        NSLog(@"HCP_LOG : HCPCheckUpdateWorker Failed to load current application config %@", [*error localizedDescription]);
        return NO;
    }
    
    return YES;
}

/**
 *  Send notification with error details.
 *
 *  @param error  occured error
 *  @param config application config that was used for download
 */
- (void)notifyWithError:(NSError *)error applicationConfig:(HCPApplicationConfig *)config {
    if (_complitionBlock) {
        _complitionBlock();
    }
     NSLog(@"HCP_LOG : HCPCheckUpdateWorker notifyWithError kHCPUpdateDownloadErrorEvent");
    NSNotification *notification = [HCPEvents notificationWithName:kHCPUpdateDownloadErrorEvent
                                                 applicationConfig:config
                                                            taskId:self.workerId
                                                             error:error];
    
    [[NSNotificationCenter defaultCenter] postNotification:notification];
}

/**
 *  Send notification that there is nothing to update and we are up-to-date
 *
 *  @param config application config that was used for download
 */
- (void)notifyNothingToUpdate:(HCPApplicationConfig *)config {
    if (_complitionBlock) {
        _complitionBlock();
    }
    NSLog(@"HCP_LOG : HCPCheckUpdateWorker notifyNothingToUpdate");
    NSError *error = [NSError errorWithCode:kHCPNothingToUpdateErrorCode description:@"Nothing to update"];
    NSNotification *notification = [HCPEvents notificationWithName:kHCPNothingToUpdateEvent
                                                 applicationConfig:config
                                                            taskId:self.workerId
                                                             error:error];
    
    [[NSNotificationCenter defaultCenter] postNotification:notification];
}

/**
 *  Send notification that update is loaded and ready for installation.
 *
 *  @param config application config that was used for download
 */
- (void)notifyCheckUpdateSuccess:(HCPApplicationConfig *)config {
    if (_complitionBlock) {
        _complitionBlock();
    }
    NSLog(@"HCP_LOG : HCPCheckUpdateWorker notifyCheckUpdateSuccess");
    NSNotification *notification = [HCPEvents notificationWithName:kHCPCheckUpdateSuccessEvent
                                                 applicationConfig:config
                                                            taskId:self.workerId];
    
    [[NSNotificationCenter defaultCenter] postNotification:notification];
}


/**
 *  Create id of the download worker.
 *
 *  @return worker id
 */
- (NSString *)generateWorkerId {
    NSTimeInterval millis = [[NSDate date] timeIntervalSince1970];
    
    return [NSString stringWithFormat:@"%f",millis];
}

@end
