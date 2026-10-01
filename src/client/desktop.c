#include "desktop.h"
#include "drop.h"
#include <SDL3/SDL.h>
#include <string.h>

static SDL_Window *window;
static Uint32 wake_event;
static SDL_AtomicInt wake_pending;
static char *clipboard;
// Match the editor budget. Reject an oversized batch without inserting a prefix.
static char text[16385];
static size_t text_length;
static int text_error;
static int composing;
static int composition_in_batch;
static char preedit[16385];
static size_t preedit_length;
static int preedit_start, preedit_selection, preedit_changed;
static char reset_text[16385];
static size_t reset_length;

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
    text_length = 0;
    text_error = composing = composition_in_batch = 0;
    preedit_length = 0;
    preedit_changed = 0;
    reset_length = 0;
    wake_event = 0;
}
void zc_desktop_wake(void) {
    if (SDL_SetAtomicInt(&wake_pending, 1) == 0 && wake_event) {
        SDL_Event event = { .type = wake_event };
        (void)SDL_PushEvent(&event);
    }
}
int zc_desktop_wait(int timeout_ms) {
    // NULL leaves the event queued for the next input batch.
    if (!SDL_GetAtomicInt(&wake_pending)) (void)SDL_WaitEventTimeout(NULL, timeout_ms);
    return SDL_SetAtomicInt(&wake_pending, 0);
}
void zc_desktop_begin_events(void) {
    text_length = 0;
    text_error = 0;
    composition_in_batch = composing;
    preedit_changed = 0;
}
int zc_desktop_event(const SDL_Event *event) {
    // A new keystroke or nonempty preedit starts a new composition transaction.
    if (event->type == SDL_EVENT_KEY_DOWN) reset_length = 0;
    if (event->type == SDL_EVENT_TEXT_EDITING) {
        const char *value = event->edit.text ? event->edit.text : "";
        const size_t length = strlen(value);
        if (length) reset_length = 0;
        preedit_changed = 1;
        preedit_length = 0;
        if (length >= sizeof(preedit)) text_error = 1;
        else {
            memcpy(preedit, value, length + 1);
            preedit_length = length;
        }
        preedit_start = event->edit.start;
        preedit_selection = event->edit.length;
        composing = length != 0;
        composition_in_batch |= composing;
        return 1;
    }
    if (event->type == SDL_EVENT_TEXT_INPUT) {
        const size_t length = strlen(event->text.text);
        // IBus/Hangul may commit asynchronously in response to Reset. The caller
        // already confirmed or cancelled that preedit before moving focus.
        // Discard only its exact echo, once, before any new typing/composition.
        if (reset_length) {
            const int echo = length == reset_length && !memcmp(event->text.text, reset_text, length);
            reset_length = 0;
            if (echo) return 1;
        }
        if (length > sizeof(text) - 1 - text_length || text_error) {
            text_error = 1;
            text_length = 0;
        } else {
            memcpy(text + text_length, event->text.text, length);
            text_length += length;
            text[text_length] = 0;
        }
        composing = 0;
        preedit_length = 0;
        preedit_changed = 1;
        return 1;
    }
    if (event->type == SDL_EVENT_WINDOW_FOCUS_LOST) {
        composing = 0;
        preedit_length = 0;
        preedit_changed = 1;
    }
    return event->type == wake_event;
}
const char *zc_desktop_take_text(size_t *length) {
    *length = text_length;
    text_length = 0;
    return text;
}
int zc_desktop_text_error(void) { return text_error; }
int zc_desktop_composing(void) { return composing || composition_in_batch; }
int zc_desktop_preedit_changed(void) { return preedit_changed; }
const char *zc_desktop_preedit(size_t *length, int *start, int *selection) {
    preedit_changed = 0;
    *length = preedit_length;
    *start = preedit_start;
    *selection = preedit_selection;
    return preedit;
}
void zc_desktop_reset_input(int enabled) {
    if (preedit_length) {
        memcpy(reset_text, preedit, preedit_length);
        reset_length = preedit_length;
    }
    if (window) {
        (void)SDL_ClearComposition(window);
        (void)SDL_StopTextInput(window);
        if (enabled) (void)SDL_StartTextInput(window);
    }
    text_length = preedit_length = 0;
    text_error = composing = preedit_changed = 0;
}
const char *zc_desktop_clipboard(void) {
    SDL_free(clipboard);
    clipboard = SDL_GetClipboardText();
    return clipboard;
}
int zc_desktop_set_clipboard(const char *value) { return SDL_SetClipboardText(value); }

