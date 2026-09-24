// Deterministic converter for synthetic service tests. This executable has no
// Contacts/ImageIO/TLS code and only reads its approved input descriptor.
#define _POSIX_C_SOURCE 200809L
#include "../media.h"
#include <stdint.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "avatar") && strcmp(argv[1], "inline_image") && strcmp(argv[1], "viewer"))) return 5;
    struct rlimit memory = {512 * 1024 * 1024, 512 * 1024 * 1024};
    (void)setrlimit(RLIMIT_AS, &memory);
    char bytes[64] = {0};
    ssize_t n = pread(3, bytes, sizeof(bytes) - 1, 0);
    if (n < 1) return 5;
    if (!strncmp(bytes, "ZIMBR-TIMEOUT", 13)) { struct timespec delay = {20, 0}; nanosleep(&delay, 0); }
    if (!strncmp(bytes, "ZIMBR-OVERSIZED", 15)) return 4;
    if (strncmp(bytes, "ZIMBR-IMAGE", 11)) return 5;
    if (!strncmp(bytes, "ZIMBR-IMAGE-SLOW", 16)) { struct timespec delay = {0, 300000000}; nanosleep(&delay, 0); }
    // One transparent PNG pixel; safe test bytes are independent of file names.
    static const unsigned char png[] = {137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,6,0,0,0,31,21,196,137,0,0,0,11,73,68,65,84,120,156,99,96,0,2,0,0,5,0,1,122,94,171,63,0,0,0,0,73,69,78,68,174,66,96,130};
    ZrImageInfo info = {1, 1, 1, 0, sizeof(png)};
    if (write(4, png, sizeof(png)) != sizeof(png)) return 5;
    if (!strncmp(bytes, "ZIMBR-IMAGE-LARGE", 17)) {
        if (ftruncate(4, 8 * 1024 * 1024)) return 5;
        info.bytes = 8 * 1024 * 1024;
    }
    if (write(5, &info, sizeof(info)) != sizeof(info)) return 5;
    return 0;
}
