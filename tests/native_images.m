#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "../src/relay/media.h"
#include <assert.h>
#include <fcntl.h>
#include <pthread.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

static CGImageRef pixels(size_t width, size_t height, BOOL alpha) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        (CGBitmapInfo)(alpha ? kCGImageAlphaPremultipliedLast : kCGImageAlphaNoneSkipLast));
    assert(context);
    CGContextSetRGBFillColor(context, 1, 0, 0, alpha ? 0.5 : 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context); CGColorSpaceRelease(space);
    return image;
}
static void fixture(const char *file, CFStringRef type, BOOL alpha, int orientation, int frames) {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:file]];
    CGImageDestinationRef target = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, type, (size_t)frames, NULL);
    assert(target);
    CGImageRef image = pixels(2048, 1024, alpha);
    NSDictionary *metadata = @{(__bridge NSString *)kCGImagePropertyOrientation: @(orientation),
        (__bridge NSString *)kCGImagePropertyGPSDictionary: @{(__bridge NSString *)kCGImagePropertyGPSLatitude: @12.3,
            (__bridge NSString *)kCGImagePropertyGPSLatitudeRef: @"N"}};
    for (int i = 0; i < frames; i++) CGImageDestinationAddImage(target, image, (__bridge CFDictionaryRef)metadata);
    assert(CGImageDestinationFinalize(target));
    CFRelease(target); CGImageRelease(image);
}
static void verify(const char *helper, const char *source, const char *output, const char *variant, unsigned width, unsigned height, int png, int still) {
    int input = open(source, O_RDONLY), out = open(output, O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(input >= 0 && out >= 0);
    ZrImageInfo info;
    int code = zr_media_convert(helper, input, out, variant, &info, 15000);
    if (code) fprintf(stderr, "Native conversion failed with safe code %d\n", code);
    assert(code == 0);
    assert(info.width == width && info.height == height);
    if ((png >= 0 && info.png != (unsigned)png) || info.still != (unsigned)still)
        fprintf(stderr, "Image flags: got png=%u still=%u, expected png=%d still=%d\n", info.png, info.still, png, still);
    assert((png < 0 || info.png == (unsigned)png) && info.still == (unsigned)still);
    close(input); close(out);
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:output]];
    CGImageSourceRef image = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    assert(image);
    assert(CFEqual(CGImageSourceGetType(image), info.png ? CFSTR("public.png") : CFSTR("public.jpeg")));
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(image, 0, NULL));
    assert(!properties[(__bridge NSString *)kCGImagePropertyGPSDictionary]);
    assert([properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntValue] == width);
    assert([properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntValue] == height);
    CGImageRef decoded = CGImageSourceCreateImageAtIndex(image, 0, NULL);
    assert(decoded); CGImageRelease(decoded); CFRelease(image);
}
static int convert(const char *helper, const char *source, const char *output, int timeout) {
    int input = open(source, O_RDONLY), out = open(output, O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(input >= 0 && out >= 0);
    ZrImageInfo info;
    int status = zr_media_convert(helper, input, out, "inline_image", &info, timeout);
    close(input); close(out); return status;
}
static void writeFixture(const char *path, const char *bytes) {
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600); assert(fd >= 0);
    assert(write(fd, bytes, strlen(bytes)) == (ssize_t)strlen(bytes)); close(fd);
}
static void *changeFile(void *path) {
    usleep(50000); writeFixture(path, "ZIMBR-IMAGE changed during decoding"); return NULL;
}
int main(int argc, char **argv) {
    assert(argc == 4);
    const char *native = argv[1], *fake = argv[2];
    char source[4096], output[4096];
    snprintf(source, sizeof(source), "%s/source", argv[3]);
    snprintf(output, sizeof(output), "%s/output", argv[3]);
    umask(0077);
    @autoreleasepool {
        fixture(source, CFSTR("public.jpeg"), NO, 1, 1);
        verify(native, source, output, "inline_image", 1024, 512, 0, 0);
        verify(native, source, output, "viewer", 2048, 1024, 0, 0);
        verify(native, source, output, "avatar", 128, 64, 0, 0);
        fixture(source, CFSTR("public.jpeg"), NO, 6, 1);
        verify(native, source, output, "inline_image", 512, 1024, 0, 0);
        fixture(source, CFSTR("public.png"), YES, 1, 1);
        verify(native, source, output, "inline_image", 1024, 512, 1, 0);
        fixture(source, CFSTR("public.heic"), NO, 6, 1);
        // ImageIO may provide an alpha channel for opaque HEIC thumbnails.
        verify(native, source, output, "inline_image", 512, 1024, -1, 0);
        fixture(source, CFSTR("com.compuserve.gif"), NO, 1, 2);
        verify(native, source, output, "inline_image", 1024, 512, -1, 1);
        writeFixture(source, "not an image");
        assert(convert(native, source, output, 15000) == -5);
        fixture(source, CFSTR("public.png"), NO, 1, 1);
        // Valid PNG header CRC with hostile dimensions. Decode must be rejected
        // from properties, before pixel allocation, independent of extension.
        int fd = open(source, O_RDWR); assert(fd >= 0);
        unsigned char header[33]; assert(pread(fd, header, sizeof(header), 0) == sizeof(header));
        header[16] = 0; header[17] = 1; header[18] = 0x86; header[19] = 0xa1; // 100001
        header[20] = 0; header[21] = 0; header[22] = 3; header[23] = 0xe9; // 1001
        uLong crc = crc32(0, header + 12, 17);
        for (int i = 0; i < 4; i++) header[29 + i] = (crc >> (24 - i * 8)) & 255;
        assert(pwrite(fd, header, sizeof(header), 0) == sizeof(header)); close(fd);
        assert(convert(native, source, output, 15000) == -4);
        fd = open(source, O_RDWR); assert(fd >= 0);
        assert(!ftruncate(fd, 100 * 1024 * 1024 + 1)); close(fd);
        assert(convert(native, source, output, 15000) == -4);
        writeFixture(source, "ZIMBR-TIMEOUT");
        assert(convert(fake, source, output, 100) == -6);
        writeFixture(source, "ZIMBR-IMAGE-SLOW");
        pthread_t thread; assert(!pthread_create(&thread, NULL, changeFile, source));
        assert(convert(fake, source, output, 15000) == -7);
        pthread_join(thread, NULL);
        writeFixture(source, "ZIMBR-IMAGE");
        verify(fake, source, output, "inline_image", 1, 1, 1, 0);
    }
    puts("PASS: native JPEG/PNG/HEIC, EXIF orientation, transparency, still frame, variants, metadata stripping, corrupt/oversized rejection, helper timeout, source mutation");
    return 0;
}
