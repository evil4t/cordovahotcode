//
//  HCPUpdateLoader.m
//
//  Created by Nikolay Demyankov on 11.08.15.
//

#import "HCPUpdateLoader.h"
#import "HCPUpdateLoaderWorker.h"
#import "HCPCheckUpdateWorker.h"
#import "HCPDoUpdateWorker.h"
#import "HCPUpdateInstaller.h"
#import "NSError+HCPExtension.h"
#import "HCPLog.h"

@interface HCPUpdateLoader() {
    __block BOOL _isExecuting;
}

@end

@implementation HCPUpdateLoader

#pragma mark Public API

+ (HCPUpdateLoader *)sharedInstance {
    static HCPUpdateLoader *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    
    return sharedInstance;
}

- (BOOL)isDownloadInProgress {
    return _isExecuting;
}

- (BOOL)executeDownloadRequest:(HCPUpdateRequest *)request error:(NSError **)error {
    if (_isExecuting) {
        *error = [NSError errorWithCode:kHCPDownloadAlreadyInProgressErrorCode
                            description:@"Download already in progress. Please, wait for it to finish."];
        NSLog(@"HCP_LOG : executeDownloadRequest Download already in progress. Please, wait for it to finish");
        return NO;
    }
    
    // if installing - don't start the task.
    if ([HCPUpdateInstaller sharedInstance].isInstallationInProgress) {
        *error = [NSError errorWithCode:kHCPCantDownloadUpdateWhileInstallationInProgressErrorCode
                            description:@"Installation is in progress, can't launch the download task. Please, wait for it to finish."];
        NSLog(@"HCP_LOG : executeDownloadRequest Installation is in progress, can't launch the download task. Please, wait for it to finish.");
        return NO;
    }
    
    id<HCPWorker> task = [[HCPUpdateLoaderWorker alloc] initWithRequest:request];
    [self executeTask:task];
    
    return YES;
}

- (BOOL)executeApplicationConfigRequest:(HCPUpdateRequest *)request error:(NSError *__autoreleasing *)error {
    if (_isExecuting) {
        *error = [NSError errorWithCode:kHCPDownloadAlreadyInProgressErrorCode
                            description:@"Download already in progress. Please, wait for it to finish."];
        NSLog(@"HCP_LOG : executeApplicationConfigRequest Download already in progress. Please, wait for it to finish");
        return NO;
    }
    
    // if installing - don't start the task.
    if ([HCPUpdateInstaller sharedInstance].isInstallationInProgress) {
        *error = [NSError errorWithCode:kHCPCantDownloadUpdateWhileInstallationInProgressErrorCode
                            description:@"Installation is in progress, can't launch the download task. Please, wait for it to finish."];
        NSLog(@"HCP_LOG : executeApplicationConfigRequest Installation is in progress, can't launch the download task. Please, wait for it to finish.");
        return NO;
    }
    
    id<HCPWorker> task = [[HCPCheckUpdateWorker alloc] initWithRequest:request];
    [self executeTask:task];
    
    return YES;
}
    
- (BOOL)executeUpdateRequest:(HCPUpdateRequest *)request options:(HCPApplicationConfig *)newAppConfig error:(NSError *__autoreleasing *)error {
    if (_isExecuting) {
        *error = [NSError errorWithCode:kHCPDownloadAlreadyInProgressErrorCode
                            description:@"Download already in progress. Please, wait for it to finish."];
        NSLog(@"HCP_LOG : executeUpdateRequest Download already in progress. Please, wait for it to finish");
        return NO;
    }
    
    // if installing - don't start the task.
    if ([HCPUpdateInstaller sharedInstance].isInstallationInProgress) {
        *error = [NSError errorWithCode:kHCPCantDownloadUpdateWhileInstallationInProgressErrorCode
                            description:@"Installation is in progress, can't launch the download task. Please, wait for it to finish."];
        NSLog(@"HCP_LOG : executeUpdateRequest Installation is in progress, can't launch the download task. Please, wait for it to finish.");
        return NO;
    }
    
    id<HCPWorker> task = [[HCPDoUpdateWorker alloc] initWithRequest:request config:newAppConfig];
    [self executeTask:task];
    return YES;
}

#pragma mark Private API

- (void)executeTask:(id<HCPWorker>)task {
    NSLog(@"HCP_LOG : executeTask %@", task);
    _isExecuting = YES;
    // execute in background, so the callbacks don't block main thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [task runWithComplitionBlock:^{
            _isExecuting = NO;
        }];
    });
}

@end
