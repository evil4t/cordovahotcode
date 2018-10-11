//
//  HCPFilesDownloadConfig.h
//
//  Created by Nikolay Demyankov on 10.08.15.
//

#import <Foundation/Foundation.h>
#import "HCPJsonConvertable.h"


/**
 *  Model for content configuration.
 *  Holds information about current/new release, when to perform the update installation and so on.
 *  Basically, it is a part of the chcp.json file, just moved to separate class for convenience.
 */
@interface HCPFilesDownloadConfig : NSObject<HCPJsonConvertable>

@property (nonatomic, readonly) NSInteger totalfiles;
@property (nonatomic, readonly) NSInteger currentfile;


@end
