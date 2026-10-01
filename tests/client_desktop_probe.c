/* Native desktop contract probe. Uses the production window, renderer adapter
 * and desktop services; stdin commands only observe or configure the window. */
#define _POSIX_C_SOURCE 200809L
#include "desktop.h"
#include "drop.h"
#include <SDL3/SDL.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

static void hex(const char *bytes, size_t length) {
    for (size_t i = 0; i < length; i++) printf("%02x", (unsigned char)bytes[i]);
}
static void geometry(void) {
    int w, h, pw, ph;
    SDL_GetWindowSize(zc_desktop_window(), &w, &h);
    SDL_GetWindowSizeInPixels(zc_desktop_window(), &pw, &ph);
    printf("size %d %d %d %d %.3f\n", w, h, pw, ph, (double)pw / w);
}
int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (!zc_desktop_open(780, 560, "Desktop contracts")) return 2;
    SDL_Renderer *renderer = SDL_CreateRenderer(zc_desktop_window(), NULL);
    if (!renderer) return 2;
    zc_desktop_reset_input(1);
    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
    char command[128];
    size_t used = 0;
    int last_hover = 0;
    puts("ready");
    zc_desktop_poll();
    int closing = 0;
    while (!closing) {
        zc_desktop_poll();
        SDL_Event event;
        while (SDL_PeepEvents(&event, 1, SDL_GETEVENT, SDL_EVENT_FIRST, SDL_EVENT_LAST) > 0) {
            switch (event.type) {
            case SDL_EVENT_QUIT:
            case SDL_EVENT_WINDOW_CLOSE_REQUESTED: closing = 1; break;
            case SDL_EVENT_WINDOW_RESIZED:
            case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
            case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED: geometry(); break;
            case SDL_EVENT_KEY_DOWN: if (event.key.key == SDLK_A) puts("key a"); break;
            case SDL_EVENT_TEXT_INPUT:
                if (event.text.text) { printf("text "); hex(event.text.text, strlen(event.text.text)); puts(""); }
                break;
            default: break;
            }
        }
        const int hover = zc_drop_hovered();
        if (hover != last_hover) { printf("hover %d\n", hover); last_hover = hover; }
        if (zc_drop_take_error()) puts("rejected");
        ZcDrop dropped;
        if (zc_drop_take(&dropped)) {
            printf("drop %d\n", dropped.count);
            for (int i = 0; i < dropped.count; i++) {
                printf("path "); hex(dropped.paths[i], strlen(dropped.paths[i])); puts("");
            }
        }
        char byte;
        while (read(STDIN_FILENO, &byte, 1) == 1) {
            if (byte != '\n') {
                if (used + 1 == sizeof(command)) return 3;
                command[used++] = byte;
                continue;
            }
            command[used] = 0;
            used = 0;
            if (!strcmp(command, "quit")) { SDL_DestroyRenderer(renderer); zc_desktop_close(); return 0; }
            else if (!strcmp(command, "size")) geometry();
            else if (!strcmp(command, "resize")) SDL_SetWindowSize(zc_desktop_window(), 920, 640);
            else if (!strcmp(command, "clipboard")) {
                const char *clip = zc_desktop_clipboard();
                printf("clipboard ");
                if (clip) hex(clip, strlen(clip));
                puts("");
            } else if (!strcmp(command, "copy")) {
                char clip[8193];
                memset(clip, 'Z', sizeof(clip) - 1);
                clip[sizeof(clip) - 1] = 0;
                if (!zc_desktop_set_clipboard(clip)) return 4;
                puts("copied");
            } else if (!strcmp(command, "pixels")) {
                SDL_SetRenderDrawColor(renderer, 17, 93, 201, 255);
                SDL_RenderClear(renderer);
                SDL_Surface *shot = SDL_RenderReadPixels(renderer, NULL);
                if (!shot) return 5;
                Uint8 r, g, b, a;
                if (!SDL_ReadSurfacePixel(shot, shot->w / 2, shot->h / 2, &r, &g, &b, &a)) return 5;
                printf("pixels %u %u %u %u\n", r, g, b, a);
                SDL_DestroySurface(shot);
            }
        }
        SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        SDL_RenderClear(renderer);
        SDL_RenderPresent(renderer);
        (void)zc_desktop_wait(10);
    }
    SDL_DestroyRenderer(renderer);
    zc_desktop_close();
    return 0;
}
