//
//  JSONKitHelper.m
//  
//  
//  Created by  on 12-3-15.
//  Copyright (c) 2012年 __MyCompanyName__. All rights reserved.
//

#import "JSONKitHelper.h"

#define IosVersionFirstValue ([[[UIDevice currentDevice] systemVersion] intValue])  //ios版本首位数字 比如5.01 -> 5
#define TheIosVersionWitchHaveNSJsonClass 5 //支持NSJson的最低版本号
@implementation JSONKitHelper

//5.0以上（包含5.0）的版本ios encode参数有效 否则无效，可传0
+(id)jsonObjectWithString:(NSString *)jsonString Encode:(NSStringEncoding)encode{
    id retValue;
    if (jsonString == nil || [jsonString isEqualToString:@""]) {
        return nil;
    }
//    //小于5.0的系统 用jsonkit解析 大于5.0系统用NSJson解析
    if (IosVersionFirstValue < TheIosVersionWitchHaveNSJsonClass) {
       retValue = [jsonString objectFromJSONString];
        //NSLog(@"非5.0系统");
    } else {
        NSError *error = nil;
        NSData *jsonData = [jsonString dataUsingEncoding:encode];
        retValue = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        NSAssert1(error == nil, @"Errored: %@", error);
        //NSLog(@"5.0系统");
    }
    
    return retValue;
}

+(id)jsonObjectWithData:(NSData *)jsonData {
    id retValue;
    if (jsonData == nil) {
        //NSLog(@"捕捉到空的jsonData");
        return nil;
    }
    if (IosVersionFirstValue < TheIosVersionWitchHaveNSJsonClass) {
        retValue = [jsonData objectFromJSONData];
        //NSLog(@"非5.0系统");
    } else {
        //NSLog(@"5.0系统");
        retValue = [jsonData objectFromJSONData];
        
//        NSError *error = nil;
//        retValue = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
//        NSAssert1(error == nil, @"Errored:%@", error);
    }
    
    return retValue;
}

//不做网络连接判断
+(id)jsonObjectWithURL:(NSURL *)url {
    id retValue;
    
    NSData *jsonData = [[NSData alloc] initWithContentsOfURL:url];
    retValue = [JSONKitHelper jsonObjectWithData:jsonData];
    [jsonData release];
    
    return retValue;
}

+(id)jsonObjectWithFile:(NSString *)fileName {
    if (fileName == nil) {
        return nil;
    }
    id retValue;
    
    NSString *filePath = [[NSBundle mainBundle]pathForResource:[fileName stringByDeletingPathExtension] ofType:[fileName pathExtension] ];
    if (!filePath) {
        [NSException raise:NSInvalidArgumentException format:@"Resource not found: %@", fileName];//xxx
    }
	NSError *error = nil;
    NSData *jsonData = [NSData dataWithContentsOfFile:filePath options:0 error:&error];
    if (error){
        [NSException raise:NSInvalidArgumentException format:@"Error loading resource at path (%@): %@", filePath, error]; 
    }
    retValue = [JSONKitHelper jsonObjectWithData:jsonData];
    
    return retValue;
}

+(id)jsonObjectWithURLWithException:(NSURL *)url {
    NSData *jsonData = nil;
    //无网络
    if(![JSONKitHelper connectedToNetwork]){
        return nil;
    }
    [UIApplication sharedApplication];
    //有网络
    //[self showLoading:@"数据加载中..."];
    NSMutableURLRequest *mutRequest = [NSMutableURLRequest requestWithURL:url];
    @try {
        NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc]init] autorelease];
        jsonData = [NSURLConnection sendSynchronousRequest:mutRequest returningResponse:&response error:nil];
    } @catch (NSException *exception) {
        NSLog(@"getData message:url = %@ | exception = %@", url, exception);
        //[self closeLoading];
        return nil;
    }
    //[self closeLoading];
    if (jsonData != nil) {
        return [JSONKitHelper jsonObjectWithData:jsonData];
    } else {
        return nil;
    }
}

+(BOOL)connectedToNetwork {
    //Createzeroaddy 
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress,sizeof(zeroAddress));
    zeroAddress.sin_len=sizeof(zeroAddress);
    zeroAddress.sin_family=AF_INET;
    
    //Recoverreachabilityflags 
    SCNetworkReachabilityRef defaultRouteReachability=SCNetworkReachabilityCreateWithAddress(NULL,(struct sockaddr *)&zeroAddress);
    SCNetworkReachabilityFlags flags;
    
    BOOL didRetrieveFlags=SCNetworkReachabilityGetFlags(defaultRouteReachability,&flags);
    CFRelease(defaultRouteReachability);
    
    if(!didRetrieveFlags)
    {
        printf("Error.Couldnotrecovernetworkreachabilityflags/n");
        return NO;
    }
    
    BOOL isReachable=((flags & kSCNetworkFlagsReachable)!=0);
    BOOL needsConnection=((flags & kSCNetworkFlagsConnectionRequired)!=0);
    return (isReachable&&!needsConnection)?YES:NO;
}


@end
