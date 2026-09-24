#ifndef ZIMBR_MEDIA_H
#define ZIMBR_MEDIA_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
    uint64_t device, inode, bytes;
    int64_t modified_sec, modified_ns, changed_sec, changed_ns;
} ZrMediaFingerprint;
typedef struct {
    uint32_t width, height, png, still;
    uint64_t bytes;
} ZrImageInfo;
// Negative errors are safe categories: -1 unavailable, -2 not local,
// -3 unsafe source, -4 oversized, -5 unsupported/corrupt, -6 timeout,
// -7 source changed, -8 helper unavailable.
int zr_media_directory(const char *path, int create_private);
int zr_media_source(int root, const char *relative, ZrMediaFingerprint *fingerprint);
int zr_media_fingerprint(int fd, ZrMediaFingerprint *fingerprint);
int zr_media_same(const ZrMediaFingerprint *a, const ZrMediaFingerprint *b);
int zr_media_temporary(int directory, const char *name);
int zr_media_install(int directory, int fd, const char *temporary, const char *name);
int zr_media_cached(int directory, const char *name, uint64_t expected_bytes);
int zr_media_remove(int directory, const char *name);
int zr_media_sweep(int directory);
typedef struct ZrMediaScan ZrMediaScan;
ZrMediaScan *zr_media_scan(int directory);
int zr_media_scan_next(ZrMediaScan *scan, char *name, size_t capacity);
void zr_media_scan_close(ZrMediaScan *scan);
int zr_media_convert(const char *helper, int source, int output, const char *variant, ZrImageInfo *info, int timeout_ms);
#endif
