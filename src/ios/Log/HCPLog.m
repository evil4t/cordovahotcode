//
//  HCPLog.m
//  cordovahotcode
//
//  Created by evil4t on 2018/6/12.
//
//
#import "HCPLog.h"

@implementation HCPLog

static BOOL const DEBUG_LOG = false;

+ (void)Log: (NSString *format, ...)message {
    if (DEBUG) {
        NSLog(@"HCP_LOG : %@", message);
    }
}

@end
