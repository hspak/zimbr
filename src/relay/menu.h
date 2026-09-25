#pragma once
#include <stddef.h>

/* All callbacks run on one background queue. Strings and buffers remain owned
 * by the caller; the relay and callbacks outlive the application event loop. */
typedef struct {
    void *relay;
    int (*read_config)(void *, char *, size_t);
    int (*save_config)(void *, const char *, size_t, const char *, size_t, char *, size_t);
    int (*status)(void *, char *, size_t);
} ZrMenu;

void zr_menu_run(const ZrMenu *menu, const char *config, const char *data, int show_settings);
void zr_menu_reopen(const char *config);
