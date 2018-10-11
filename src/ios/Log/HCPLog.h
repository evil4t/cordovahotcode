//
//  HCPLog.h
//  cordovahotcode
//
//  Created by evil4t on 2018/6/12.
//
//

#import <Foundation/Foundation.h>

#define HCPLOG_DEBUG = 1

#ifdef HCPLOG_DEBUG
#define NSLog(...) NSLog(__VA_ARGS__)
#else
#define NSLog(...)
#endif

