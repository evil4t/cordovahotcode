//
//  HCPDoUpdateWorker.h
//
//  Created by Nikolay Demyankov on 11.08.15.
//

#import <Foundation/Foundation.h>
#import "HCPFilesStructure.h"
#import "HCPWorker.h"
#import "HCPUpdateRequest.h"
#import "HCPApplicationConfig.h"
#import "HCPFilesDownloadConfig.h"

/**
 *  Worker, that implements update download logic.
 *  During the download process events are dispatched to notify the subscribers about the progress.
 *  @see HCPWorker
 */
@interface HCPDoUpdateWorker : NSObject<HCPWorker>

/**
 *  Constructor.
 *
 *  @param request request parameters
 *
 *  @return object instance
 */
- (instancetype)initWithRequest:(HCPUpdateRequest *)request config:(HCPApplicationConfig *)newAppConfig;

@end
