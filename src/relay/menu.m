#import <AppKit/AppKit.h>
#import <crt_externs.h>
#import <dispatch/dispatch.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include "menu.h"

static NSString *const reopenNotification = @"com.hsp.zimbr.relay.show-settings";

static NSString *explanation(NSString *code) {
    NSDictionary *messages = @{
        @"UnsafeOrMissingSecurityFile": @"Settings or credentials are missing or have unsafe permissions. Select provisioned files in private directories.",
        @"InvalidTlsConfiguration": @"Check the server name, port, and required credential paths.",
        @"InvalidTlsCredentials": @"The certificates and key could not be validated. Check their identity, expiry, and permissions. Open Logs for details.",
        @"ExplicitListenAddressRequired": @"Enter a specific IPv4 or IPv6 listening address.",
        @"WildcardListenAddressForbidden": @"Choose a specific network address instead of a wildcard address.",
        @"InvalidContactsPhoneRegion": @"Use a supported two-letter country code, or leave the phone region blank.",
        @"InvalidDeviceAllowlist": @"The selected device list is invalid. Select a provisioned device list.",
        @"InvalidDeviceFingerprint": @"A device certificate fingerprint is invalid. Check the selected device list.",
        @"DuplicateDeviceFingerprint": @"The device list contains a duplicate certificate. Correct the device list before saving.",
        @"TooManyDevices": @"The device list exceeds the supported limit of 256 entries.",
        @"OutOfMemory": @"The relay could not allocate enough memory. Close other applications and try again.",
        @"ConfigurationChanged": @"The settings file changed while this window was open. Reload it before saving again.",
        @"ConfigurationWriteDenied": @"The settings file could not be safely replaced. Check that its directory is private, writable, and contains no symbolic links.",
        @"AddressInUse": @"The listening address and port are already in use. Choose another port or stop the other listener.",
        @"AddressNotAvailable": @"The listening address is not available on this Mac.",
        @"database_access_required": @"Allow Zimbr Relay in System Settings → Privacy & Security → Full Disk Access, then restart the relay.",
        @"schema_unsupported": @"This Messages database version is not supported.",
        @"database_busy": @"Messages is busy. The relay will retry automatically.",
        @"persistence_or_source_failure": @"Message history could not be read or saved. Open Logs for details.",
        @"automation_unverified": @"Messages Automation has not been verified yet.",
        @"automation_permission_required": @"Allow Zimbr Relay to control Messages in System Settings → Privacy & Security → Automation.",
        @"messages_unavailable": @"Open Messages and check that the intended account is signed in.",
        @"unsupported_account_configuration": @"Check the signed-in account in Messages.",
        @"automation_launch_failed": @"Messages Automation could not start. Open Logs for details.",
        @"automation_timeout_or_uncertain": @"Messages Automation did not finish. The relay will check again.",
        @"read_only_mode": @"This relay was started in read-only mode.",
        @"starting": @"Loading message history…",
    };
    return messages[code] ?: code;
}

@interface ZrMenuController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic) ZrMenu bridge;
@property(nonatomic, copy) NSString *configPath;
@property(nonatomic, copy) NSString *dataPath;
@property(nonatomic) BOOL showOnLaunch;
@property(nonatomic, strong) NSStatusItem *item;
@property(nonatomic, strong) NSMenuItem *summary;
@property(nonatomic, strong) NSMenuItem *detail;
@property(nonatomic, strong) NSMenuItem *restartItem;
@property(nonatomic, strong) NSImage *normalImage;
@property(nonatomic, strong) NSImage *warningImage;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) dispatch_queue_t work;
@property(nonatomic) BOOL statusPending;
@property(nonatomic, strong) NSDictionary *latestStatus;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL loaded;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *fields;
@property(nonatomic, strong) NSMutableArray<NSControl *> *editControls;
@property(nonatomic, strong) NSData *originalBytes;
@property(nonatomic, strong) NSTextField *notice;
@property(nonatomic, strong) NSButton *saveButton;
@property(nonatomic, strong) NSButton *reloadButton;
@property(nonatomic, strong) NSButton *advancedButton;
@property(nonatomic, strong) NSStackView *advanced;
- (void)showSettings:(id)sender;
- (void)refresh;
@end

