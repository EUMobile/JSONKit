//
//  JSONKitHelper.h
//  

//JSONKit 和 NSJSONSerialization的封装，如果系统支持NSJSONSerialization自动使用它，否则使用JSONKit

// 使用方法：
//----- string  data type -------//
//NSString *strJson = @"{\"flag\":\"内容\"}";
//NSData *strJsonData = [strJson dataUsingEncoding:NSUTF8StringEncoding];
//NSMutableDictionary *result = [JSONKitHelper jsonObjectWithString:strJson Encode:NSUTF8StringEncoding];
//NSMutableDictionary *result2 = [JSONKitHelper jsonObjectWithData:strJsonData];

// --- url type  location file type ---//
//NSString *urlString = @"http://ehr.91yong.com/Service.nd?act=getClient&type=1";
//NSURL *url = [[[NSURL alloc] initWithString:urlString] autorelease];
//NSLog(@"%@", [JSONKitHelper jsonObjectWithURL:url]);
//NSLog(@"%@", [JSONKitHelper jsonObjectWithURLWithException:url]);
//NSLog(@"%@", [JSONKitHelper jsonObjectWithFile:@"yelp.json"]);

//  Created by JSONKit on 12-3-15.
//  Copyright (c) 2012年 __MyCompanyName__. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <SystemConfiguration/SystemConfiguration.h>

#import "JSONKit.h"

@interface JSONKitHelper : NSObject {
    
}

+(id)jsonObjectWithString:(NSString *)jsonString Encode:(NSStringEncoding)encode;
+(id)jsonObjectWithData:(NSData *)jsonData;
+(id)jsonObjectWithURL:(NSURL *)url;
+(id)jsonObjectWithURLWithException:(NSURL *)url;
+(id)jsonObjectWithFile:(NSString *)fileName;

+(BOOL)connectedToNetwork;

@end
