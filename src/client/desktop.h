#pragma once
#include <stddef.h>
typedef struct SDL_Window SDL_Window;
typedef union SDL_Event SDL_Event;
/* Own one SDL window. The caller owns its SDL renderer. Open returns zero on error. */
int zc_desktop_open(int width, int height, const char *title);
void zc_desktop_close(void);
SDL_Window *zc_desktop_window(void);
void zc_desktop_poll(void);
/* GUI-thread services. The desktop owns the SDL window; workers must stop
 * before zc_desktop_free. Only wake may be called from another thread. */
void zc_desktop_configure(void);
void zc_desktop_init(SDL_Window *window);
void zc_desktop_free(void);
void zc_desktop_wake(void);
int zc_desktop_wait(int timeout_ms);
/* Borrowed until the next get or desktop shutdown. NULL indicates failure. */
const char *zc_desktop_clipboard(void);
int zc_desktop_set_clipboard(const char *text);
/* Clear native composition and enable text input for the focused editor. */
void zc_desktop_reset_input(int enabled);
int zc_desktop_activate(const char *token);
void zc_wayland_init(SDL_Window *window);
void zc_wayland_free(void);

void zc_wayland_poll(void);
int zc_wayland_wait_limit(int timeout_ms);
