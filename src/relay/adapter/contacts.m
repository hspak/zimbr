#import <Foundation/Foundation.h>
#import <Contacts/Contacts.h>
#import "NBPhoneNumberUtil.h"
#import "NBPhoneNumber.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <limits.h>
#include <errno.h>
#include <mach-o/dyld.h>

// This bridge never logs contact data and never implicitly requests permission.
// Returned buffers belong to the caller. Native reads run on the Contacts worker.
static _Atomic(uint64_t) generation = 1;
static CNContactStore *store;
static id changeObserver;
static _Atomic(bool) monitorAuthorization = false;
static _Atomic(int) observedAuthorization = -1;
static _Atomic(uint64_t) authorizationChecked = 0;

static uint64_t monotonicMilliseconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static void initialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [CNContactStore new];
        changeObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:CNContactStoreDidChangeNotification object:nil queue:nil
            usingBlock:^(NSNotification *notification) {
                (void)notification;
                atomic_fetch_add(&generation, 1);
            }];
    });
}

int zr_contacts_raw_status(void) {
    // Limited is annotated for iOS in the current SDK. Unknown future values
    // stay unavailable until Mac runtime behavior has been validated.
    switch ([CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]) {
        case CNAuthorizationStatusNotDetermined: return 0;
        case CNAuthorizationStatusRestricted: return 1;
        case CNAuthorizationStatusDenied: return 2;
        case CNAuthorizationStatusAuthorized: return 3;
        default: return 4;
    }
}

int zr_contacts_status(void) {
    if (!atomic_load(&monitorAuthorization)) return zr_contacts_raw_status();
    // A stalled checker cannot extend permission to cached photos indefinitely.
    if (monotonicMilliseconds() - atomic_load(&authorizationChecked) > 5000) return -1;
    return atomic_load(&observedAuthorization);
}

// On the tested macOS build, a long-lived CNContactStore authorization query
// retained a revoked grant. Ask only the public status API in a fresh process
// under this same installed executable identity. No enumeration or prompt,
// inherited credentials/descriptors, source data, or child output is involved.
void zr_contacts_refresh_status(void) {
    int status = -1;
    char executable[PATH_MAX]; uint32_t capacity = sizeof(executable);
    if (_NSGetExecutablePath(executable, &capacity) != 0) goto complete;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&actions)) goto complete;
    if (posix_spawnattr_init(&attributes)) {
        posix_spawn_file_actions_destroy(&actions); goto complete;
    }
    int error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    for (int fd = 0; !error && fd < 3; ++fd)
        error = posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0);
    pid_t child = -1;
    char *arguments[] = {executable, "contacts-permission-status", NULL};
    char *environment[] = {NULL};
    if (!error) error = posix_spawn(&child, executable, &actions, &attributes, arguments, environment);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (error) goto complete;
    uint64_t deadline = monotonicMilliseconds() + 2000;
    for (;;) {
        int result = 0;
        pid_t reaped = waitpid(child, &result, WNOHANG);
        if (reaped == child) {
            if (WIFEXITED(result) && WEXITSTATUS(result) >= 100 && WEXITSTATUS(result) <= 104)
                status = WEXITSTATUS(result) - 100;
            break;
        }
        if (reaped < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (monotonicMilliseconds() >= deadline) {
            kill(child, SIGKILL);
            while (waitpid(child, &result, 0) < 0 && errno == EINTR) {}
            break;
        }
        usleep(10000);
    }
complete:
    atomic_store(&observedAuthorization, status);
    atomic_store(&authorizationChecked, monotonicMilliseconds());
}

void zr_contacts_monitor_status(void) {
    atomic_store(&monitorAuthorization, true);
    zr_contacts_refresh_status();
}

uint64_t zr_contacts_generation(void) {
    @autoreleasepool {
        initialize();
        return atomic_load(&generation);
    }
}

// A LaunchAgent still needs its main run loop to deliver framework callbacks.
// Network accept and Contacts enumeration run on separate workers.
void zr_contacts_pump_main(void) {
    @autoreleasepool {
        SInt32 result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, true);
        if (result == kCFRunLoopRunFinished) usleep(250000);
    }
}

int zr_contacts_request(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.hsp.zimbr.relay"])
            return -2;
        initialize();
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [store requestAccessForEntityType:CNEntityTypeContacts completionHandler:^(BOOL granted, NSError *error) {
            (void)granted; (void)error;
            dispatch_semaphore_signal(done);
        }];
        // Pump the local run loop for interactive setup. A timeout is not denial.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
        while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) != 0) {
            if ([deadline timeIntervalSinceNow] <= 0) return -1;
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        return zr_contacts_status();
    }
}

static NSString *phoneKey(NSString *value, NSString *region) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length || trimmed.length > 254) return nil;
    // Short codes, extensions, and unparseable numbers retain exact identity.
    // Never use isNumberMatch: its suffix-match modes violate our policy.
    NBPhoneNumberUtil *util = [NBPhoneNumberUtil sharedInstance];
    NSError *error = nil;
    NBPhoneNumber *number = [util parse:trimmed defaultRegion:region.length ? region : @"ZZ" error:&error];
    if (number && !error && !number.extension.length && [util isValidNumber:number]) {
        NSString *formatted = [util format:number numberFormat:NBEPhoneNumberFormatE164 error:&error];
        if (formatted && !error) return [@"phone:" stringByAppendingString:formatted];
    }
    return [@"exact:" stringByAppendingString:trimmed];
}

