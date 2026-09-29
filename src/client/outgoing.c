#define _GNU_SOURCE
#include "outgoing.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int valid_id(const char *id) {
    if (strlen(id)!=22) return 0;
    for (const char *p=id;*p;p++)
        if (!((*p>='a' && *p<='z') || (*p>='A' && *p<='Z') ||
              (*p>='0' && *p<='9') || *p=='-' || *p=='_')) return 0;
    return 1;
}
int zc_outgoing_directory(const char *data) {
    int parent=open(data,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (parent<0) return -1;
    int dir=-1;
    if (mkdirat(parent,"outgoing",0700) && errno!=EEXIST) goto end;
    dir=openat(parent,"outgoing",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (dir>=0) {
        struct stat st;
        if (fstat(dir,&st) || st.st_uid!=getuid() || (st.st_mode&0777)!=0700 || fsync(parent)) {
            close(dir); dir=-1;
        }
    }
end:
    close(parent); return dir;
}
int zc_outgoing_fingerprint(int fd, ZcOutgoingFingerprint *fingerprint) {
    struct stat st;
    if (fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_size<0) return 0;
    *fingerprint=(ZcOutgoingFingerprint){
        .device=st.st_dev,.inode=st.st_ino,.bytes=(uint64_t)st.st_size,
        .modified_seconds=st.st_mtim.tv_sec,.modified_nanoseconds=st.st_mtim.tv_nsec,
        .changed_seconds=st.st_ctim.tv_sec,.changed_nanoseconds=st.st_ctim.tv_nsec,
    };
    return 1;
}
int zc_outgoing_source(const char *path, ZcOutgoingFingerprint *fingerprint) {
    int fd=open(path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) return -1;
    if (!zc_outgoing_fingerprint(fd,fingerprint)) { close(fd); return -1; }
    return fd;
}
int zc_outgoing_create(int directory, const char *id) {
    if (!valid_id(id)) return -1;
    return openat(directory,id,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
}
int zc_outgoing_open(int directory, const char *id, uint64_t length) {
    if (!valid_id(id)) return -1;
    int fd=openat(directory,id,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) return -1;
    struct stat st;
    if (fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_uid!=getuid() ||
        st.st_nlink!=1 || (st.st_mode&077) || st.st_size<0 || (uint64_t)st.st_size!=length) {
        close(fd); return -1;
    }
    return fd;
}
int zc_outgoing_write(int fd, const void *bytes, size_t length) {
    const unsigned char *next=bytes;
    while (length) {
        ssize_t count=write(fd,next,length);
        if (count<0 && errno==EINTR) continue;
        if (count<=0) return 0;
        next+=count; length-=(size_t)count;
    }
    return 1;
}
int zc_outgoing_remove(int directory, const char *id) {
    if (!valid_id(id)) return 0;
    if (unlinkat(directory,id,0) && errno!=ENOENT) return 0;
    return fsync(directory)==0;
}
void *zc_outgoing_scan(int directory) {
    int copy=openat(directory,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if (copy<0) return NULL;
    DIR *scan=fdopendir(copy);
    if (!scan) close(copy);
    return scan;
}
int zc_outgoing_next(void *scan, char *name, size_t capacity) {
    for (;;) {
        errno=0;
        struct dirent *entry=readdir(scan);
        if (!entry) return errno ? -1 : 0;
        if (!valid_id(entry->d_name)) continue;
        size_t length=strlen(entry->d_name);
        if (capacity<=length) return -1;
        memcpy(name,entry->d_name,length+1);
        return (int)length;
    }
}
void zc_outgoing_scan_close(void *scan) { closedir(scan); }
