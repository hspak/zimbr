#ifndef ZIMBR_CLIENT_OUTGOING_H
#define ZIMBR_CLIENT_OUTGOING_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t device, inode, bytes;
    int64_t modified_seconds, modified_nanoseconds, changed_seconds, changed_nanoseconds;
} ZcOutgoingFingerprint;

int zc_outgoing_directory(const char *data);
int zc_outgoing_source(const char *path, ZcOutgoingFingerprint *fingerprint);
int zc_outgoing_fingerprint(int fd, ZcOutgoingFingerprint *fingerprint);
int zc_outgoing_create(int directory, const char *id);
int zc_outgoing_open(int directory, const char *id, uint64_t length);
int zc_outgoing_write(int fd, const void *bytes, size_t length);
int zc_outgoing_remove(int directory, const char *id);
void *zc_outgoing_scan(int directory);
int zc_outgoing_next(void *scan, char *name, size_t capacity);
void zc_outgoing_scan_close(void *scan);
#endif