@implementation ZrMenuController
- (NSMenuItem *)addItem:(NSString *)title action:(SEL)action menu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    [menu addItem:item];
    return item;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    // Accessory apps still need a responder-chain Edit menu for text-field shortcuts.
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    for (NSArray<NSString *> *entry in @[
        @[@"Undo", @"undo:", @"z"], @[@"Redo", @"redo:", @"Z"],
        @[@"Cut", @"cut:", @"x"], @[@"Copy", @"copy:", @"c"],
        @[@"Paste", @"paste:", @"v"], @[@"Select All", @"selectAll:", @"a"],
    ]) {
        [edit addItemWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:entry[2]];
    }
    editItem.submenu = edit;
    [main addItem:editItem];
    NSApp.mainMenu = main;
    self.work = dispatch_queue_create("com.hsp.zimbr.relay.menu", DISPATCH_QUEUE_SERIAL);
    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSString *icon = [NSBundle.mainBundle pathForResource:@"statusTemplate" ofType:@"pdf"];
    self.normalImage = icon ? [[NSImage alloc] initWithContentsOfFile:icon] : nil;
    if (!self.normalImage)
        self.normalImage = [NSImage imageWithSystemSymbolName:@"bubble.left.and.bubble.right" accessibilityDescription:@"Zimbr Relay"];
    self.normalImage.size = NSMakeSize(18, 18);
    self.normalImage.template = YES;
    NSImage *base = self.normalImage;
    self.warningImage = [NSImage imageWithSize:NSMakeSize(25, 18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        [base drawInRect:NSMakeRect(0, 0, 18, 18)];
        NSImage *mark = [NSImage imageWithSystemSymbolName:@"exclamationmark" accessibilityDescription:nil];
        [mark drawInRect:NSMakeRect(20, 3, 4, 12)];
        return YES;
    }];
    self.warningImage.template = YES;
    self.item.button.image = self.normalImage;
    [self.item.button setAccessibilityLabel:@"Zimbr Relay"];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Zimbr Relay"];
    menu.autoenablesItems = NO;
    self.summary = [self addItem:@"Starting relay…" action:NULL menu:menu];
    self.summary.enabled = NO;
    self.detail = [self addItem:@"" action:NULL menu:menu];
    self.detail.enabled = NO;
    [menu addItem:NSMenuItem.separatorItem];
    [self addItem:@"Settings…" action:@selector(showSettings:) menu:menu];
    [self addItem:@"Check Permissions…" action:@selector(checkPermissions:) menu:menu];
    [self addItem:@"Open Logs…" action:@selector(openLogs:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    self.restartItem = [self addItem:@"Restart Relay…" action:@selector(confirmRestart:) menu:menu];
    self.item.menu = menu;
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(showSettings:)
        name:reopenNotification object:self.configPath suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    __weak ZrMenuController *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf refresh];
    }];
    self.timer.tolerance = 0.5;
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self refresh];
    if (self.showOnLaunch) [self showSettings:nil];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible {
    (void)application; (void)visible;
    [self showSettings:nil];
    return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    (void)application;
    return NO;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    return !self.busy;
}

- (void)refresh {
    if (self.statusPending) return;
    self.statusPending = YES;
    dispatch_async(self.work, ^{
        char buffer[8192];
        int length = self.bridge.status(self.bridge.relay, buffer, sizeof(buffer));
        NSDictionary *status = length < 0 ? nil : [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithBytes:buffer length:(NSUInteger)length] options:0 error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusPending = NO;
            self.latestStatus = status;
            self.summary.title = status[@"summary"] ?: @"Status unavailable";
            NSString *detail = explanation(status[@"detail"] ?: @"Open Logs for details.");
            self.detail.title = detail.length > 72 ? [[detail substringToIndex:71] stringByAppendingString:@"…"] : detail;
            self.detail.toolTip = detail;
            self.item.button.toolTip = [NSString stringWithFormat:@"Zimbr Relay: %@\n%@", self.summary.title, detail];
            self.item.button.image = !status || [status[@"warning"] boolValue] ? self.warningImage : self.normalImage;
        });
    });
}

