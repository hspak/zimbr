#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#include "media.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#endif

static int64_t monotonic_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int component(const char *name) {
    return *name && strcmp(name, ".") && strcmp(name, "..") && !strchr(name, '/');
}
static int error_code(void) {
    return errno == ENOENT ? -2 : (errno == ELOOP || errno == ENOTDIR ? -3 : -1);
}
int zr_media_directory(const char *path, int create_private) {
    if (!path || path[0] != '/' || strlen(path) >= PATH_MAX) return -3;
    char copy[PATH_MAX]; strcpy(copy, path + 1);
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return -1;
    char *remaining = copy, *part;
    while ((part = strsep(&remaining, "/"))) {
        if (!component(part)) { close(fd); return -3; }
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0 && errno == ENOENT && !remaining && create_private) {
            if (mkdirat(fd, part, 0700) && errno != EEXIST) { close(fd); return -1; }
            next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        }
        if (next < 0) { int result = error_code(); close(fd); return result; }
        close(fd); fd = next;
    }
    if (create_private) {
        struct stat st;
        if (fstat(fd, &st) || st.st_uid != getuid() || (st.st_mode & 077)) { close(fd); return -3; }
    }
    return fd;
}
int zr_media_fingerprint(int fd, ZrMediaFingerprint *out) {
    struct stat st;
    if (fstat(fd, &st)) return -1;
    if (!S_ISREG(st.st_mode) || st.st_uid != getuid() || st.st_nlink != 1 || st.st_size < 0) return -3;
    if ((uint64_t)st.st_size > 100 * 1024 * 1024) return -4;
    memset(out, 0, sizeof(*out));
    out->device = st.st_dev; out->inode = st.st_ino; out->bytes = (uint64_t)st.st_size;
#ifdef __APPLE__
    out->modified_sec = st.st_mtimespec.tv_sec; out->modified_ns = st.st_mtimespec.tv_nsec;
    out->changed_sec = st.st_ctimespec.tv_sec; out->changed_ns = st.st_ctimespec.tv_nsec;
#else
    out->modified_sec = st.st_mtim.tv_sec; out->modified_ns = st.st_mtim.tv_nsec;
    out->changed_sec = st.st_ctim.tv_sec; out->changed_ns = st.st_ctim.tv_nsec;
#endif
    return 0;
}
int zr_media_same(const ZrMediaFingerprint *a, const ZrMediaFingerprint *b) {
    return a->device == b->device && a->inode == b->inode && a->bytes == b->bytes &&
        a->modified_sec == b->modified_sec && a->modified_ns == b->modified_ns &&
        a->changed_sec == b->changed_sec && a->changed_ns == b->changed_ns;
}
int zr_media_source(int root, const char *relative, ZrMediaFingerprint *fingerprint) {
    if (root < 0) return -2;
    if (!relative || *relative == '/' || strlen(relative) >= PATH_MAX) return -3;
    char copy[PATH_MAX]; strcpy(copy, relative);
    int dir = fcntl(root, F_DUPFD_CLOEXEC, 6);
    if (dir < 0) return -1;
    char *remaining = copy, *part;
    while ((part = strsep(&remaining, "/"))) {
        if (!component(part)) { close(dir); return -3; }
        int fd = openat(dir, part, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (remaining ? O_DIRECTORY : 0));
        if (fd < 0) { int result = error_code(); close(dir); return result; }
        close(dir); dir = fd;
    }
    int status = zr_media_fingerprint(dir, fingerprint);
    if (status < 0) { close(dir); return status; }
    return dir;
}
int zr_media_temporary(int directory, const char *name) {
    if (!component(name) || strncmp(name, ".tmp-", 5)) return -3;
    return openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
}
int zr_media_install(int directory, int fd, const char *temporary, const char *name) {
    struct stat st;
    if (!component(temporary) || !component(name) || fstat(fd, &st) || !S_ISREG(st.st_mode) ||
        st.st_uid != getuid() || st.st_nlink != 1 || st.st_size < 1 || st.st_size > 8 * 1024 * 1024 ||
        fchmod(fd, 0600) || fsync(fd) || renameat(directory, temporary, directory, name) || fsync(directory)) return -1;
    return 0;
}
int zr_media_cached(int directory, const char *name, uint64_t expected_bytes) {
    if (!component(name)) return -3;
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return error_code();
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || st.st_nlink != 1 ||
        (st.st_mode & 077) || st.st_size < 1 || st.st_size > 8 * 1024 * 1024 || (uint64_t)st.st_size != expected_bytes) {
        close(fd); return -3;
    }
    return fd;
}
int zr_media_remove(int directory, const char *name) {
    if (!component(name)) return -3;
    return unlinkat(directory, name, 0);
}
int zr_media_sweep(int directory) {
    int copy = fcntl(directory, F_DUPFD_CLOEXEC, 6);
    if (copy < 0) return -1;
    DIR *dir = fdopendir(copy);
    if (!dir) { close(copy); return -1; }
    struct dirent *item;
    while ((item = readdir(dir))) if (!strncmp(item->d_name, ".tmp-", 5)) unlinkat(directory, item->d_name, 0);
    closedir(dir); return 0;
}
struct ZrMediaScan { DIR *directory; };
ZrMediaScan *zr_media_scan(int directory) {
    // openat creates an independent directory offset (dup would share it).
    int copy = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (copy < 0) return NULL;
    DIR *dir = fdopendir(copy);
    if (!dir) { close(copy); return NULL; }
    ZrMediaScan *scan = malloc(sizeof(*scan));
    if (!scan) { closedir(dir); return NULL; }
    scan->directory = dir; return scan;
}
int zr_media_scan_next(ZrMediaScan *scan, char *name, size_t capacity) {
    struct dirent *item;
    while ((item = readdir(scan->directory))) {
        size_t n = strlen(item->d_name);
        if (n >= capacity || !component(item->d_name)) continue;
        memcpy(name, item->d_name, n + 1); return (int)n;
    }
    return 0;
}
void zr_media_scan_close(ZrMediaScan *scan) { if (scan) { closedir(scan->directory); free(scan); } }

