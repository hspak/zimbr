// Exercise the production AppKit lifecycle actions with disposable callbacks.
#import "../src/relay/menu.m"
#import <objc/runtime.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>

static _Atomic(int) refreshes;

static int startupStatus(void *raw, char *out, size_t capacity) {
    (void)raw;
    BOOL ready = atomic_fetch_add(&refreshes, 1) > 0;
    return snprintf(out, capacity, "{\"summary\":\"%s\",\"warning\":false}", ready ? "Ready" : "Starting");
}

static void checkStartupRefresh(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        ZrMenuController *controller = (ZrMenuController *)NSApp.delegate;
        if (![controller.summary.title isEqualToString:@"Ready"]) _exit(6);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        int settled = atomic_load(&refreshes);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // Startup polling must settle back to the low-frequency steady cadence.
            if (atomic_load(&refreshes) - settled > 1) _exit(7);
            _exit(0);
        });
    });
    ZrMenu menu = { .status = startupStatus };
    zr_menu_run(&menu, "/unused/relay.json", "/unused", 0);
}

static int readConfig(void *raw, char *out, size_t capacity) {
    (void)raw;
    return snprintf(out, capacity, "{\"port\":8731}");
}

static int status(void *raw, char *out, size_t capacity) {
    (void)raw;
    return snprintf(out, capacity, "{\"summary\":\"Disposable restart check\",\"warning\":false}");
}

static int saveConfig(void *raw, const char *expected, size_t expectedLength,
                      const char *bytes, size_t length, char *diagnostic, size_t capacity) {
    (void)raw; (void)diagnostic; (void)capacity;
    NSData *original = [NSData dataWithBytes:expected length:expectedLength];
    NSData *saved = [NSData dataWithBytes:bytes length:length];
    NSDictionary *before = [NSJSONSerialization JSONObjectWithData:original options:0 error:nil];
    NSDictionary *after = [NSJSONSerialization JSONObjectWithData:saved options:0 error:nil];
    if (![before[@"port"] isEqual:@8731] || ![after[@"port"] isEqual:@8731]) _exit(4);
    return 0;
}

static void saveWhenLoaded(ZrMenuController *controller, double deadline) {
    if (controller.loaded && !controller.busy) {
        [controller saveSettings:nil];
        return;
    }
    if (NSProcessInfo.processInfo.systemUptime >= deadline) _exit(5);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        saveWhenLoaded(controller, deadline);
    });
}

static NSString *quitOutput;

static void quitRejected(ZrMenuController *controller, SEL command, NSString *title, NSString *message) {
    (void)command; (void)message;
    if (![title isEqualToString:@"Could not quit relay"] || controller.busy ||
        !controller.quitItem.enabled || !controller.restartItem.enabled) _exit(10);
    if (![@"rejected" writeToFile:[quitOutput stringByAppendingString:@"-rejected"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil]) _exit(11);
    _exit(0);
}

static void checkQuit(const char *output, BOOL rejected) {
    quitOutput = [NSString stringWithUTF8String:output];
    if (rejected) method_setImplementation(class_getInstanceMethod(ZrMenuController.class,
        @selector(alert:message:)), (IMP)quitRejected);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ZrMenuController *controller = (ZrMenuController *)NSApp.delegate;
        NSArray<NSMenuItem *> *items = controller.item.menu.itemArray;
        if (items.lastObject != controller.quitItem ||
            ![controller.quitItem.title isEqualToString:@"Quit Relay"] ||
            items[items.count - 2] != controller.restartItem) _exit(8);
        [controller setEditingBusy:YES];
        if (controller.quitItem.enabled) _exit(9);
        [controller quit:nil]; // A save in progress must not be interrupted.
        [controller setEditingBusy:NO];
        NSString *pid = [NSString stringWithFormat:@"%d", getpid()];
        if (![pid writeToFile:quitOutput atomically:YES encoding:NSUTF8StringEncoding error:nil]) _exit(11);
        [NSApp sendAction:controller.quitItem.action to:controller.quitItem.target from:controller.quitItem];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            _exit(12);
        });
    });
    ZrMenu menu = { .read_config = readConfig, .status = status };
    zr_menu_run(&menu, "/unused/relay.json", "/unused", 0);
}

int main(int argc, char **argv) {
    if (argc == 3 && (strcmp(argv[1], "check-quit") == 0 || strcmp(argv[1], "check-quit-rejected") == 0)) {
        @autoreleasepool { checkQuit(argv[2], strcmp(argv[1], "check-quit-rejected") == 0); }
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "check-startup-refresh") == 0) {
        @autoreleasepool { checkStartupRefresh(); }
        return 3;
    }
    // Model the executable's startup handoff without loading a real relay profile.
    if (argc > 3 && strcmp(argv[1], "menu-relaunch") == 0) {
        pid_t parent = (pid_t)atoi(argv[2]);
        for (int attempt = 0; attempt < 150 && kill(parent, 0) == 0; attempt++) usleep(100000);
        if (kill(parent, 0) == 0) return 2;
        argc -= 3;
        argv += 3;
    }
    if (argc != 3 || strcmp(argv[2], "argument with spaces") != 0) return 2;
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSString *before = [path stringByAppendingString:@"-before.json"];
        NSString *after = [path stringByAppendingString:@"-after.json"];
        BOOL restarted = [NSFileManager.defaultManager fileExistsAtPath:before];
        BOOL repeated = [NSFileManager.defaultManager fileExistsAtPath:after];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            ZrMenuController *controller = (ZrMenuController *)NSApp.delegate;
            NSDictionary *result = @{
                @"uptime": @(NSProcessInfo.processInfo.systemUptime),
                @"registered_pid": @(NSRunningApplication.currentApplication.processIdentifier),
                @"pid": @(getpid()),
                @"item_created": @(controller.item != nil),
                @"item_visible": @(controller.item.visible),
                @"timer_valid": @(controller.timer.valid),
            };
            NSData *bytes = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            NSString *output = repeated ? [path stringByAppendingString:@"-again.json"] : restarted ? after : before;
            if (![bytes writeToFile:output atomically:YES]) _exit(3);
            if (repeated) _exit(0);
            if (restarted) {
                [controller showSettings:nil];
                saveWhenLoaded(controller, NSProcessInfo.processInfo.systemUptime + 5);
            } else [controller restart];
        });
        ZrMenu menu = { .read_config = readConfig, .save_config = saveConfig, .status = status };
        zr_menu_run(&menu, "/unused/relay.json", "/unused", 0);
    }
    return 3;
}
