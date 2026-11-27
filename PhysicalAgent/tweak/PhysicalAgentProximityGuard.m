#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static IMP s_origProximityChanged = NULL;

static void PA_proximityChanged(id self, SEL _cmd, id note) {
    SEL frontSel = sel_registerName("_accessibilityFrontMostApplication");
    if (frontSel && [self respondsToSelector:frontSel]) {
        id frontApp = ((id (*)(id, SEL))objc_msgSend)(self, frontSel);
        SEL bundleSel = sel_registerName("bundleIdentifier");
        if (frontApp && bundleSel && [frontApp respondsToSelector:bundleSel]) {
            NSString *bundleId = ((id (*)(id, SEL))objc_msgSend)(frontApp, bundleSel);
            if ([bundleId isKindOfClass:[NSString class]] &&
                [bundleId isEqualToString:@"com.antigravity.physicalagent"]) {
                // Skip SpringBoard screen blanking while PhysicalAgent is foreground
                return;
            }
        }
    }
    if (s_origProximityChanged) {
        ((void (*)(id, SEL, id))s_origProximityChanged)(self, _cmd, note);
    }
}

__attribute__((constructor))
static void PhysicalAgentProximityGuardInit(void) {
    @autoreleasepool {
        Class sbClass = objc_getClass("SpringBoard");
        if (!sbClass) return;
        SEL proxSel = sel_registerName("_proximityChanged:");
        Method m = class_getInstanceMethod(sbClass, proxSel);
        if (m) {
            s_origProximityChanged = method_setImplementation(m, (IMP)PA_proximityChanged);
        }
    }
}