int zr_contacts_phone_key(const char *value, const char *region, char *out, size_t capacity) {
    @autoreleasepool {
        NSString *input = [NSString stringWithUTF8String:value];
        NSString *r = [NSString stringWithUTF8String:region];
        if (!input || !r) return -1;
        NSString *key = phoneKey(input, r);
        const char *bytes = key.UTF8String;
        if (!bytes || strlen(bytes) >= capacity) return -1;
        memcpy(out, bytes, strlen(bytes) + 1);
        return (int)strlen(bytes);
    }
}

int zr_contacts_email_key(const char *value, int fold_local, char *out, size_t capacity) {
    @autoreleasepool {
        NSString *input = [NSString stringWithUTF8String:value];
        if (!input) return -1;
        input = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSArray<NSString *> *parts = [input componentsSeparatedByString:@"@"];
        if (parts.count != 2 || !parts[0].length || !parts[1].length) return -1;
        NSString *local = fold_local ? parts[0].lowercaseString : parts[0];
        NSString *key = [NSString stringWithFormat:@"%@@%@", local, parts[1].lowercaseString];
        const char *bytes = key.UTF8String;
        if (!bytes || strlen(bytes) >= capacity) return -1;
        memcpy(out, bytes, strlen(bytes) + 1);
        return (int)strlen(bytes);
    }
}

int zr_contacts_region_valid(const char *region) {
    @autoreleasepool {
        NSString *value = [NSString stringWithUTF8String:region];
        return value && (!value.length || [[[NBPhoneNumberUtil sharedInstance] getSupportedRegions] containsObject:value]);
    }
}

int zr_contacts_suggest_region(char *out, size_t capacity) {
    @autoreleasepool {
        const char *region = NSLocale.currentLocale.countryCode.UTF8String;
        if (!region || strlen(region) >= capacity) return -1;
        memcpy(out, region, strlen(region) + 1);
        return (int)strlen(region);
    }
}

// NULL is a failed/incomplete scan, never an empty address book. Byte/count
// budgets prevent pathological stores from exhausting the relay worker.
char *zr_contacts_snapshot(const char *region) {
    @autoreleasepool {
        if (zr_contacts_status() != 3) return NULL;
        initialize();
        NSString *r = [NSString stringWithUTF8String:region];
        if (!r) return NULL;
        NSArray *keys = @[ CNContactIdentifierKey,
            [CNContactFormatter descriptorForRequiredKeysForStyle:CNContactFormatterStyleFullName],
            CNContactOrganizationNameKey, CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey, CNContactImageDataAvailableKey ];
        CNContactFetchRequest *request = [[CNContactFetchRequest alloc] initWithKeysToFetch:keys];
        request.unifyResults = YES;
        NSMutableArray *contacts = [NSMutableArray array];
        __block BOOL bounded = YES;
        __block NSUInteger bytes = 0;
        NSError *error = nil;
        BOOL success = [store enumerateContactsWithFetchRequest:request error:&error usingBlock:^(CNContact *contact, BOOL *stop) {
            NSString *name = [CNContactFormatter stringFromContact:contact style:CNContactFormatterStyleFullName];
            if (!name.length) name = contact.organizationName;
            NSMutableArray *phones = [NSMutableArray array];
            NSMutableArray *emails = [NSMutableArray array];
            for (CNLabeledValue<CNPhoneNumber *> *phone in contact.phoneNumbers) {
                NSString *key = phoneKey(phone.value.stringValue, r);
                if (key) [phones addObject:key];
            }
            for (CNLabeledValue<NSString *> *email in contact.emailAddresses) {
                if (email.value.length <= 254) [emails addObject:email.value];
            }
            // Omit oversized names, retaining a safe address fallback.
            if ([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024) name = nil;
            NSDictionary *item = @{ @"id": contact.identifier, @"name": name.length ? name : NSNull.null,
                @"phones": phones, @"emails": emails, @"has_image": @(contact.imageDataAvailable) };
            NSData *encoded = [NSJSONSerialization dataWithJSONObject:item options:0 error:nil];
            bytes += encoded.length;
            if (!encoded || bytes > 32 * 1024 * 1024 || contacts.count >= 100000) {
                bounded = NO; *stop = YES; return;
            }
            [contacts addObject:item];
        }];
        if (!success || error || !bounded || zr_contacts_status() != 3) return NULL;
        NSData *json = [NSJSONSerialization dataWithJSONObject:contacts options:0 error:nil];
        if (!json) return NULL;
        char *result = malloc(json.length + 1);
        if (!result) return NULL;
        memcpy(result, json.bytes, json.length); result[json.length] = 0;
        return result;
    }
}

// Called only for an observed, unambiguously matched contact whose pending
// avatar was requested. No thumbnail bytes enter the directory snapshot.
int zr_contacts_thumbnail(const char *identifier, uint64_t expected_generation, int output) {
    @autoreleasepool {
        if (zr_contacts_status() != 3 || zr_contacts_generation() != expected_generation) return -7;
        NSString *key = [NSString stringWithUTF8String:identifier];
        if (!key) return -5;
        NSError *error = nil;
        CNContact *contact = [store unifiedContactWithIdentifier:key keysToFetch:@[CNContactThumbnailImageDataKey] error:&error];
        if (!contact || error) return -1;
        NSData *bytes = contact.thumbnailImageData;
        if (!bytes.length) return -2;
        if (bytes.length > 8 * 1024 * 1024) return -4;
        size_t offset = 0;
        while (offset < bytes.length) {
            ssize_t n = write(output, (const char *)bytes.bytes + offset, bytes.length - offset);
            if (n <= 0) return -1;
            offset += (size_t)n;
        }
        return zr_contacts_status() == 3 && zr_contacts_generation() == expected_generation ? 0 : -7;
    }
}
