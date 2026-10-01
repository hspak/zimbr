/* Native desktop contract probe. Uses the production window, renderer adapter
 * and desktop services; stdin commands only observe or configure the window. */
#define _POSIX_C_SOURCE 200809L
#include <GL/gl.h>
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
    zc_desktop_reset_input(1);
    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
    char command[128];
    size_t used = 0;
    int last_hover = 0;
    puts("ready");
    zc_desktop_poll();
    while (!zc_desktop_closing()) {
        if (zc_desktop_resized()) geometry();
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
        size_t length;
        const char *text = zc_desktop_take_text(&length);
        if (length) { printf("text "); hex(text, length); puts(""); }
        if (zc_desktop_key(SDL_SCANCODE_A, 1)) puts("key a");
        char byte;
        while (read(STDIN_FILENO, &byte, 1) == 1) {
            if (byte != '\n') {
                if (used + 1 == sizeof(command)) return 3;
                command[used++] = byte;
                continue;
            }
            command[used] = 0;
            used = 0;
            if (!strcmp(command, "quit")) { zc_desktop_close(); return 0; }
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
            } else if (!strcmp(command, "samples")) {
                int samples = 0;
                SDL_GL_GetAttribute(SDL_GL_MULTISAMPLESAMPLES, &samples);
                printf("samples %d\n", samples);
            }
        }
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        SDL_GL_SwapWindow(zc_desktop_window());
        zc_desktop_poll();
        (void)zc_desktop_wait(10);
    }
    zc_desktop_close();
    return 0;
}