- (void)alert:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    if (self.window.visible) [alert beginSheetModalForWindow:self.window completionHandler:nil];
    else [alert runModal];
}

- (NSStackView *)column {
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    return stack;
}

- (void)addField:(NSString *)key label:(NSString *)label stack:(NSStackView *)stack file:(BOOL)file {
    NSTextField *caption = [NSTextField labelWithString:label];
    [caption.widthAnchor constraintEqualToConstant:145].active = YES;
    NSTextField *field = [NSTextField textFieldWithString:@""];
    field.placeholderString = [key isEqualToString:@"contacts_phone_region"] ? @"Optional, e.g. US" : @"";
    [field.widthAnchor constraintEqualToConstant:file ? 330 : 430].active = YES;
    [field setAccessibilityLabel:label];
    field.identifier = key;
    self.fields[key] = field;
    [self.editControls addObject:field];
    NSStackView *row = [NSStackView stackViewWithViews:@[caption, field]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 10;
    if (file) {
        NSButton *choose = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(chooseFile:)];
        choose.identifier = key;
        [row addArrangedSubview:choose];
        [self.editControls addObject:choose];
    }
    [stack addArrangedSubview:row];
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 590)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Zimbr Relay Settings";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.fields = [NSMutableDictionary dictionary];
    self.editControls = [NSMutableArray array];
    NSStackView *content = [self column];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.window.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:24],
        [content.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-24],
        [content.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:24],
    ]];
    NSTextField *intro = [NSTextField wrappingLabelWithString:@"Changes take effect after restarting the relay. Existing clients reconnect automatically."];
    [intro.widthAnchor constraintEqualToConstant:600].active = YES;
    [content addArrangedSubview:intro];
    [self addField:@"listen_address" label:@"Listening address" stack:content file:NO];
    [self addField:@"port" label:@"Port" stack:content file:NO];
    [self addField:@"server_name" label:@"Server name" stack:content file:NO];
    [self addField:@"contacts_phone_region" label:@"Phone region" stack:content file:NO];
    self.advancedButton = [NSButton checkboxWithTitle:@"Advanced: certificates and device list" target:self action:@selector(toggleAdvanced:)];
    [content addArrangedSubview:self.advancedButton];
    self.advanced = [self column];
    [self addField:@"server_cert_file" label:@"Server certificate" stack:self.advanced file:YES];
    [self addField:@"server_key_file" label:@"Server private key" stack:self.advanced file:YES];
    [self addField:@"client_ca_file" label:@"Client CA certificate" stack:self.advanced file:YES];
    [self addField:@"device_allowlist_file" label:@"Device list" stack:self.advanced file:YES];
    [content addArrangedSubview:self.advanced];
    self.advanced.hidden = YES;
    self.notice = [NSTextField wrappingLabelWithString:@"Loading settings…"];
    [self.notice.widthAnchor constraintEqualToConstant:600].active = YES;
    [content addArrangedSubview:self.notice];
    self.reloadButton = [NSButton buttonWithTitle:@"Reload" target:self action:@selector(reloadSettings:)];
    self.saveButton = [NSButton buttonWithTitle:@"Save and Restart" target:self action:@selector(saveSettings:)];
    self.saveButton.keyEquivalent = @"\r";
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.reloadButton, self.saveButton]];
    buttons.spacing = 12;
    [content addArrangedSubview:buttons];
    [self.window center];
}

- (void)toggleAdvanced:(id)sender {
    (void)sender;
    self.advanced.hidden = self.advancedButton.state != NSControlStateValueOn;
}

- (void)showSettings:(id)sender {
    (void)sender;
    if (!self.window) [self buildWindow];
    BOOL wasVisible = self.window.visible;
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    if (!wasVisible && !self.busy) [self loadSettings];
}

