//
//  HCPDoUpdateWorker.m
//
//  Created by Nikolay Demyankov on 11.08.15.
//

#import "HCPDoUpdateWorker.h"
#import "NSJSONSerialization+HCPExtension.h"
#import "HCPManifestDiff.h"
#import "HCPManifestFile.h"
#import "HCPApplicationConfigStorage.h"
#import "HCPContentManifestStorage.h"
#import "HCPFileDownloader.h"
#import "HCPDataDownloader.h"
#import "HCPEvents.h"
#import "NSError+HCPExtension.h"
#import "HCPUpdateInstaller.h"
#import "HCPContentManifest.h"
#import "HCPLog.h"
#import "HCPPlugin.h"

@interface HCPDoUpdateWorker() {
    HCPFilesStructure *_pluginFiles;
    
    id<HCPConfigFileStorage> _appConfigStorage;
    id<HCPConfigFileStorage> _manifestStorage;
    
    HCPApplicationConfig *_oldAppConfig;
    HCPContentManifest *_oldManifest;
    
    NSDictionary *_requestHeaders;
    
    HCPApplicationConfig *newAppConfig;
    
    HCPFilesDownloadConfig *filesConfig;
    
    NSUInteger filesCount;
    
    HCPFileDownloader *downloader;
    
    HCPContentManifest *newManifest;
    
    NSInteger isNeedRetry;
    
    dispatch_semaphore_t sema;
    
    void (^_complitionBlock)(void);
}

@property (nonatomic, strong, readwrite) NSString *workerId;

@end

@implementation HCPDoUpdateWorker

#pragma mark Public API

- (instancetype)initWithRequest:(HCPUpdateRequest *)request config:(HCPApplicationConfig *)appConfig {
    self = [super init];
    if (self) {
        _requestHeaders = [request.requestHeaders copy];
        _workerId = [self generateWorkerId];
        _pluginFiles = [[HCPFilesStructure alloc] initWithReleaseVersion:request.currentWebVersion];
        _appConfigStorage = [[HCPApplicationConfigStorage alloc] initWithFileStructure:_pluginFiles];
        _manifestStorage = [[HCPContentManifestStorage alloc] initWithFileStructure:_pluginFiles];
        newAppConfig = appConfig;
        NSDictionary *config = @{@"totalfiles":[NSNumber numberWithInteger:0], @"currentfile":[NSNumber numberWithInteger:0]};
        filesConfig = [HCPFilesDownloadConfig instanceFromJsonObject:config];
        filesCount = 0;
        isNeedRetry = -1;
        sema = dispatch_semaphore_create(0);
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onNeedRetry:) name:@"xxxxxxxxxxNeedRetry" object:nil];
        NSLog(@"HCP_LOG : HCPDoUpdateWorker init workerId %@", _workerId);
    }
    return self;
}

- (void)onNeedRetry:(NSNotification *)notObj {
    isNeedRetry = [notObj.object integerValue];
    dispatch_semaphore_signal(sema);
    NSLog(@"HCP_LOG : onNeedRetry:%ld", isNeedRetry);
}

