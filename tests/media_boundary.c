#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "../src/relay/media.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static long milliseconds(void) {
    struct timespec value;
    assert(!clock_gettime(CLOCK_MONOTONIC, &value));
    return value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
static int helper(void) {
    char mode;
    if (pread(3, &mode, 1, 0) != 1) return 5;
    if (getenv("ZIMBR_PRIVATE_TEST") || fcntl(99, F_GETFD) != -1 || errno != EBADF) return 5;
    if (mode == 'h') {
        pid_t child = fork();
        if (child < 0) return 5;
        if (!child) {
            // Retain the metadata writer after the helper itself has exited.
            // This short-lived descendant exits itself; no unrelated PID is killed.
            sleep(3);
            _exit(0);
        }
        return 0;
    }
    if (mode == 't') {
        sleep(3);
        return 0;
    }
    if (mode == 's') {
        raise(SIGKILL);
        return 5;
    }
    if (write(4, "x", 1) != 1) return 5;
    ZrImageInfo info = {.width = 1, .height = 1, .png = 1, .bytes = 1};
    if (mode == 'd') info.width = 100000;
    if (mode == 'b') info.bytes = 2;
    size_t length = mode == 'm' ? 1 : sizeof(info);
    return write(5, &info, length) == (ssize_t)length ? 0 : 5;
}
static int convert(const char *executable, const char *source, const char *output, char mode) {
    int input = open(source, O_RDWR | O_CREAT | O_TRUNC, 0600);
    int result = open(output, O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(input >= 0 && result >= 0);
    assert(write(input, &mode, 1) == 1);
    assert(dup2(input, 99) == 99); // Deliberately lacks FD_CLOEXEC.
    ZrImageInfo info;
    int status = zr_media_convert(executable, input, result, "inline_image", &info, 100);
    close(99); close(input); close(result);
    return status;
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "inline_image")) return helper();
    assert(argc == 4);
    umask(0077);
    assert(!setenv("ZIMBR_PRIVATE_TEST", "must-not-reach-decoder", 1));
    assert(convert(argv[1], argv[2], argv[3], 'v') == 0);
    for (const char *mode = "mdbs"; *mode; mode++)
        assert(convert(argv[1], argv[2], argv[3], *mode) == -5);
    assert(convert("/nonexistent-zimbr-helper", argv[2], argv[3], 'v') == -8);
    assert(convert(argv[1], argv[2], argv[3], 't') == -6);
    long start = milliseconds();
    assert(convert(argv[1], argv[2], argv[3], 'h') == -5);
    assert(milliseconds() - start < 1500);
    // Ensure the fixture's bounded descendant has also finished before exit.
    sleep(3);
    puts("PASS: helper descriptor/environment isolation, failed launch, invalid/truncated metadata, crash, timeout, inherited metadata writer");
    return 0;
}
