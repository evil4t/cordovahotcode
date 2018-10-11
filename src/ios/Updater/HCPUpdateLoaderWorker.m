//
//  HCPUpdateLoaderWorker.m
//
//  Created by Nikolay Demyankov on 11.08.15.
//

#import "HCPUpdateLoaderWorker.h"
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

@interface HCPUpdateLoaderWorker() {
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

@implementation HCPUpdateLoaderWorker

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
        _manifestStorage = [[HCPContentManifestStorage alloc] initWithFileStructure:_pluginFiles];
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
    NSLog(@"HCP_LOG : HCPUpdateLoaderWorker runWithComplitionBlock");
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
        NSLog(@"HCP_LOG : HCPUpdateLoaderWorker configURL %@", [_configURL absoluteString]);
        HCPApplicationConfig *newAppConfig = [self getApplicationConfigFromData:data error:&error];
        if (newAppConfig == nil) {
            NSLog(@"HCP_LOG : HCPUpdateLoaderWorker newAppConfig null --> notifyWithError code %ld", kHCPFailedToDownloadApplicationConfigErrorCode);
            [self notifyWithError:[NSError errorWithCode:kHCPFailedToDownloadApplicationConfigErrorCode descriptionFromError:error]
                applicationConfig:nil];
            return;
        }
        
        // check if new version is available
        if ([newAppConfig.contentConfig.releaseVersion isEqualToString:_oldAppConfig.contentConfig.releaseVersion]) {
            NSLog(@"HCP_LOG : HCPUpdateLoaderWorker check if new version is available --> notifyNothingToUpdate");
            [self notifyNothingToUpdate:newAppConfig];
            return;
        }
        
        // check if current native version supports new content
        if (newAppConfig.contentConfig.minimumNativeVersion > _nativeInterfaceVersion) {
            NSLog(@"HCP_LOG : HCPUpdateLoaderWorker Application build version is too low for this update %ld > %ld --> notifyWithError code %ld", newAppConfig.contentConfig.minimumNativeVersion, _nativeInterfaceVersion, kHCPApplicationBuildVersionTooLowErrorCode);
            [self notifyWithError:[NSError errorWithCode:kHCPApplicationBuildVersionTooLowErrorCode
                                             description:@"Application build version is too low for this update"]
                applicationConfig:newAppConfig];
            return;
        }
        
        // download new content manifest
        NSURL *manifestFileURL = [newAppConfig.contentConfig.contentURL URLByAppendingPathComponent:_pluginFiles.manifestFileName];
        [configDownloader downloadDataFromUrl:manifestFileURL requestHeaders:_requestHeaders completionBlock:^(NSData *data, NSError *error) {
            NSLog(@"HCP_LOG : HCPUpdateLoaderWorker manifestFileURL %@", [manifestFileURL absoluteString]);
            HCPContentManifest *newManifest = [self getManifestConfigFromData:data error:&error];
            if (newManifest == nil) {
                NSLog(@"HCP_LOG : HCPUpdateLoaderWorker newManifest null --> notifyWithError code %ld", kHCPFailedToDownloadContentManifestErrorCode);
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
                NSLog(@"HCP_LOG : HCPUpdateLoaderWorker manifestDiff isEmpty --> notifyNothingToUpdate");
                [self notifyNothingToUpdate:newAppConfig];
                return;
            }
            
            // switch file structure to new release
            _pluginFiles = [[HCPFilesStructure alloc] initWithReleaseVersion:newAppConfig.contentConfig.releaseVersion];
            NSLog(@"HCP_LOG : HCPUpdateLoaderWorker switch file structure to new release");
            
            // create new download folder
            [self createNewReleaseDownloadFolder:_pluginFiles.downloadFolder];
            
            // if there is anything to load - do that
            NSArray *updatedFiles = manifestDiff.updateFileList;
            if (updatedFiles.count > 0) {
                NSLog(@"HCP_LOG : HCPUpdateLoaderWorker pdatedFiles count %ld", updatedFiles.count);
                [self downloadUpdatedFiles:updatedFiles appConfig:newAppConfig manifest:newManifest];
                return;
            }
            
            // otherwise - update holds only files for deletion;
            // just save new configs and notify subscribers about success
            
            [_manifestStorage store:newManifest inFolder:_pluginFiles.downloadFolder];
            [_appConfigStorage store:newAppConfig inFolder:_pluginFiles.downloadFolder];
            NSLog(@"HCP_LOG : HCPUpdateLoaderWorker update holds only files for deletion --> notifyUpdateDownloadSuccess");
            [self notifyUpdateDownloadSuccess:newAppConfig];
        }];
    }];
}

