#ifndef ZIMBR_CLIENT_DROP_H
#define ZIMBR_CLIENT_DROP_H
#include <stddef.h>
// Match the protocol's maximum attachments per send.
#define ZC_DROP_FILES 16
// Allow a Linux PATH_MAX-sized path, including the terminating NUL.
#define ZC_DROP_PATH 4096
// 256 KiB fits percent-encoded paths for a full drop while bounding Wayland offer reads.
#define ZC_DROP_BYTES (256u * 1024)
typedef struct {
    int count;
    char paths[ZC_DROP_FILES][ZC_DROP_PATH];
} ZcDrop;
int zc_drop_parse(const char *text, size_t length, ZcDrop *output);
/* All-or-none delivery. The pending batch is replaced, never partially appended. */
void zc_drop_offer(const char *text, size_t length);
void zc_drop_paths(int count, const char *const *paths);
int zc_drop_pending(void);
int zc_drop_take(ZcDrop *output);
void zc_drop_reject(void);
int zc_drop_take_error(void);
// Accepted file offers only; all access stays on the GUI thread.
void zc_drop_set_hovered(int hovered);
int zc_drop_hovered(void);
#endif
