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
static NSMutableDictionary<NSString*, NSArray<NSDictionary*>*>* serviceCache = nil;

NSDictionary* AppleSiliconSensors(int32_t page, int32_t usage, int32_t type) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        serviceCache = [NSMutableDictionary dictionary];
    });
    
    if (sharedClient == nil) {
        return nil;
    }

    NSString* cacheKey = [NSString stringWithFormat:@"%d-%d", page, usage];
    NSArray<NSDictionary*>* services = serviceCache[cacheKey];
    if (services == nil) {
        NSDictionary* dictionary = @{
            @"PrimaryUsagePage": @(page),
            @"PrimaryUsage": @(usage)
        };

        IOHIDEventSystemClientSetMatching(sharedClient, (__bridge CFDictionaryRef)dictionary);
        CFArrayRef copiedServices = IOHIDEventSystemClientCopyServices(sharedClient);
        if (copiedServices == nil) {
            return nil;
        }

        NSArray* copiedServicesArray = CFBridgingRelease(copiedServices);
        NSMutableArray<NSDictionary*>* cachedServices = [NSMutableArray arrayWithCapacity:copiedServicesArray.count];
        for (id service in copiedServicesArray) {
            NSString* name = CFBridgingRelease(IOHIDServiceClientCopyProperty((__bridge IOHIDServiceClientRef)service, CFSTR("Product")));
            if (name == nil) {
                continue;
            }
            [cachedServices addObject:@{
                @"service": service,
                @"name": name
            }];
        }
        services = cachedServices;
        serviceCache[cacheKey] = services;
    }
    
    NSMutableDictionary* dict = [NSMutableDictionary dictionary];
    for (NSDictionary* entry in services) {
        IOHIDServiceClientRef service = (__bridge IOHIDServiceClientRef)entry[@"service"];
        NSString* name = entry[@"name"];
        
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

    return dict;
}
