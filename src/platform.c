#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "platform.h"
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <limits.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#ifdef __APPLE__
#include <sys/event.h>
#elif defined(__linux__)
#include <sys/inotify.h>
#endif
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
    int no_delay = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &no_delay, sizeof(no_delay));
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

// File notifications are hints only: callers always re-read SQLite and retain
// a periodic reconciliation scan. Watch the database and its WAL/journal,
// including replacement and sidecar creation; never watch SHM reader traffic.
struct ZrWatch {
    int fd;
    char paths[4][PATH_MAX];
#ifdef __APPLE__
    int files[4];
    dev_t devices[4];
    ino_t inodes[4];
    struct stat snapshots[3];
    int present[3];
#elif defined(__linux__)
    int directory;
    const char *names[3];
#endif
};
#ifdef __APPLE__
static int watch_refresh(ZrWatch *w) {
    int changed = 0;
    for (int i=0; i<4; ++i) {
        struct stat st;
        int exists = stat(w->paths[i], &st) == 0;
        if (i > 0) {
            const struct stat *old = &w->snapshots[i-1];
            if (exists != w->present[i-1] || (exists && (st.st_dev != old->st_dev || st.st_ino != old->st_ino ||
                st.st_size != old->st_size || st.st_mtimespec.tv_sec != old->st_mtimespec.tv_sec ||
                st.st_mtimespec.tv_nsec != old->st_mtimespec.tv_nsec))) changed = 1;
            w->present[i-1] = exists;
            if (exists) w->snapshots[i-1] = st;
        }
        if (w->files[i] >= 0 && (!exists || st.st_dev != w->devices[i] || st.st_ino != w->inodes[i])) {
            close(w->files[i]); w->files[i] = -1;
        }
        if (!exists || w->files[i] >= 0) continue;
        int fd = open(w->paths[i], O_EVTONLY | O_CLOEXEC);
        if (fd < 0) continue;
        struct kevent event;
        EV_SET(&event, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
               NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE, 0, NULL);
        if (kevent(w->fd, &event, 1, NULL, 0, NULL) < 0) { close(fd); continue; }
        w->files[i] = fd; w->devices[i] = st.st_dev; w->inodes[i] = st.st_ino;
    }
    return changed;
}
#endif
ZrWatch *zr_watch_open(const char *path) {
    ZrWatch *w = calloc(1, sizeof(*w));
    if (!w) return NULL;
    w->fd = -1;
    if (snprintf(w->paths[1], PATH_MAX, "%s", path) >= PATH_MAX ||
        snprintf(w->paths[2], PATH_MAX, "%s-wal", path) >= PATH_MAX ||
        snprintf(w->paths[3], PATH_MAX, "%s-journal", path) >= PATH_MAX) { free(w); return NULL; }
    const char *slash = strrchr(path, '/');
    if (slash) {
        size_t len = slash == path ? 1 : (size_t)(slash-path);
        memcpy(w->paths[0], path, len); w->paths[0][len] = 0;
    } else strcpy(w->paths[0], ".");
#ifdef __APPLE__
    for (int i=0; i<4; ++i) w->files[i] = -1;
    w->fd = kqueue();
    if (w->fd >= 0) { fcntl(w->fd, F_SETFD, FD_CLOEXEC); watch_refresh(w); }
#elif defined(__linux__)
    w->fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    w->directory = -1;
    for (int i=0; i<3; ++i) {
        const char *p = strrchr(w->paths[i+1], '/');
        w->names[i] = p ? p+1 : w->paths[i+1];
    }
#endif
    if (w->fd < 0) { free(w); return NULL; }
    return w;
}
int zr_watch_wait(ZrWatch *w, int timeout_ms) {
    if (!w) { poll(NULL, 0, timeout_ms); return 0; }
    int64_t deadline = zr_monotonic_ms() + timeout_ms;
    for (;;) {
    int left = (int)(deadline - zr_monotonic_ms());
    if (left < 0) left = 0;
#ifdef __APPLE__
    if (watch_refresh(w)) return 1;
    struct kevent events[8];
    struct timespec timeout = { .tv_sec = left/1000, .tv_nsec = (left%1000)*1000000L };
    int n = kevent(w->fd, NULL, 0, events, 8, &timeout);
    if (n <= 0) return 0;
    int changed = 0;
    for (int i=0; i<n; ++i) if ((int)events[i].ident != w->files[0]) changed = 1;
    changed |= watch_refresh(w);
    if (changed) return 1;
#elif defined(__linux__)
    if (w->directory < 0) w->directory = inotify_add_watch(w->fd, w->paths[0],
        IN_MODIFY | IN_CLOSE_WRITE | IN_CREATE | IN_MOVED_TO | IN_MOVED_FROM | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF);
    struct pollfd p = { .fd = w->fd, .events = POLLIN };
    if (poll(&p, 1, left) <= 0) return 0;
    union { struct inotify_event align; char bytes[8192]; } buffer;
    int changed = 0;
    ssize_t n;
    while ((n = read(w->fd, buffer.bytes, sizeof(buffer.bytes))) > 0) {
        for (size_t pos=0; pos < (size_t)n;) {
            struct inotify_event *event = (struct inotify_event *)(buffer.bytes+pos);
            if (event->wd == w->directory && (event->mask & (IN_IGNORED | IN_DELETE_SELF | IN_MOVE_SELF))) {
                if (!(event->mask & IN_IGNORED)) inotify_rm_watch(w->fd, w->directory);
                w->directory = -1; changed = 1;
            }
            if (event->mask & IN_Q_OVERFLOW) changed = 1;
            for (int i=0; event->len && i<3; ++i) if (!strcmp(event->name, w->names[i])) changed = 1;
            pos += sizeof(*event) + event->len;
        }
    }
    if (changed) return 1;
#else
    poll(NULL, 0, left); return 0;
#endif
    if (zr_monotonic_ms() >= deadline) return 0;
    }
}
void zr_watch_close(ZrWatch *w) {
    if (!w) return;
#ifdef __APPLE__
    for (int i=0; i<4; ++i) if (w->files[i] >= 0) close(w->files[i]);
#endif
    close(w->fd); free(w);
}