int zr_media_convert(const char *helper, int source, int output, const char *variant, ZrImageInfo *info, int timeout_ms) {
    ZrMediaFingerprint before, after;
    int source_status = zr_media_fingerprint(source, &before);
    if (source_status) return source_status;
    int pipefd[2];
    if (pipe(pipefd)) return -1;
    // High duplicates avoid collisions with the fixed helper descriptors.
    int input = fcntl(source, F_DUPFD_CLOEXEC, 10), result = fcntl(output, F_DUPFD_CLOEXEC, 10);
    int meta = fcntl(pipefd[1], F_DUPFD_CLOEXEC, 10);
    close(pipefd[1]);
    if (input < 0 || result < 0 || meta < 0) {
        close(input); close(result); close(meta); close(pipefd[0]); return -1;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attrs;
    posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attrs);
    int rc = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    rc |= posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    rc |= posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    rc |= posix_spawn_file_actions_adddup2(&actions, input, 3);
    rc |= posix_spawn_file_actions_adddup2(&actions, result, 4);
    rc |= posix_spawn_file_actions_adddup2(&actions, meta, 5);
    rc |= posix_spawn_file_actions_addclose(&actions, input);
    rc |= posix_spawn_file_actions_addclose(&actions, result);
    rc |= posix_spawn_file_actions_addclose(&actions, meta);
#ifdef __APPLE__
    rc |= posix_spawnattr_setflags(&attrs, POSIX_SPAWN_CLOEXEC_DEFAULT);
#else
    rc |= posix_spawn_file_actions_addclosefrom_np(&actions, 6);
#endif
    char *argv[] = {(char *)helper, (char *)variant, NULL};
    // No relay credentials, user environment, source paths, or shell.
    char *env[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
    pid_t pid = -1;
    if (!rc) rc = posix_spawn(&pid, helper, &actions, &attrs, argv, env);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs);
    close(input); close(result); close(meta);
    if (rc) { close(pipefd[0]); return -8; }
    int status = 0, timeout = 0;
    int64_t deadline = monotonic_ms() + timeout_ms;
    for (;;) {
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) break;
        if (waited < 0 && errno != EINTR) { timeout = 1; break; }
#ifdef __APPLE__
        struct proc_taskinfo task;
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task) && task.pti_resident_size > 512ULL * 1024 * 1024) {
            timeout = 2; break;
        }
#endif
        if (monotonic_ms() >= deadline) { timeout = 1; break; }
        poll(NULL, 0, 10);
    }
    if (timeout) { kill(pid, SIGKILL); while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {} close(pipefd[0]); return timeout == 2 ? -4 : -6; }
    if (!WIFEXITED(status) || WEXITSTATUS(status)) {
        close(pipefd[0]); return WIFEXITED(status) && WEXITSTATUS(status) == 4 ? -4 : -5;
    }
    // Child is gone, so metadata reads cannot hang on an inherited writer.
    ssize_t n = read(pipefd[0], info, sizeof(*info)); close(pipefd[0]);
    unsigned edge = !strcmp(variant, "avatar") ? 128 : !strcmp(variant, "inline_image") ? 1024 : !strcmp(variant, "viewer") ? 2560 : 0;
    if (n != sizeof(*info) || !info->width || !info->height || info->width > edge || info->height > edge ||
        (uint64_t)info->width * info->height * 4 > 32 * 1024 * 1024 || !info->bytes || info->bytes > 8 * 1024 * 1024 || info->png > 1 || info->still > 1) return -5;
    if (zr_media_fingerprint(source, &after) || !zr_media_same(&before, &after)) return -7;
    struct stat encoded;
    if (fstat(output, &encoded) || (uint64_t)encoded.st_size != info->bytes) return -5;
    return 0;
}
