#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct ZcNet ZcNet;
typedef int (*ZcStreamFn)(void *, const char *, size_t);
ZcNet *zc_net_new(const char *token, unsigned port, ZcStreamFn fn, void *context);
void zc_net_free(ZcNet *net);
int zc_net_start(ZcNet *net, int stream, const char *path, const char *body);
void zc_net_cancel_stream(ZcNet *net);
void zc_net_cancel_request(ZcNet *net);
int zc_net_wait(ZcNet *net, int wake_fd, int timeout_ms);
int zc_net_poll(ZcNet *net);
int zc_net_done(ZcNet *net, int stream);
long zc_net_status(ZcNet *net, int stream);
const char *zc_net_body(ZcNet *net, size_t *length);
void zc_net_ack(ZcNet *net, int stream);
typedef struct ZcText ZcText;
ZcText *zc_text_new(const char *text, int length, double size, int width, double scale);
void zc_text_free(ZcText *text);
int zc_text_width(ZcText *text);
int zc_text_height(ZcText *text);
unsigned char *zc_text_pixels(ZcText *text, unsigned color, int start, int end, int top, int height);
void zc_text_clear_pixels(ZcText *text);
int zc_local_time(const char *timestamp, char *output, size_t size, int compact);
void zc_text_caret(ZcText *text, int index, int *x, int *y, int *height);
int zc_text_hit(ZcText *text, int x, int y);
size_t zc_text_boundary(const char *text, size_t length, size_t position, int direction);
