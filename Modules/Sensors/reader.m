//
//  reader.m
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 06/05/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "bridge.h"

static IOHIDEventSystemClientRef sharedClient = nil;

NSDictionary* AppleSiliconSensors(int32_t page, int32_t usage, int32_t type) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    });
    
    if (sharedClient == nil) {
        return nil;
    }
    
    NSDictionary* dictionary = @{
        @"PrimaryUsagePage": @(page),
        @"PrimaryUsage": @(usage)
    };
    
    IOHIDEventSystemClientSetMatching(sharedClient, (__bridge CFDictionaryRef)dictionary);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(sharedClient);
    if (services == nil) {
        return nil;
    }
    
    NSMutableDictionary* dict = [NSMutableDictionary dictionary];
    for (int i = 0; i < CFArrayGetCount(services); i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        NSString* name = CFBridgingRelease(IOHIDServiceClientCopyProperty(service, CFSTR("Product")));
        
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, type, 0, 0);
        if (event == nil) {
            continue;
        }
        
        if (name && event) {
            double value = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(type));
            dict[name] = @(value);
        }
        
        CFRelease(event);
    }
    
    CFRelease(services);
    
    return dict;
}