// TODO: refactoring is required after merging https://github.com/nordnet/cordova-hot-code-push/pull/55.
// To reduce merge conflicts leaving it as it is for now.
- (void)runWithComplitionBlock:(void (^)(void))updateLoaderComplitionBlock {
    NSLog(@"HCP_LOG : HCPDoUpdateWorker runWithComplitionBlock");
    _complitionBlock = updateLoaderComplitionBlock;
    
    // initialize before the run
    NSError *error = nil;
    if (![self loadLocalConfigs:&error]) {
        NSLog(@"HCP_LOG : HCPDoUpdateWorker loadLocalConfigsnotifyWithError %@", [error localizedDescription]);
        [self notifyWithError:error applicationConfig:nil];
        return;
    }
    
    HCPDataDownloader *configDownloader = [[HCPDataDownloader alloc] init];
        
    // download new content manifest
    NSURL *manifestFileURL = [newAppConfig.contentConfig.contentURL URLByAppendingPathComponent:_pluginFiles.manifestFileName];
    [configDownloader downloadDataFromUrl:manifestFileURL requestHeaders:_requestHeaders completionBlock:^(NSData *data, NSError *error) {
        NSLog(@"HCP_LOG : HCPDoUpdateWorker manifestFileURL %@", [manifestFileURL absoluteString]);
        newManifest = [self getManifestConfigFromData:data error:&error];
        if (newManifest == nil) {
            NSLog(@"HCP_LOG : HCPDoUpdateWorker newManifest null --> notifyWithError code %ld", kHCPFailedToDownloadContentManifestErrorCode);
            [self notifyWithError:[NSError errorWithCode:kHCPFailedToDownloadContentManifestErrorCode
                                        descriptionFromError:error]
                applicationConfig:newAppConfig];
            return;
        }
            
        // compare manifests to find out if anything has changed since the last update
        HCPManifestDiff *manifestDiff = [_oldManifest calculateDifference:newManifest];
        if (manifestDiff.isEmpty) {
            [_manifestStorage store:newManifest inFolder:_pluginFiles.wwwFolder];
            [_appConfigStorage store:newAppConfig inFolder:_pluginFiles.wwwFolder];
            NSLog(@"HCP_LOG : HCPDoUpdateWorker manifestDiff isEmpty --> notifyNothingToUpdate");
            [self notifyNothingToUpdate:newAppConfig];
            return;
        }
            
        // switch file structure to new release
        _pluginFiles = [[HCPFilesStructure alloc] initWithReleaseVersion:newAppConfig.contentConfig.releaseVersion];
        NSLog(@"HCP_LOG : HCPDoUpdateWorker switch file structure to new release");
        // create new download folder
        [self createNewReleaseDownloadFolder:_pluginFiles.downloadFolder];
            
        // if there is anything to load - do that
        NSArray *updatedFiles = manifestDiff.updateFileList;
        if (updatedFiles.count > 0) {
            filesCount = updatedFiles.count;
            NSDictionary *config = @{@"totalfiles":[NSNumber numberWithInteger:updatedFiles.count], @"currentfile":[NSNumber numberWithInteger:0]};
            filesConfig = [HCPFilesDownloadConfig instanceFromJsonObject:config];
            NSLog(@"HCP_LOG : HCPDoUpdateWorker pdatedFiles count %ld --> notifyDownloadFilesTotalCount", updatedFiles.count);
            [self notifyDownloadFilesTotalCount:filesConfig];
            [self downloadUpdatedFiles:updatedFiles appConfig:newAppConfig manifest:newManifest];
            return;
        }
            
        // otherwise - update holds only files for deletion;
        // just save new configs and notify subscribers about success
        [_manifestStorage store:newManifest inFolder:_pluginFiles.downloadFolder];
        [_appConfigStorage store:newAppConfig inFolder:_pluginFiles.downloadFolder];
        NSLog(@"HCP_LOG : HCPDoUpdateWorker update holds only files for deletion --> notifyUpdateDownloadSuccess");
        [self notifyUpdateDownloadSuccess:newAppConfig];
    }];
}

#pragma mark Private API

- (void)run {
    [self runWithComplitionBlock:nil];
}

- (void)downloadUpdatedFiles:(NSArray *)updatedFiles
                   appConfig:(HCPApplicationConfig *)_newAppConfig
                    manifest:(HCPContentManifest *)newManifest {
    
    // download files
    downloader = [[HCPFileDownloader alloc] initWithFiles:updatedFiles
                                                                   srcDirURL:_newAppConfig.contentConfig.contentURL
                                                                   dstDirURL:_pluginFiles.downloadFolder
                                                              requestHeaders:_requestHeaders];
    
    [downloader startDownloadWithCompletionBlock:^(id message) {
        NSLog(@"HCP_LOG : HCPDoUpdateWorker downloadUpdatedFiles startDownloadWithCompletionBlock");
        if (message) {
            if ([message isKindOfClass: [NSError class]]) {
                
                NSError *error = (NSError *)message;
                NSLog(@"HCP_LOG : HCPDoUpdateWorker downloadUpdatedFiles --> notifyWithError code %ld", kHCPFailedToDownloadUpdateFilesErrorCode);
                [self notifyWithError:[NSError errorWithCode:kHCPFailedToDownloadUpdateFilesErrorCode
                                        descriptionFromError:error]
                    applicationConfig:_newAppConfig];
                isNeedRetry = -1;
                NSLog(@"HCP_LOG : HCPDoUpdateWorker dispatch_semaphore_wait");
                dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
                NSLog(@"HCP_LOG : HCPDoUpdateWorker get singal %ld", isNeedRetry);
                if (isNeedRetry == 1) {
                    NSLog(@"HCP_LOG : HCPDoUpdateWorker retryDownloadWithCompletionBlock");
                    [downloader retryDownloadWithCompletionBlock];
                } else {
                    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"xxxxxxxxxxNeedRetry" object:nil];
                    // remove new release folder
                    [[NSFileManager defaultManager] removeItemAtURL:_pluginFiles.contentFolder error:nil];
                    
                    // notify about the error
                    NSLog(@"HCP_LOG : HCPDoUpdateWorker remove new release folder --> notifyWithError code %ld", KHCPFailedToRemoveNewReleaseFolderErrorCode);
                    
                    [self notifyWithError:[NSError errorWithCode:KHCPFailedToRemoveNewReleaseFolderErrorCode
                                            descriptionFromError:nil]
                        applicationConfig:newAppConfig];
                    return;
                }
            } else if ([message isKindOfClass: [NSNumber class]]) {
                NSNumber *currentCount = (NSNumber *)message;
                NSDictionary *config = @{@"totalfiles":[NSNumber numberWithInteger:filesCount], @"currentfile":currentCount};
                filesConfig = [HCPFilesDownloadConfig instanceFromJsonObject:config];
                 NSLog(@"HCP_LOG : HCPDoUpdateWorker pdatedFiles count %@ --> notifyDownloadFilesCurrentCount", currentCount);
                [self notifyDownloadFilesTotalCount:filesConfig];
            }
        } else {
                  
            // store configs
            [_manifestStorage store:newManifest inFolder:_pluginFiles.downloadFolder];
            [_appConfigStorage store:_newAppConfig inFolder:_pluginFiles.downloadFolder];
                  
            // notify that we are done
            NSLog(@"HCP_LOG : HCPDoUpdateWorker notify that we are done --> notifyUpdateDownloadSuccess");
            [self notifyUpdateDownloadSuccess:_newAppConfig];
        }
    }];
}