static SDL_GLContext gl_context;
static unsigned char keys[SDL_SCANCODE_COUNT][4];
static unsigned char buttons[6][4];
static float mouse_x, mouse_y, wheel;
static int closing, resized;

int zc_desktop_open(int width, int height, const char *title) {
    zc_desktop_configure();
    if (!SDL_Init(SDL_INIT_VIDEO)) return 0;
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 0);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 0);
    SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1);
    SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, 4);
    window = SDL_CreateWindow(title, width, height,
        SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (!window) { SDL_Quit(); return 0; }
    gl_context = SDL_GL_CreateContext(window);
    if (!gl_context) { SDL_DestroyWindow(window); window = NULL; SDL_Quit(); return 0; }
    SDL_GL_SetSwapInterval(0);
    zc_desktop_init(window);
    memset(keys, 0, sizeof(keys));
    memset(buttons, 0, sizeof(buttons));
    mouse_x = mouse_y = wheel = 0;
    closing = resized = 0;
    return 1;
}
void zc_desktop_close(void) {
    SDL_Window *owned = window;
    SDL_StopTextInput(owned);
    zc_desktop_free();
    SDL_GL_DestroyContext(gl_context);
    gl_context = NULL;
    SDL_DestroyWindow(owned);
    SDL_Quit();
    memset(keys, 0, sizeof(keys));
    memset(buttons, 0, sizeof(buttons));
    wheel = 0;
}
SDL_Window *zc_desktop_window(void) { return window; }
int zc_desktop_closing(void) { return closing; }
int zc_desktop_resized(void) { return resized; }
int zc_desktop_key(int scancode, int query) {
    return scancode >= 0 && scancode < SDL_SCANCODE_COUNT && query >= 0 && query < 4
        ? keys[scancode][query] : 0;
}
int zc_desktop_button(int button, int query) {
    return button > 0 && button < 6 && query >= 0 && query < 4 ? buttons[button][query] : 0;
}
float zc_desktop_wheel(void) { return wheel; }
void zc_desktop_mouse(float *x, float *y) { *x = mouse_x; *y = mouse_y; }
static void transition(unsigned char bits[4], int down, int repeat) {
    if (repeat) bits[3] = 1;
    else if (down != bits[0]) bits[down ? 1 : 2] = 1;
    bits[0] = down;
}
void zc_desktop_poll(void) {
    for (int i = 0; i < SDL_SCANCODE_COUNT; ++i) memset(keys[i] + 1, 0, 3);
    for (int i = 0; i < 6; ++i) memset(buttons[i] + 1, 0, 3);
    wheel = 0;
    resized = 0;
    zc_desktop_begin_events();
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        if (zc_desktop_event(&event)) continue;
        switch (event.type) {
        case SDL_EVENT_QUIT:
        case SDL_EVENT_WINDOW_CLOSE_REQUESTED: closing = 1; break;
        case SDL_EVENT_WINDOW_RESIZED:
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
        case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED: resized = 1; break;
        case SDL_EVENT_KEY_DOWN:
        case SDL_EVENT_KEY_UP:
            if (event.key.scancode > SDL_SCANCODE_UNKNOWN && event.key.scancode < SDL_SCANCODE_COUNT)
                transition(keys[event.key.scancode], event.key.down, event.key.repeat);
            break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP:
            if (event.button.button > 0 && event.button.button < 6)
                transition(buttons[event.button.button], event.button.down, 0);
            mouse_x = event.button.x; mouse_y = event.button.y;
            break;
        case SDL_EVENT_MOUSE_MOTION: mouse_x = event.motion.x; mouse_y = event.motion.y; break;
        case SDL_EVENT_MOUSE_WHEEL:
            wheel += event.wheel.y * (event.wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -1 : 1);
            break;
        case SDL_EVENT_WINDOW_FOCUS_LOST:
            for (int i = 0; i < SDL_SCANCODE_COUNT; ++i) transition(keys[i], 0, 0);
            for (int i = 0; i < 6; ++i) transition(buttons[i], 0, 0);
            break;
        default: break;
        }
    }
}