- (void)setEditingBusy:(BOOL)busy {
    self.busy = busy;
    for (NSControl *control in self.editControls) control.enabled = !busy && self.loaded;
    self.saveButton.enabled = !busy && self.loaded;
    self.reloadButton.enabled = !busy;
    self.restartItem.enabled = !busy;
}

- (void)loadSettings {
    [self setEditingBusy:YES];
    self.notice.stringValue = @"Loading settings…";
    dispatch_async(self.work, ^{
        char buffer[65536];
        int length = self.bridge.read_config(self.bridge.relay, buffer, sizeof(buffer));
        NSData *bytes = length < 0 ? nil : [NSData dataWithBytes:buffer length:(NSUInteger)length];
        id parsed = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
        NSDictionary *object = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loaded = length >= 0 || length == -2;
            self.originalBytes = bytes;
            for (NSString *key in self.fields) {
                id value = object[key];
                self.fields[key].stringValue = [value isKindOfClass:NSString.class] ? value :
                    ([value isKindOfClass:NSNumber.class] ? [value stringValue] : @"");
            }
            if (!object[@"port"]) self.fields[@"port"].stringValue = @"8731";
            self.notice.stringValue = length == -1 ? @"Settings could not be safely read. Check the file and directory permissions, then Reload." :
                (!object ? @"Complete the settings using provisioned certificates and a device list. Certificate issuance is managed separately." :
                @"Credentials are validated before saving. Changing the server name requires a certificate that covers that name.");
            if (!object) {
                self.advancedButton.state = NSControlStateValueOn;
                self.advanced.hidden = NO;
            }
            NSMutableSet *unknown = [NSMutableSet setWithArray:object.allKeys ?: @[]];
            [unknown minusSet:[NSSet setWithArray:self.fields.allKeys]];
            if (unknown.count)
                self.notice.stringValue = @"This file contains unsupported settings. Saving replaces it with the fields shown here and removes unsupported entries.";
            [self setEditingBusy:NO];
        });
    });
}

- (void)reloadSettings:(id)sender {
    (void)sender;
    if (self.busy) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Reload settings?";
    alert.informativeText = @"Unsaved edits in this window will be discarded.";
    [alert addButtonWithTitle:@"Reload"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [self loadSettings];
    }];
}

- (void)chooseFile:(NSButton *)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK) {
            // System paths such as /tmp are symlinks; store the actual selected location.
            self.fields[sender.identifier].stringValue = panel.URL.URLByResolvingSymlinksInPath.path;
        }
    }];
}

- (void)saveSettings:(id)sender {
    (void)sender;
    if (self.busy || !self.loaded) return;
    NSString *port = self.fields[@"port"].stringValue;
    if (port.length == 0 || [port rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound ||
        port.longLongValue < 1 || port.longLongValue > 65535) {
        self.notice.stringValue = @"Enter a port between 1 and 65535.";
        return;
    }
    NSMutableDictionary *object = [NSMutableDictionary dictionary];
    for (NSString *key in self.fields) object[key] = self.fields[key].stringValue;
    object[@"port"] = @([port intValue]);
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (!bytes) { self.notice.stringValue = @"Settings could not be encoded."; return; }
    NSData *original = self.originalBytes;
    [self setEditingBusy:YES];
    self.notice.stringValue = @"Validating settings and credentials…";
    dispatch_async(self.work, ^{
        char diagnostic[256] = {0};
        // NSData may return NULL for an empty file; distinguish that from an absent file.
        const char *expected = original ? (original.length ? original.bytes : "") : NULL;
        int result = self.bridge.save_config(self.bridge.relay, expected, original.length,
            bytes.bytes, bytes.length, diagnostic, sizeof(diagnostic));
        NSString *reason = [NSString stringWithUTF8String:diagnostic] ?: @"Settings could not be saved.";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setEditingBusy:NO];
            if (result < 0) { self.notice.stringValue = explanation(reason); return; }
            self.originalBytes = bytes;
            if (result == 1) {
                self.notice.stringValue = @"Settings were saved, but disk synchronization failed. Check available disk space, then restart the relay.";
                return;
            }
            self.notice.stringValue = @"Settings saved. Restarting relay…";
            [self restart];
        });
    });
}

