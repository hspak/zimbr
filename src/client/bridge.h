#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct ZcNotifications ZcNotifications;
typedef struct { unsigned char *data; int width, height; size_t bytes; } ZcPixels;
typedef void (*ZcNotificationAction)(void *, const char *chat, const char *activation_token);
ZcNotifications *zc_notifications_new(ZcNotificationAction action, void *context);
void zc_notifications_poll(void);
/* -1 while capabilities are unknown, 0 if unsupported, 1 if supported. */
int zc_notifications_images(ZcNotifications *);
/* Copies content and optional RGBA pixels before returning. */
void zc_notifications_show(ZcNotifications *, const char *chat, const char *summary, const char *body, const ZcPixels *image);
void zc_notifications_dismiss(ZcNotifications *, const char *chat);
void zc_notifications_free(ZcNotifications *);
typedef struct ZcNet ZcNet;
/* Complete request URL capacity, including the null terminator. */
// 8 KiB leaves room for the configured origin, endpoint, and escaped pagination tokens.
#define ZC_REQUEST_URL_CAPACITY 8192
typedef int (*ZcStreamFn)(void *, const char *, size_t);
enum ZcFailure { ZC_OK, ZC_NETWORK, ZC_SERVER_TRUST, ZC_CREDENTIALS, ZC_CLIENT_REJECTED, ZC_TLS, ZC_HTTP, ZC_CONFIG };
// 256 bytes bounds copied diagnostics across the Zig/C boundary.
typedef struct { int kind, curl_code; long verify_result; char message[256]; } ZcError;
// SHA-256 needs 64 hex digits plus NUL; 32 bytes covers the UTC expiry string.
typedef struct { char fingerprint[65], expires[32]; int64_t expires_at; } ZcIdentity;
/* Secure descriptor-based read. 1 = success, 0 = absent, -1 = unsafe/error. */
int zc_private_read(const char *path, char **data, size_t *length);
void zc_private_free(char *data, size_t length);
int zc_origin_valid(const char *origin);
ZcNet *zc_net_new(const char *origin, const char *ca, const char *cert, const char *key,
                  ZcStreamFn fn, void *context, ZcError *error, ZcIdentity *identity);
void zc_net_free(ZcNet *net);
/* Copies path and body before returning. A null body starts a GET. */
int zc_net_start(ZcNet *net, int stream, const char *path, const char *body, size_t body_length);
void zc_net_cancel_stream(ZcNet *net);
void zc_net_cancel_request(ZcNet *net);
int zc_net_wait(ZcNet *net, int wake_fd, int timeout_ms);
int zc_net_poll(ZcNet *net);
int zc_net_done(ZcNet *net, int stream);
long zc_net_status(ZcNet *net, int stream);
void zc_net_error(ZcNet *net, int stream, ZcError *error);
const char *zc_net_extensions(ZcNet *net);
int zc_url_host(const char *url, char *host, size_t size);
int zc_url_open(const char *url);
/* Transfers the completed response allocation to the caller; release with free().
   The returned bytes remain valid after ack and subsequent requests. */
char *zc_net_take_body(ZcNet *net, size_t *length);
char *zc_net_take_slot_body(ZcNet *net, int slot, size_t *length);
void zc_net_ack(ZcNet *net, int stream);
/* Slot 4 is an independent outgoing lane. Borrow fd until ack/cancellation.
   Read at most 64 KiB per callback; no whole-file allocation or seek retries. */
int zc_net_upload(ZcNet *, const char *path, const char *epoch, int fd, uint64_t length);
uint64_t zc_net_upload_progress(ZcNet *);
/* Two binary lanes (status/done/ack use slot lane+2). Caller owns the fd. */
int zc_net_start_file(ZcNet *, int lane, const char *path, int fd, size_t expected);
const char *zc_net_media_body(ZcNet *, int lane, size_t *length);
int zc_cache_open(const char *path);
int zc_cache_temp(int dir, char *name, size_t size);
int zc_cache_install(int dir, const char *temporary, const char *key, int fd);
void zc_cache_remove(int dir, const char *name);
typedef struct { size_t bytes, entries; } ZcCacheUsage;
/* Remove orphan temporaries only at startup, before this owner starts downloads.
   Returns 0 if scanning or eviction failed; usage is then not authoritative. */
int zc_cache_prune(int dir, size_t budget, size_t max_entries, int startup, ZcCacheUsage *usage);
void zc_cache_clear_avatars(int dir);
int zc_image_read(int dir, const char *name, ZcPixels *pixels);
/* Borrow a private original descriptor without changing its offset or timestamps. */
int zc_image_read_fd(int fd, ZcPixels *pixels);
void zc_pixels_free(ZcPixels *pixels);
typedef struct ZcText ZcText;
ZcText *zc_text_new(const char *text, int length, double size, int width, double scale);
ZcText *zc_text_new_with_options(const char *text, int length, double size, int width, double scale, int single_line, int subpixel);
/* Pango weights range from 100 to 1000; 400 is normal and 600 is semibold. */
ZcText *zc_text_new_weighted(const char *text, int length, double size, int width, double scale, int single_line, int subpixel, int weight);
void zc_text_free(ZcText *text);
int zc_text_width(ZcText *text);
int zc_text_height(ZcText *text);
double zc_text_baseline(ZcText *text);
double zc_text_ink_center_x(ZcText *text);
double zc_text_ink_center_y(ZcText *text);
// Raster bytes are borrowed native-endian premultiplied ARGB32 until clear/free/next raster.
// Use zc_text_pitch for the row stride; color arguments remain packed RGBA.
int zc_text_pitch(ZcText *text);
unsigned char *zc_text_pixels(ZcText *text, unsigned color, int start, int end, int top, int height);
unsigned char *zc_text_pixels_on(ZcText *text, unsigned color, int start, int end, int top, int height, unsigned background);
// Colors are packed RGBA; zero selection keeps the default highlight.
unsigned char *zc_text_pixels_with_selection(ZcText *text, unsigned color, int start, int end, int top, int height, unsigned background, unsigned selection);
void zc_text_clear_pixels(ZcText *text);
int zc_local_time(const char *timestamp, char *output, size_t size, int compact);
int zc_timestamp_ms(const char *timestamp, size_t length, int64_t *output);
void zc_text_caret(ZcText *text, int index, int *x, int *y, int *height);
// Visit visual rectangles for a UTF-8 byte range, in logical layout coordinates.
void zc_text_ranges(ZcText *text, int start, int end, void (*visit)(void *, double, double, double, double), void *user);
int zc_text_hit(ZcText *text, int x, int y);
// Returns UTF-8 byte bounds for the word, whitespace run, or grapheme under the pointer.
void zc_text_word_hit(ZcText *text, int x, int y, int *start, int *end);
size_t zc_text_boundary(const char *text, size_t length, size_t position, int direction);
