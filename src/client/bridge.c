#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "bridge.h"
#include <curl/curl.h>
#include <pango/pangocairo.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <math.h>
#include <limits.h>
#include <poll.h>
#include <unistd.h>

struct Slot { CURL *easy; char *body; size_t len; long status; int done, stream; int64_t last_rx; struct ZcNet *owner; };
struct ZcNet { CURLM *multi; struct curl_slist *headers; struct Slot slots[2]; unsigned port; ZcStreamFn fn; void *context; };
static int64_t monotonic_ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return (int64_t)ts.tv_sec*1000+ts.tv_nsec/1000000; }
static int progress(void *context, curl_off_t a, curl_off_t b, curl_off_t c, curl_off_t d) {
    (void)a; (void)b; (void)c; (void)d;
    struct Slot *s=context;
    return s->stream && monotonic_ms()-s->last_rx>45000;
}
static size_t receive(char *data, size_t size, size_t count, void *context) {
    struct Slot *s = context; size_t n = size * count; s->last_rx=monotonic_ms();
    if (s->stream) {
        long status = 0; curl_easy_getinfo(s->easy, CURLINFO_RESPONSE_CODE, &status);
        if (status != 200) return n;
        return s->owner->fn(s->owner->context, data, n) ? n : 0;
    }
    if (n > 64*1024*1024 - s->len) return 0;
    char *next = realloc(s->body, s->len + n + 1); if (!next) return 0;
    s->body = next; memcpy(next + s->len, data, n); s->len += n; next[s->len] = 0; return n;
}
ZcNet *zc_net_new(const char *token, unsigned port, ZcStreamFn fn, void *context) {
    if (curl_global_init(CURL_GLOBAL_DEFAULT)) return NULL;
    ZcNet *n = calloc(1, sizeof(*n)); if (!n) { curl_global_cleanup(); return NULL; }
    n->multi = curl_multi_init(); n->port = port; n->fn = fn; n->context = context;
    char auth[96]; snprintf(auth, sizeof(auth), "Authorization: Bearer %s", token);
    n->headers = curl_slist_append(NULL, auth); memset(auth, 0, sizeof(auth));
    n->headers = curl_slist_append(n->headers, "Content-Type: application/json");
    return n;
}
static void clear_slot(ZcNet *n, int index) {
    struct Slot *s = &n->slots[index];
    if (s->easy) { curl_multi_remove_handle(n->multi, s->easy); curl_easy_cleanup(s->easy); }
    free(s->body); memset(s, 0, sizeof(*s));
}
void zc_net_free(ZcNet *n) { if (!n) return; clear_slot(n,0); clear_slot(n,1); curl_slist_free_all(n->headers); curl_multi_cleanup(n->multi); free(n); curl_global_cleanup(); }
int zc_net_start(ZcNet *n, int stream, const char *path, const char *body) {
    if (n->slots[stream].easy || path[0] != '/') return 0;
    struct Slot *s = &n->slots[stream]; s->easy = curl_easy_init(); if (!s->easy) return 0;
    s->owner = n; s->stream = stream; s->last_rx=monotonic_ms();
    char url[8192]; if (snprintf(url, sizeof(url), "http://127.0.0.1:%u%s", n->port, path) >= (int)sizeof(url)) { clear_slot(n,stream); return 0; }
    curl_easy_setopt(s->easy, CURLOPT_URL, url);
    curl_easy_setopt(s->easy, CURLOPT_PROXY, "");
    curl_easy_setopt(s->easy, CURLOPT_PROTOCOLS_STR, "http");
    curl_easy_setopt(s->easy, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(s->easy, CURLOPT_HTTPHEADER, n->headers);
    curl_easy_setopt(s->easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(s->easy, CURLOPT_CONNECTTIMEOUT_MS, 3000L);
    curl_easy_setopt(s->easy, CURLOPT_TIMEOUT_MS, stream ? 0L : 7000L);
    if (!stream) {
        curl_easy_setopt(s->easy, CURLOPT_LOW_SPEED_LIMIT, 1L);
        curl_easy_setopt(s->easy, CURLOPT_LOW_SPEED_TIME, 7L);
    }
    curl_easy_setopt(s->easy, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(s->easy, CURLOPT_XFERINFOFUNCTION, progress);
    curl_easy_setopt(s->easy, CURLOPT_XFERINFODATA, s);
    curl_easy_setopt(s->easy, CURLOPT_WRITEFUNCTION, receive);
    curl_easy_setopt(s->easy, CURLOPT_WRITEDATA, s);
    curl_easy_setopt(s->easy, CURLOPT_PRIVATE, s);
    if (body) { curl_easy_setopt(s->easy, CURLOPT_POST, 1L); curl_easy_setopt(s->easy, CURLOPT_COPYPOSTFIELDS, body); }
    return curl_multi_add_handle(n->multi, s->easy) == CURLM_OK;
}
void zc_net_cancel_stream(ZcNet *n) { clear_slot(n, 1); }
void zc_net_cancel_request(ZcNet *n) { clear_slot(n, 0); }
int zc_net_wait(ZcNet *n, int wake_fd, int timeout_ms) {
    int ready = 0;
    if (n) {
        struct curl_waitfd wake = { .fd = wake_fd, .events = CURL_WAIT_POLLIN, .revents = 0 };
        if (curl_multi_poll(n->multi, &wake, wake_fd >= 0 ? 1 : 0, timeout_ms, &ready) != CURLM_OK) return 0;
    } else {
        struct pollfd wake = { .fd = wake_fd, .events = POLLIN };
        poll(&wake, wake_fd >= 0 ? 1 : 0, timeout_ms);
    }
    if (wake_fd >= 0) { char bytes[128]; while (read(wake_fd, bytes, sizeof(bytes)) > 0) {} }
    return 1;
}
int zc_net_poll(ZcNet *n) {
    int active = 0; if (curl_multi_perform(n->multi, &active) != CURLM_OK) return 0;
    int queued; CURLMsg *m;
    while ((m = curl_multi_info_read(n->multi, &queued))) if (m->msg == CURLMSG_DONE) {
        struct Slot *s = NULL; curl_easy_getinfo(m->easy_handle, CURLINFO_PRIVATE, &s);
        curl_easy_getinfo(m->easy_handle, CURLINFO_RESPONSE_CODE, &s->status);
        if (m->data.result != CURLE_OK && (!s->stream || s->status == 200)) s->status = 0;
        s->done = 1;
    }
    return 1;
}
int zc_net_done(ZcNet *n, int stream) { return n->slots[stream].done; }
long zc_net_status(ZcNet *n, int stream) {
    struct Slot *s = &n->slots[stream]; long status = s->status;
    if (s->easy && !s->done) curl_easy_getinfo(s->easy, CURLINFO_RESPONSE_CODE, &status);
    return status;
}
const char *zc_net_body(ZcNet *n, size_t *length) { *length=n->slots[0].len; return n->slots[0].body; }
void zc_net_ack(ZcNet *n, int stream) { clear_slot(n, stream); }

struct ZcText { PangoLayout *layout; cairo_surface_t *surface; int width, height; double scale; };
static cairo_t *text_context(cairo_surface_t *surface, double scale, int top) {
    cairo_t *cr = cairo_create(surface);
    cairo_translate(cr, 0, -top);
    cairo_scale(cr, scale, scale);
    cairo_font_options_t *options = cairo_font_options_create();
    // Smooth glyph edges with grayscale coverage, suitable for transparent
    // textures without LCD subpixel color fringes.
    cairo_font_options_set_antialias(options, CAIRO_ANTIALIAS_GRAY);
    cairo_font_options_set_hint_style(options, CAIRO_HINT_STYLE_SLIGHT);
    cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_ON);
    cairo_set_font_options(cr, options);
    cairo_font_options_destroy(options);
    return cr;
}
ZcText *zc_text_new(const char *text, int length, double size, int width, double scale) {
    if (length < 0 || length > 65536 || !isfinite(size) || size < 1 || size > 256 ||
        length*(size + 4)*PANGO_SCALE > INT_MAX - 1048576.0 ||
        !isfinite(scale) || scale < .5 || scale > 8 || width < 1 || (width + 2.0)*scale > 4096) return NULL;
    if (!length) text = "";
    if (!text) return NULL;
    if (!g_utf8_validate(text, length, NULL)) return NULL;
    // WORD_CHAR repeatedly reshapes the remainder of a long unbroken word.
    // Character wrapping bounds that cost for URLs and pasted machine output.
    int char_wrap = 0, marks = 0, lines = 1;
    const char *word = text;
    for (const char *p = text; p < text + length; p = g_utf8_next_char(p)) {
        gunichar ch = g_utf8_get_char(p);
        if ((ch == '\n' || ch == '\r' || ch == 0x2028 || ch == 0x2029) && ++lines > 2048) return NULL;
        GUnicodeType type = g_unichar_type(ch);
        if (type == G_UNICODE_NON_SPACING_MARK || type == G_UNICODE_SPACING_MARK ||
            type == G_UNICODE_ENCLOSING_MARK || type == G_UNICODE_FORMAT) {
            if (++marks > 32) return NULL;
        } else marks = 0;
        if (g_unichar_isspace(ch)) word = p;
        if (p - word > 512) char_wrap = 1;
    }
    ZcText *t = calloc(1, sizeof(*t)); if (!t) return NULL; t->scale = scale;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
    // Shape and hint at the same device scale used for rasterization. Creating
    // the layout at 1x then drawing it at fractional scale softens small text.
    cairo_t *cr = text_context(surface, scale, 0); t->layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_new();
    pango_font_description_set_family(font, "sans-serif");
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_layout_set_font_description(t->layout, font); pango_font_description_free(font);
    pango_layout_set_text(t->layout, text, length);
    pango_layout_set_width(t->layout, width > 0 ? width * PANGO_SCALE : -1);
    pango_layout_set_wrap(t->layout, char_wrap ? PANGO_WRAP_CHAR : PANGO_WRAP_WORD_CHAR);
    pango_layout_set_spacing(t->layout, 3 * PANGO_SCALE);
    pango_layout_get_pixel_size(t->layout, &t->width, &t->height);
    // A single unbreakable grapheme can exceed the requested width. Clip it;
    // never make an enormous texture or stretch it to fit the message bubble.
    t->width = (int)((MIN(t->width, width) + 2.0) * scale + .5);
    double height = (t->height + 2.0) * scale + .5;
    cairo_destroy(cr); cairo_surface_destroy(surface);
    if (height < 1 || height > INT_MAX || t->width < 1) { zc_text_free(t); return NULL; }
    t->height = (int)height;
    return t;
}
void zc_text_clear_pixels(ZcText *t) { if (t->surface) cairo_surface_destroy(t->surface); t->surface = NULL; }
void zc_text_free(ZcText *t) { if (!t) return; zc_text_clear_pixels(t); g_object_unref(t->layout); free(t); }
int zc_text_width(ZcText *t) { return t->width; }
int zc_text_height(ZcText *t) { return t->height; }
unsigned char *zc_text_pixels(ZcText *t, unsigned color, int start, int end, int top, int height) {
    zc_text_clear_pixels(t);
    if (top < 0 || top >= t->height || height < 1 || height > 2048 ||
        height > t->height - top || (size_t)t->width * (size_t)height > 8*1024*1024) return NULL;
    t->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, t->width, height);
    if (cairo_surface_status(t->surface) != CAIRO_STATUS_SUCCESS) { zc_text_clear_pixels(t); return NULL; }
    cairo_t *cr = text_context(t->surface, t->scale, top);
    // Use the measured layout unchanged. Only draw lines intersecting this
    // tile; drawing the entire document still shapes/rasterizes offscreen text.
    PangoLayoutIter *it = pango_layout_get_iter(t->layout);
    do {
        PangoRectangle ink, logical;
        pango_layout_iter_get_line_extents(it, &ink, &logical);
        double bottom = MAX(ink.y + ink.height, logical.y + logical.height)/(double)PANGO_SCALE*t->scale;
        double line_top = MIN(ink.y, logical.y)/(double)PANGO_SCALE*t->scale;
        if (bottom < top || line_top > top + height) continue;
        PangoLayoutLine *line = pango_layout_iter_get_line_readonly(it);
        if (start != end) {
            int *ranges, n;
            pango_layout_line_get_x_ranges(line, start, end, &ranges, &n);
            cairo_set_source_rgba(cr, .24, .48, .86, .42);
            for (int i=0; i<n; ++i) cairo_rectangle(cr, ranges[i*2]/(double)PANGO_SCALE, logical.y/(double)PANGO_SCALE, (ranges[i*2+1]-ranges[i*2])/(double)PANGO_SCALE, logical.height/(double)PANGO_SCALE);
            cairo_fill(cr); g_free(ranges);
        }
        cairo_set_source_rgba(cr, ((color>>24)&255)/255., ((color>>16)&255)/255., ((color>>8)&255)/255., (color&255)/255.);
        cairo_move_to(cr, logical.x/(double)PANGO_SCALE, pango_layout_iter_get_baseline(it)/(double)PANGO_SCALE);
        pango_cairo_show_layout_line(cr, line);
    } while (pango_layout_iter_next_line(it));
    pango_layout_iter_free(it);
    cairo_status_t status = cairo_status(cr);
    cairo_destroy(cr); cairo_surface_flush(t->surface);
    if (status != CAIRO_STATUS_SUCCESS) { zc_text_clear_pixels(t); return NULL; }
    unsigned char *pixels = cairo_image_surface_get_data(t->surface);
    // Cairo is premultiplied native ARGB; raylib expects straight RGBA.
    for (int y=0; y<height; ++y) for (int x=0; x<t->width; ++x) {
        unsigned char *p = pixels+y*cairo_image_surface_get_stride(t->surface)+x*4;
        unsigned b=p[0], g=p[1], r=p[2], a=p[3];
        p[0]=a ? (unsigned char)(r*255/a) : 0; p[1]=a ? (unsigned char)(g*255/a) : 0; p[2]=a ? (unsigned char)(b*255/a) : 0;
    }
    return pixels;
}
void zc_text_caret(ZcText *t, int index, int *x, int *y, int *height) {
    const char *text = pango_layout_get_text(t->layout);
    index = CLAMP(index, 0, (int)strlen(text));
    while (index > 0 && ((unsigned char)text[index] & 0xc0) == 0x80) --index;
    PangoRectangle r; pango_layout_get_cursor_pos(t->layout,index,&r,NULL);
    *x=r.x/PANGO_SCALE; *y=r.y/PANGO_SCALE; *height=r.height/PANGO_SCALE;
}
int zc_text_hit(ZcText *t, int x, int y) {
    int index, trailing;
    pango_layout_xy_to_index(t->layout,(int)CLAMP((int64_t)x*PANGO_SCALE,INT_MIN,INT_MAX),(int)CLAMP((int64_t)y*PANGO_SCALE,INT_MIN,INT_MAX),&index,&trailing);
    const char *text = pango_layout_get_text(t->layout); const char *p = text+index;
    while (trailing-- > 0 && *p) p=g_utf8_next_char(p);
    return (int)(p-text);
}
size_t zc_text_boundary(const char *text, size_t length, size_t position, int direction) {
    if (!g_utf8_validate(text, (gssize)length, NULL)) return position;
    glong count=g_utf8_strlen(text,(gssize)length); PangoLogAttr *attrs=g_new0(PangoLogAttr,count+1);
    pango_get_log_attrs(text,(int)length,-1,pango_language_get_default(),attrs,(int)count+1);
    const char *p=text; size_t prev=0, result=length;
    for (glong i=0;i<=count;i++) {
        size_t at=(size_t)(p-text);
        if (attrs[i].is_cursor_position) {
            if (direction<0 && at>=position) { result=prev; break; }
            if (direction>0 && at>position) { result=at; break; }
            prev=at;
        }
        if (i<count) p=g_utf8_next_char(p);
    }
    g_free(attrs); return result;
}

int zc_local_time(const char *timestamp, char *output, size_t size, int compact) {
    struct tm tm = {0};
    if (sscanf(timestamp, "%d-%d-%dT%d:%d:%d", &tm.tm_year, &tm.tm_mon, &tm.tm_mday, &tm.tm_hour, &tm.tm_min, &tm.tm_sec) != 6) return 0;
    tm.tm_year -= 1900; tm.tm_mon -= 1;
    time_t when = timegm(&tm); struct tm local;
    if (!localtime_r(&when, &local)) return 0;
    return (int)strftime(output, size, compact ? "%b %d" : "%b %d · %H:%M", &local);
}
