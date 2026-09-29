#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#include "uploads.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int component(const char *name) {
    return name && *name && strcmp(name, ".") && strcmp(name, "..") &&
        !strchr(name, '/') && strlen(name) <= 255;
}
static int private_directory(int root, const char *id) {
    if (!component(id)) return -1;
    int fd = openat(root, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) || st.st_uid != getuid() || (st.st_mode & 077)) {
        close(fd); return -1;
    }
    return fd;
}
int zr_upload_directory(int root, const char *id) {
    if (!component(id) || mkdirat(root, id, 0700)) return -1;
    int fd = private_directory(root, id);
    if (fd < 0 || fsync(root)) { if (fd >= 0) close(fd); return -1; }
    return fd;
}
int zr_upload_temporary(int directory, const char *name) {
    if (!component(name)) return -1;
    return openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
}
int zr_upload_write(int fd, const void *bytes, size_t length) {
    const unsigned char *next = bytes;
    while (length) {
        ssize_t count = write(fd, next, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        next += count; length -= (size_t)count;
    }
    return 0;
}
static int regular_file(int fd, uint64_t length) {
    struct stat st;
    // Mirror the shared 100 MiB upload cap at the native descriptor boundary.
    return length <= 100 * 1024 * 1024 && !fstat(fd, &st) && S_ISREG(st.st_mode) &&
        st.st_uid == getuid() && st.st_nlink == 1 && !(st.st_mode & 077) &&
        st.st_size >= 0 && (uint64_t)st.st_size == length;
}
int zr_upload_install(int directory, int fd, const char *temporary, const char *name, uint64_t length) {
    if (!component(temporary) || !component(name) || !strcmp(temporary, name) ||
        !regular_file(fd, length) || fsync(fd)) return -1;
    /* One lease owns this directory; no completed upload is replaced here. */
    struct stat st;
    if (!fstatat(directory, name, &st, AT_SYMLINK_NOFOLLOW) || errno != ENOENT) return -1;
    if (renameat(directory, temporary, directory, name) || fsync(directory)) return -1;
    return 0;
}
int zr_upload_open(int root, const char *id, const char *name, uint64_t length) {
    if (!component(name)) return -1;
    int directory = private_directory(root, id);
    if (directory < 0) return -1;
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    close(directory);
    if (fd < 0) return -1;
    if (!regular_file(fd, length)) { close(fd); return -1; }
    return fd;
}
int zr_upload_remove(int root, const char *id) {
    if (!component(id)) return -1;
    struct stat st;
    if (fstatat(root, id, &st, AT_SYMLINK_NOFOLLOW)) return errno == ENOENT ? 0 : -1;
    /* A hostile replacement must not redirect cleanup to another directory. */
    if (!S_ISDIR(st.st_mode)) return -1;
    int fd = private_directory(root, id);
    if (fd < 0) return -1;
    DIR *dir = fdopendir(fd);
    if (!dir) { close(fd); return -1; }
    int result = 0;
    size_t count = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) result = -1; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        /* Ordinary uploads have at most a partial file and a final file. */
        // A reservation contains only a few files; cap cleanup to avoid traversing arbitrary
        // directories.
        if (++count > 16 || unlinkat(fd, entry->d_name, 0)) { result = -1; break; }
    }
    closedir(dir);
    if (!result && (unlinkat(root, id, AT_REMOVEDIR) || fsync(root))) result = -1;
    return result;
}
