#ifndef ZIMBR_CLIENT_DROP_H
#define ZIMBR_CLIENT_DROP_H
#include <stddef.h>
#define ZC_DROP_FILES 16
#define ZC_DROP_PATH 4096
#define ZC_DROP_BYTES (256u * 1024)
typedef struct {
    int count;
    char paths[ZC_DROP_FILES][ZC_DROP_PATH];
} ZcDrop;
int zc_drop_parse(const char *text, size_t length, ZcDrop *output);
void zc_drop_reject(void);
int zc_drop_take_error(void);
// Accepted file offers only; all access stays on the GUI thread.
void zc_drop_set_hovered(int hovered);
int zc_drop_hovered(void);
#endif