#pragma mark Private API

- (void)downloadUpdatedFiles:(NSArray *)updatedFiles
                   appConfig:(HCPApplicationConfig *)newAppConfig
                    manifest:(HCPContentManifest *)newManifest {
    
    // download files
    HCPFileDownloader *downloader = [[HCPFileDownloader alloc] initWithFiles:updatedFiles
                                                                   srcDirURL:newAppConfig.contentConfig.contentURL
                                                                   dstDirURL:_pluginFiles.downloadFolder
                                                              requestHeaders:_requestHeaders];
    [downloader startDownloadWithCompletionBlock:^(NSError * error) {
        NSLog(@"HCP_LOG : HCPUpdateLoaderWorker downloadUpdatedFiles startDownloadWithCompletionBlock");
        if (error) {
            // remove new release folder
            [[NSFileManager defaultManager] removeItemAtURL:_pluginFiles.contentFolder error:nil];
            
            // notify about the error
            
            NSLog(@"HCP_LOG : HCPUpdateLoaderWorker remove new release folder --> notifyWithError code %ld", kHCPFailedToDownloadUpdateFilesErrorCode);
            
            [self notifyWithError:[NSError errorWithCode:kHCPFailedToDownloadUpdateFilesErrorCode
                                              descriptionFromError:error]
                          applicationConfig:newAppConfig];
            return;
        }
                  
        // store configs
        [_manifestStorage store:newManifest inFolder:_pluginFiles.downloadFolder];
        [_appConfigStorage store:newAppConfig inFolder:_pluginFiles.downloadFolder];
                  
        // notify that we are done
        NSLog(@"HCP_LOG : HCPUpdateLoaderWorker notify that we are done --> notifyUpdateDownloadSuccess");
        [self notifyUpdateDownloadSuccess:newAppConfig];
    }];
}

- (HCPApplicationConfig *)getApplicationConfigFromData:(NSData *)data error:(NSError **)error {
    if (*error) {
        NSLog(@"HCP_LOG : HCPUpdateLoaderWorker getApplicationConfigFromData error %@", [*error localizedDescription]);
        return nil;
    }
    
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:error];
    if (*error) {
        NSLog(@"HCP_LOG : HCPUpdateLoaderWorker getApplicationConfigFromData NSJSONSerialization error %@", [*error localizedDescription]);
        return nil;
    }
    NSLog(@"HCP_LOG : HCPUpdateLoaderWorker HCPApplicationConfig instanceFromJsonObject %@", json);
    return [HCPApplicationConfig instanceFromJsonObject:json];
}

- (HCPContentManifest *)getManifestConfigFromData:(NSData *)data error:(NSError **)error {
    if (*error) {
        NSLog(@"HCP_LOG : HCPUpdateLoaderWorker getManifestConfigFromData error %@", [*error localizedDescription]);
        return nil;
    }
    
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:error];
    if (*error) {
        NSLog(@"HCP_LOG : HCPUpdateLoaderWorker getManifestConfigFromData NSJSONSerialization error %@", [*error localizedDescription]);
        return nil;
    }
    NSLog(@"HCP_LOG : HCPUpdateLoaderWorker HCPContentManifest instanceFromJsonObject %@", json);
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
        NSLog(@"HCP_LOG : HCPUpdateLoaderWorker Failed to load current application config %@", [*error localizedDescription]);
        return NO;
    }
    
    _oldManifest = [_manifestStorage loadFromFolder:_pluginFiles.wwwFolder];
    if (_oldManifest == nil) {
        *error = [NSError errorWithCode:kHCPLocalVersionOfManifestNotFoundErrorCode
                            description:@"Failed to load current manifest file"];
        NSLog(@"HCP_LOG : HCPUpdateLoaderWorker Failed to load current manifest file %@", [*error localizedDescription]);
        return NO;
    }
    NSLog(@"HCP_LOG : HCPUpdateLoaderWorker loadLocalConfigs YES");
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
    NSLog(@"HCP_LOG : HCPUpdateLoaderWorker notifyWithError kHCPUpdateDownloadErrorEvent");
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
    NSLog(@"HCP_LOG : HCPUpdateLoaderWorker notifyNothingToUpdate");
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
    NSLog(@"HCP_LOG : HCPUpdateLoaderWorker notifyUpdateDownloadSuccess");
    NSNotification *notification = [HCPEvents notificationWithName:kHCPUpdateIsReadyForInstallationEvent
                                                 applicationConfig:config
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
    
    NSLog(@"HCP_LOG : HCPUpdateLoaderWorker create new download folder %@", downloadFolder.path);
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
