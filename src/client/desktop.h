#pragma once
#include <stddef.h>
typedef struct SDL_Window SDL_Window;
typedef union SDL_Event SDL_Event;
/* Own one SDL window and its OpenGL 3.3 context. Open returns zero on error. */
int zc_desktop_open(int width, int height, const char *title);
void zc_desktop_close(void);
SDL_Window *zc_desktop_window(void);
void zc_desktop_poll(void);
int zc_desktop_closing(void);
int zc_desktop_resized(void);
int zc_desktop_key(int scancode, int query);
int zc_desktop_button(int button, int query);
float zc_desktop_wheel(void);
void zc_desktop_mouse(float *x, float *y);
/* GUI-thread services. The desktop owns the SDL window; workers must stop
 * before zc_desktop_free. Only wake may be called from another thread. */
void zc_desktop_configure(void);
void zc_desktop_init(SDL_Window *window);
void zc_desktop_free(void);
void zc_desktop_begin_events(void);
/* Called once for each polled SDL event. Nonzero means consumed. */
int zc_desktop_event(const SDL_Event *event);
void zc_desktop_wake(void);
int zc_desktop_wait(int timeout_ms);
/* Borrowed until the next get or desktop shutdown. NULL indicates failure. */
const char *zc_desktop_clipboard(void);
int zc_desktop_set_clipboard(const char *text);
/* Borrowed until the next event batch. Taking text clears its pending length. */
const char *zc_desktop_take_text(size_t *length);
int zc_desktop_text_error(void);
int zc_desktop_composing(void);
int zc_desktop_preedit_changed(void);
/* UTF-8 snapshot; start/selection are SDL character offsets, not byte offsets. */
const char *zc_desktop_preedit(size_t *length, int *start, int *selection);
/* Confirm or cancel the editor's preedit before calling. Clear pending text and
 * composition, discard a possible reset echo, and enable the next editor. */
void zc_desktop_reset_input(int enabled);
int zc_desktop_activate(const char *token);
void zc_wayland_init(SDL_Window *window);
void zc_wayland_free(void);
