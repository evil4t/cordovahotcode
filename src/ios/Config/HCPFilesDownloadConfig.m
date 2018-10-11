//
//  HCPFilesDownloadConfig.m
//
//  Created by Nikolay Demyankov on 10.08.15.
//

#import "HCPFilesDownloadConfig.h"

@interface HCPFilesDownloadConfig()

@property (nonatomic, readwrite) NSInteger totalfiles;
@property (nonatomic, readwrite) NSInteger currentfile;

@end

#pragma mark Json keys declaration

static NSString *const TOTAL_FILES_KEY = @"totalfiles";
static NSString *const CURRENT_FILE_KEY = @"currentfile";


@implementation HCPFilesDownloadConfig

#pragma mark HCPJsonConvertable implementation

- (id)toJson {
    NSMutableDictionary *jsonObject = [[NSMutableDictionary alloc] init];
    
    if (_totalfiles > 0) {
        jsonObject[TOTAL_FILES_KEY] = [NSNumber numberWithInteger:_totalfiles];
    } else {
        jsonObject[TOTAL_FILES_KEY] = 0;
    }
    
    if (_currentfile > 0) {
        jsonObject[CURRENT_FILE_KEY] = [NSNumber numberWithInteger:_currentfile];
    } else {
        jsonObject[CURRENT_FILE_KEY] = 0;
    }
    return jsonObject;
}

+ (instancetype)instanceFromJsonObject:(id)json {
    if (![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *jsonObject = json;
    
    HCPFilesDownloadConfig *filesDownloadConfig = [[HCPFilesDownloadConfig alloc] init];
    filesDownloadConfig.totalfiles = [(NSNumber *)jsonObject[TOTAL_FILES_KEY] integerValue];
    filesDownloadConfig.currentfile = [(NSNumber *)jsonObject[CURRENT_FILE_KEY] integerValue];
    
    
    return filesDownloadConfig;
}

@end