- (void)confirmRestart:(id)sender {
    (void)sender;
    if (self.busy) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Restart Zimbr Relay?";
    alert.informativeText = @"Clients will briefly disconnect. Unsaved settings will be discarded.";
    [alert addButtonWithTitle:@"Restart"];
    [alert addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([alert runModal] == NSAlertFirstButtonReturn) [self restart];
}

- (void)restart {
    // Replacing this process preserves launchd ownership and works for manual launches.
    // The journal's existing crash recovery handles interrupted work on startup.
    NSString *executable = NSBundle.mainBundle.executablePath;
    execv(executable.fileSystemRepresentation, *_NSGetArgv());
    int reason = errno;
    [self alert:@"Could not restart relay" message:[NSString stringWithFormat:
        @"Saved settings will apply on the next launch. %@", [NSString stringWithUTF8String:strerror(reason)]]];
}

- (void)openLogs:(id)sender {
    (void)sender;
    NSURL *url = [NSURL fileURLWithPath:[self.dataPath stringByAppendingPathComponent:@"relay.log"]];
    if (![NSWorkspace.sharedWorkspace openURL:url])
        [self alert:@"Log unavailable" message:@"The service log is created when the installed LaunchAgent runs. A relay started in Terminal writes its logs there."];
}

- (void)checkPermissions:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Messages and Contacts permissions";
    NSDictionary *permissionNames = @{
        @"authorized": @"Allowed", @"denied": @"Denied", @"restricted": @"Restricted",
        @"not_determined": @"Not requested", @"unavailable": @"Unavailable", @"unsupported": @"Unsupported",
    };
    NSString *reading = self.latestStatus[@"messages_readable"] ?
        ([self.latestStatus[@"messages_readable"] boolValue] ? @"Available" : @"Unavailable") : @"Not checked";
    NSString *sending = self.latestStatus[@"sending_available"] ?
        ([self.latestStatus[@"sending_available"] boolValue] ? @"Available" : @"Unavailable") : @"Not checked";
    NSString *contacts = permissionNames[self.latestStatus[@"contacts_permission"] ?: @""] ?: @"Not checked";
    alert.informativeText = [NSString stringWithFormat:
        @"Reading Messages: %@\nSending Messages: %@\nContacts: %@\n\nAllow Zimbr Relay under Privacy & Security → Full Disk Access and Automation (Messages). Contacts access is optional. Restart after changing Full Disk Access.",
        reading, sending, contacts];
    [alert addButtonWithTitle:@"Open Privacy Settings"];
    [alert addButtonWithTitle:@"Request Contacts Access"];
    [alert addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security"]];
    } else if (response == NSAlertSecondButtonReturn) {
        // A fresh invocation through Launch Services attributes the request to the signed app.
        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.createsNewApplicationInstance = YES;
        configuration.arguments = @[@"doctor", @"--config", self.configPath, @"--request-contacts", @"--read-only"];
        [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:configuration
            completionHandler:^(NSRunningApplication *application, NSError *error) {
                (void)application;
                if (error) dispatch_async(dispatch_get_main_queue(), ^{
                    [self alert:@"Could not request Contacts access" message:error.localizedDescription];
                });
            }];
    }
}
@end

void zr_menu_run(const ZrMenu *menu, const char *config, const char *data, int show_settings) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        ZrMenuController *controller = [[ZrMenuController alloc] init];
        controller.bridge = *menu;
        controller.configPath = [NSString stringWithUTF8String:config];
        controller.dataPath = [NSString stringWithUTF8String:data];
        controller.showOnLaunch = show_settings != 0;
        NSApp.delegate = controller;
        [NSApp run];
        [controller.timer invalidate];
        [NSDistributedNotificationCenter.defaultCenter removeObserver:controller];
    }
}

void zr_menu_reopen(const char *config) {
    @autoreleasepool {
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:reopenNotification
            object:[NSString stringWithUTF8String:config] userInfo:nil deliverImmediately:YES];
    }
}
