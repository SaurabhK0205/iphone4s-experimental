#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[PhysicalAgent] Testing Objective-C runtime on iOS 6.1.3...");
        NSDictionary *deviceInfo = @{
            @"model": @"iPhone 4S (N94AP)",
            @"os": @"iOS 6.1.3 (10B329)",
            @"role": @"PhysicalAgent-DeskCompanion",
            @"timestamp": [NSDate date]
        };
        NSLog(@"[PhysicalAgent] Device Info: %@", deviceInfo);
        
        printf("[PhysicalAgent] Triggering haptic vibration motor...\n");
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        printf("[PhysicalAgent] Vibration triggered!\n");
    }
    return 0;
}
