#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "platform.h"
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
int zr_random(void *bytes, size_t length) {
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t pos = 0;
    while (pos < length) {
        ssize_t n = read(fd, (char *)bytes + pos, length - pos);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return -1; }
        pos += (size_t)n;
    }
    close(fd); return 0;
}
int64_t zr_now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
int zr_timestamp(int64_t ns, char *out, size_t cap) {
    // Contemporary Messages uses nanoseconds since 2001; preserve subsecond precision.
    int64_t sec = ns / 1000000000;
    int64_t rem = ns % 1000000000;
    if (rem < 0) { --sec; rem += 1000000000; }
    time_t unix_sec = (time_t)(sec + 978307200);
    struct tm t;
    if (!gmtime_r(&unix_sec, &t) || t.tm_year < 0 || t.tm_year > 8099) return -1;
    char date[32];
    if (!strftime(date, sizeof(date), "%Y-%m-%dT%H:%M:%S", &t)) return -1;
    int n = snprintf(out, cap, "%s.%09lldZ", date, (long long)rem);
    return n > 0 && (size_t)n < cap ? n : -1;
}
int zr_file_identity(const char *path, char *out, size_t cap) {
    struct stat s;
    if (stat(path, &s)) return -1;
    int n = snprintf(out, cap, "%llu:%llu", (unsigned long long)s.st_dev, (unsigned long long)s.st_ino);
    return n > 0 && (size_t)n < cap ? n : -1;
}
int zr_secure_file(const char *path, const void *data, size_t length, int replace) {
    int fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (replace ? O_TRUNC : O_EXCL), 0600);
    if (fd < 0) return -1;
    struct stat s;
    if (fstat(fd, &s) || s.st_uid != getuid() || !S_ISREG(s.st_mode) || fchmod(fd, 0600)) { close(fd); return -1; }
    size_t pos = 0;
    while (pos < length) {
        ssize_t n = write(fd, (const char *)data + pos, length - pos);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return -1; }
        pos += (size_t)n;
    }
    int rc = fsync(fd); close(fd); return rc;
}
int zr_read_secret(const char *path, char *out, size_t cap) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat s;
    if (fstat(fd, &s) || s.st_uid != getuid() || (s.st_mode & 077) || !S_ISREG(s.st_mode)) { close(fd); return -1; }
    ssize_t n = read(fd, out, cap); close(fd);
    return n >= 0 && (size_t)n < cap ? (int)n : -1;
}
void zr_socket_timeout(int fd) {
    struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
#ifdef SO_NOSIGPIPE
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
}
// Fixed script and data-only argv. Retain at most 128 bytes of known status
// markers; stderr is discarded. Kill and reap on timeout or excess output.
int zr_spawn(const char *script, const char *mode, const char *route, const char *text, int timeout_ms) {
    int output[2];
    if (pipe(output)) return -2;
    fcntl(output[0], F_SETFD, FD_CLOEXEC); fcntl(output[1], F_SETFD, FD_CLOEXEC);
    fcntl(output[0], F_SETFL, O_NONBLOCK);
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions)) { close(output[0]); close(output[1]); return -2; }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, output[1], 1);
    posix_spawn_file_actions_addclose(&actions, output[0]);
    posix_spawn_file_actions_addclose(&actions, output[1]);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    char *argv[] = { "/usr/bin/osascript", "-e", (char *)script, "--", (char *)mode, (char *)route, (char *)text, NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, argv[0], &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions); close(output[1]);
    if (rc) { close(output[0]); return -2; }
    struct timespec start, now, pause = { .tv_sec = 0, .tv_nsec = 20000000 };
    clock_gettime(CLOCK_MONOTONIC, &start);
    char result[129] = {0}; size_t used = 0;
    for (;;) {
        ssize_t n = read(output[0], result + used, 128 - used);
        if (n > 0) used += (size_t)n;
        int status;
        pid_t got = waitpid(pid, &status, WNOHANG);
        if (got == pid) {
            // Drain the final marker after observing process exit.
            n = read(output[0], result + used, 128 - used);
            if (n > 0) used += (size_t)n;
            close(output[0]);
            if (!WIFEXITED(status) || WEXITSTATUS(status) != 0 || used >= 128) return -1;
            while (used && (result[used-1] == '\n' || result[used-1] == '\r')) result[--used] = 0;
            if (!strcmp(result,"ready") || !strcmp(result,"invoked")) return 0;
            if (!strcmp(result,"permission_required")) return 1;
            if (!strcmp(result,"unsupported_account")) return 2;
            if (!strcmp(result,"unsupported_target")) return 3;
            if (!strcmp(result,"adapter_unavailable")) return 4;
            return -1;
        }
        if (got < 0 && errno != EINTR) { close(output[0]); return -1; }
        clock_gettime(CLOCK_MONOTONIC, &now);
        int64_t elapsed = (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000;
        if (elapsed >= timeout_ms || used >= 128) {
            kill(pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
            close(output[0]); return -1;
        }
        nanosleep(&pause, NULL);
    }
}
#include <sys/file.h>
int zr_lock(const char *path) {
    int fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    struct stat s;
    if (fstat(fd, &s) || s.st_uid != getuid() || !S_ISREG(s.st_mode) || flock(fd, LOCK_EX | LOCK_NB)) { close(fd); return -1; }
    return fd;
}
#include <poll.h>
int64_t zr_monotonic_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
ptrdiff_t zr_recv(int fd, void *buffer, size_t length, int64_t deadline_ms) {
    for (;;) {
        int64_t left = deadline_ms - zr_monotonic_ms();
        if (left <= 0) return -1;
        struct pollfd p = { .fd = fd, .events = POLLIN };
        int rc = poll(&p, 1, left > 10000 ? 10000 : (int)left);
        if (rc < 0 && errno == EINTR) continue;
        if (rc <= 0) return -1;
        ssize_t n = recv(fd, buffer, length, 0);
        if (n < 0 && errno == EINTR) continue;
        return n;
    }
}
int zr_send(int fd, const void *buffer, size_t length) {
    size_t offset = 0; int64_t deadline = zr_monotonic_ms() + 10000;
    while (offset < length) {
        int64_t left = deadline - zr_monotonic_ms();
        if (left <= 0) return -1;
        struct pollfd p = { .fd = fd, .events = POLLOUT };
        int rc = poll(&p, 1, (int)left);
        if (rc < 0 && errno == EINTR) continue;
        if (rc <= 0) return -1;
#ifdef MSG_NOSIGNAL
        int flags = MSG_NOSIGNAL;
#else
        int flags = 0;
#endif
        ssize_t n = send(fd, (const char *)buffer + offset, length - offset, flags);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        offset += (size_t)n;
    }
    return 0;
}
int zr_socket_closed(int fd) {
    struct pollfd p = { .fd = fd, .events = POLLIN };
    if (poll(&p, 1, 0) <= 0) return 0;
    if (p.revents & (POLLHUP | POLLERR | POLLNVAL)) return 1;
    char byte;
    return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0;
}
