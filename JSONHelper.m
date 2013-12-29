//
//  JsonHelper.m
//
//
//  Created by  on 12-3-15.
//  Copyright (c) 2012年 liubiqu@qq.com. All rights reserved.
//

#import "JsonHelper.h"
#import "JSONKit.h"

#define IosVersionFirstValue ([[[UIDevice currentDevice] systemVersion] intValue])  //ios版本首位数字 比如5.01 -> 5
#define TheIosVersionWitchHaveNSJsonClass 5 //支持NSJson的最低版本号
@implementation JsonHelper
 
+(id)jsonObjectWithString:(NSString *)jsonString {
    id retValue;
    if (jsonString == nil || [jsonString isEqualToString:@""]) {
        return nil;
    }
    NSError *error = nil; 
    retValue = [jsonString objectFromJSONStringWithParseOptions:JKParseOptionStrict error:&error]; 
    NSAssert1(error == nil, @"JOSN解析错误(jsonObjectWithString):%@", error);
    return retValue; 
}

//5.0以上（包含5.0）的版本ios encode参数有效 否则无效，可传0
+(id)jsonObjectWithString:(NSString *)jsonString Encode:(NSStringEncoding)encode{
    if (jsonString == nil || [jsonString isEqualToString:@""]) {
        return nil;
    }
    NSData *jsonData = [jsonString dataUsingEncoding:encode];
    return [JsonHelper jsonObjectWithData:jsonData];
}

+(id)jsonObjectWithData:(NSData *)jsonData {
    id retValue;
    if (jsonData == nil) {
        //NSLog(@"捕捉到空的jsonData");
        return nil;
    }
    NSError *error = nil; 
//    retValue = [jsonData objectFromJSONDataWithParseOptions:JKParseOptionStrict error:&error ];
    retValue = [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingMutableContainers error:&error];
    NSAssert1(error == nil, @"JOSN解析错误(jsonObjectWithData):%@", error);
    return retValue;
}

#pragma mark - 应用接口
//不做网络连接判断
+(id)jsonObjectWithURL:(NSURL *)url {
    id retValue;
    NSData *jsonData = [[NSData alloc] initWithContentsOfURL:url];
    retValue = [JsonHelper jsonObjectWithData:jsonData];
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
    retValue = [JsonHelper jsonObjectWithData:jsonData];
    return retValue;
}

+(id)jsonObjectWithURLWithException:(NSURL *)url {
    //无网络
    if(![JsonHelper connectedToNetwork]){
        return nil;
    }
    NSData *jsonData = nil;
    NSMutableURLRequest *mutRequest = [NSMutableURLRequest requestWithURL:url];
    @try {
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]init];
        jsonData = [NSURLConnection sendSynchronousRequest:mutRequest returningResponse:&response error:nil];
    } @catch (NSException *exception) {
        NSLog(@"getData message:url = %@ | exception = %@", url, exception);
        
        return nil;
    }
    if (jsonData != nil) {
        return [JsonHelper jsonObjectWithData:jsonData];
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
