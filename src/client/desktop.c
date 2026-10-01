#include "desktop.h"
#include "drop.h"
#include <SDL3/SDL.h>

static SDL_Window *window;
static Uint32 wake_event;
static SDL_AtomicInt wake_pending;
static char *clipboard;
void zc_desktop_configure(void) {
    SDL_SetHintWithPriority(SDL_HINT_VIDEO_DRIVER, "wayland", SDL_HINT_OVERRIDE);
    SDL_SetHintWithPriority(SDL_HINT_APP_ID, "zimbr", SDL_HINT_OVERRIDE);
    SDL_SetHintWithPriority(SDL_HINT_IME_IMPLEMENTED_UI, "composition", SDL_HINT_OVERRIDE);
}
void zc_desktop_init(SDL_Window *created) {
    window = created;
    wake_event = SDL_RegisterEvents(1);
    SDL_SetAtomicInt(&wake_pending, 0);
    // Keep the raw URI list: SDL's decoded file events discard information needed
    // to reject malformed escapes and bound the entire transfer before accepting it.
    SDL_SetEventEnabled(SDL_EVENT_DROP_FILE, false);
    SDL_SetEventEnabled(SDL_EVENT_DROP_TEXT, false);
    zc_wayland_init(window);
}
void zc_desktop_free(void) {
    zc_wayland_free();
    SDL_free(clipboard);
    clipboard = NULL;
    window = NULL;
    wake_event = 0;
}
void zc_desktop_wake(void) {
    if (SDL_SetAtomicInt(&wake_pending, 1) == 0 && wake_event) {
        SDL_Event event = { .type = wake_event };
        (void)SDL_PushEvent(&event);
    }
}
int zc_desktop_wait(int timeout_ms) {
    // NULL leaves the event queued for the application event loop.
    if (!SDL_GetAtomicInt(&wake_pending)) (void)SDL_WaitEventTimeout(NULL, zc_wayland_wait_limit(timeout_ms));
    return SDL_SetAtomicInt(&wake_pending, 0);
}
void zc_desktop_reset_input(int enabled) {
    if (!window) return;
    (void)SDL_ClearComposition(window);
    (void)SDL_StopTextInput(window);
    if (enabled) (void)SDL_StartTextInput(window);
}
const char *zc_desktop_clipboard(void) {
    SDL_free(clipboard);
    clipboard = SDL_GetClipboardText();
    return clipboard;
}
int zc_desktop_set_clipboard(const char *value) { return SDL_SetClipboardText(value); }

int zc_desktop_open(int width, int height, const char *title) {
    zc_desktop_configure();
    if (!SDL_Init(SDL_INIT_VIDEO)) return 0;
    window = SDL_CreateWindow(title, width, height,
        SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (!window) { SDL_Quit(); return 0; }
    zc_desktop_init(window);
    return 1;
}
void zc_desktop_close(void) {
    SDL_Window *owned = window;
    SDL_StopTextInput(owned);
    zc_desktop_free();
    SDL_DestroyWindow(owned);
    SDL_Quit();
}
SDL_Window *zc_desktop_window(void) { return window; }
void zc_desktop_poll(void) {
    zc_wayland_poll();
    SDL_PumpEvents();
    zc_wayland_poll();
}