- (HCPApplicationConfig *)getApplicationConfigFromData:(NSData *)data error:(NSError **)error {
    if (*error) {
        NSLog(@"HCP_LOG : HCPDoUpdateWorker getApplicationConfigFromData error %@", [*error localizedDescription]);
        return nil;
    }
    
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:error];
    if (*error) {
        NSLog(@"HCP_LOG : HCPDoUpdateWorker getApplicationConfigFromData NSJSONSerialization error %@", [*error localizedDescription]);
        return nil;
    }
    NSLog(@"HCP_LOG : HCPDoUpdateWorker HCPApplicationConfig instanceFromJsonObject %@", json);
    return [HCPApplicationConfig instanceFromJsonObject:json];
}

- (HCPContentManifest *)getManifestConfigFromData:(NSData *)data error:(NSError **)error {
    if (*error) {
        NSLog(@"HCP_LOG : HCPDoUpdateWorker getManifestConfigFromData error %@", [*error localizedDescription]);
        return nil;
    }
    
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:error];
    if (*error) {
        NSLog(@"HCP_LOG : HCPDoUpdateWorker getManifestConfigFromData NSJSONSerialization error %@", [*error localizedDescription]);
        return nil;
    }
    NSLog(@"HCP_LOG : HCPDoUpdateWorker HCPContentManifest instanceFromJsonObject %@", json);
    return [HCPContentManifest instanceFromJsonObject:json];
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
        NSLog(@"HCP_LOG : HCPDoUpdateWorker Failed to load current application config %@", [*error localizedDescription]);
        return NO;
    }
    
    _oldManifest = [_manifestStorage loadFromFolder:_pluginFiles.wwwFolder];
    if (_oldManifest == nil) {
        *error = [NSError errorWithCode:kHCPLocalVersionOfManifestNotFoundErrorCode
                            description:@"Failed to load current manifest file"];
        NSLog(@"HCP_LOG : HCPDoUpdateWorker Failed to load current manifest file %@", [*error localizedDescription]);
        return NO;
    }
    NSLog(@"HCP_LOG : HCPDoUpdateWorker loadLocalConfigs YES");
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
    NSLog(@"HCP_LOG : HCPDoUpdateWorker notifyWithError kHCPUpdateDownloadErrorEvent");
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
    NSLog(@"HCP_LOG : HCPDoUpdateWorker notifyNothingToUpdate");
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
- (void)notifyUpdateDownloadSuccess:(HCPApplicationConfig *)config {
    if (_complitionBlock) {
        _complitionBlock();
    }
    NSLog(@"HCP_LOG : HCPDoUpdateWorker notifyUpdateDownloadSuccess");
    NSNotification *notification = [HCPEvents notificationWithName:kHCPUpdateIsReadyForInstallationEvent
                                                 applicationConfig:config
                                                            taskId:self.workerId];
    
    [[NSNotificationCenter defaultCenter] postNotification:notification];
}

- (void)notifyDownloadFilesTotalCount:(HCPFilesDownloadConfig *)config {
    if (_complitionBlock) {
        _complitionBlock();
    }
    NSLog(@"HCP_LOG : HCPDoUpdateWorker notifyDownloadFilesTotalCount");
    NSNotification *notification = [HCPEvents notificationWithName:KHCPFileDownloaded
                                               filesDownloadConfig:config
                                                            taskId:self.workerId];
    
    [[NSNotificationCenter defaultCenter] postNotification:notification];
}

/**
 *  Remove old version of download folder and create the new one.
 *
 *  @param downloadFolder url to the download folder
 */
- (void)createNewReleaseDownloadFolder:(NSURL *)downloadFolder {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSError *error = nil;
    if ([fileManager fileExistsAtPath:downloadFolder.path]) {
        [fileManager removeItemAtURL:downloadFolder error:&error];
    }
    NSLog(@"HCP_LOG : HCPDoUpdateWorker create new download folder %@", downloadFolder.path);
    [fileManager createDirectoryAtURL:downloadFolder withIntermediateDirectories:YES attributes:nil error:&error];
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
