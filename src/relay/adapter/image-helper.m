#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "../media.h"
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

static int writeAll(int fd, const void *bytes, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t n = write(fd, (const char *)bytes + offset, length - offset);
        if (n <= 0) return -1;
        offset += (size_t)n;
    }
    return 0;
}
int main(int argc, char **argv) {
    if (argc != 2) return 5;
    int edge = !strcmp(argv[1], "avatar") ? 128 : !strcmp(argv[1], "inline_image") ? 1024 : !strcmp(argv[1], "viewer") ? 2560 : 0;
    if (!edge) return 5;
    struct rlimit cpu = {15, 15}, file = {8 * 1024 * 1024, 8 * 1024 * 1024};
    if (setrlimit(RLIMIT_CPU, &cpu) || setrlimit(RLIMIT_FSIZE, &file)) return 5;
    // The parent enforces 512 MiB resident memory and a 15-second wall bound.
    @autoreleasepool {
        struct stat st;
        if (fstat(3, &st) || !S_ISREG(st.st_mode) || st.st_size < 1) return 5;
        if (st.st_size > 100 * 1024 * 1024) return 4;
        NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
        size_t offset = 0;
        while (offset < bytes.length) {
            ssize_t n = pread(3, (char *)bytes.mutableBytes + offset, bytes.length - offset, (off_t)offset);
            if (n <= 0) return 5;
            offset += (size_t)n;
        }
        NSDictionary *sourceOptions = @{(__bridge NSString *)kCGImageSourceShouldCache: @NO};
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, (__bridge CFDictionaryRef)sourceOptions);
        if (!source) return 5;
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, (__bridge CFDictionaryRef)sourceOptions));
        uint64_t width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
        uint64_t height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
        if (!width || !height) { CFRelease(source); return 5; }
        if (width > 100000000 || height > 100000000 || width * height > 100000000) { CFRelease(source); return 4; }
        NSDictionary *options = @{
            (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(edge),
            (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
        };
        CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        BOOL still = CGImageSourceGetCount(source) > 1;
        CFRelease(source);
        if (!image) return 5;
        width = CGImageGetWidth(image); height = CGImageGetHeight(image);
        if (!width || !height || width > (uint64_t)edge || height > (uint64_t)edge || width * height * 4 > 32 * 1024 * 1024) { CGImageRelease(image); return 4; }
        CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
        BOOL png = alpha == kCGImageAlphaFirst || alpha == kCGImageAlphaLast || alpha == kCGImageAlphaPremultipliedFirst || alpha == kCGImageAlphaPremultipliedLast || alpha == kCGImageAlphaOnly;
        NSMutableData *encoded = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)encoded, png ? CFSTR("public.png") : CFSTR("public.jpeg"), 1, NULL);
        if (!destination) { CGImageRelease(image); return 5; }
        // Only fresh image pixels and encoder quality are supplied: EXIF/GPS,
        // comments, source paths, and all other original metadata are omitted.
        NSDictionary *encoding = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.85};
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)encoding);
        CGImageRelease(image);
        BOOL success = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        if (!success || !encoded.length) return 5;
        if (encoded.length > 8 * 1024 * 1024) return 4;
        ZrImageInfo info = {.width = (uint32_t)width, .height = (uint32_t)height, .png = png, .still = still, .bytes = encoded.length};
        if (writeAll(4, encoded.bytes, encoded.length) || writeAll(5, &info, sizeof(info))) return 5;
        return 0;
    }
}
