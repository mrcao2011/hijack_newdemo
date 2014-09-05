//
//  AppDelegate.h
//  HiJack_demo
//
//  Created by demo on 13-11-16.
//  Copyright (c) 2013年 Junsheng. All rights reserved.
//


#import <UIKit/UIKit.h>
#import "HiJackMgr.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate,HiJackDelegate>
{
    HiJackMgr*  hiJackMgr;
}
@property (strong, nonatomic) UIWindow *window;

@end
