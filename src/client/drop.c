#include "drop.h"
#include <string.h>

// Wayland callbacks and the composer consume this on the GUI thread.
static int rejected;
static int hovered;
void zc_drop_set_hovered(int active) { hovered = active; }
int zc_drop_hovered(void) { return hovered; }
void zc_drop_reject(void) { rejected = 1; }
int zc_drop_take_error(void) { int result = rejected; rejected = 0; return result; }
static int hex(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
int zc_drop_parse(const char *text, size_t length, ZcDrop *output) {
    output->count = 0;
    if (length > ZC_DROP_BYTES || memchr(text, 0, length)) goto invalid;
    size_t cursor = 0;
    while (cursor < length) {
        const char *line = text + cursor;
        size_t n = 0;
        while (cursor + n < length && line[n] != '\r' && line[n] != '\n') n++;
        cursor += n;
        while (cursor < length && (text[cursor] == '\r' || text[cursor] == '\n')) cursor++;
        if (!n || line[0] == '#') continue;
        if (output->count == ZC_DROP_FILES || n < 6 || memcmp(line, "file:/", 6)) goto invalid;
        size_t start = 5;
        if (n >= 7 && line[6] == '/') {
            start = 7;
            if (n >= start + 10 && !memcmp(line + start, "localhost/", 10)) start += 9;
        }
        if (start >= n || line[start] != '/') goto invalid;
        size_t used = 0;
        for (size_t i = start; i < n; i++) {
            unsigned char c = (unsigned char)line[i];
            if (c == '%') {
                if (i + 2 >= n) goto invalid;
                int high = hex((unsigned char)line[i + 1]), low = hex((unsigned char)line[i + 2]);
                if (high < 0 || low < 0) goto invalid;
                c = (unsigned char)(high * 16 + low);
                i += 2;
            } else if (c == '?' || c == '#') goto invalid;
            if (c < 32 || c == 127 || used == ZC_DROP_PATH - 1) goto invalid;
            output->paths[output->count][used++] = (char)c;
        }
        output->paths[output->count][used] = 0;
        output->count++;
    }
    return 1;
invalid:
    output->count = 0;
    zc_drop_reject();
    return 0;
}
