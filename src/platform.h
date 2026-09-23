#include <sqlite3.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <fcntl.h>
#include <time.h>
int zr_random(void *bytes, size_t length);
int64_t zr_now_ms(void);
int zr_timestamp(int64_t apple_ns, char *out, size_t capacity);
int zr_spawn(const char *script, const char *mode, const char *route, const char *text, int timeout_ms);
int zr_file_identity(const char *path, char *out, size_t capacity);
int zr_secure_file(const char *path, const void *data, size_t length, int replace);
int zr_read_secret(const char *path, char *out, size_t capacity);
void zr_socket_timeout(int fd);

int zr_lock(const char *path);

int64_t zr_monotonic_ms(void);
typedef struct ZrWatch ZrWatch;
ZrWatch *zr_watch_open(const char *path);
int zr_watch_wait(ZrWatch *watch, int timeout_ms);
void zr_watch_close(ZrWatch *watch);
