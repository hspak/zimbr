#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct ZrTlsContext ZrTlsContext;
typedef struct ZrTls ZrTls;
/* Paths must be absolute, owner-only files in owner-only directories. */
int zr_tls_read_file(const char *path, char *out, size_t capacity);
/* Like read_file, with -2 only for an absent leaf in a validated private directory. */
int zr_tls_read_config(const char *path, char *out, size_t capacity);
/* Optimistic replacement: expected == NULL requires an absent destination.
 * 0: saved; 1: saved but directory sync failed; -2: changed; -1: unsafe/I/O error. */
int zr_tls_replace_config(const char *path, const char *expected, size_t expected_length,
    const char *bytes, size_t length);
ZrTlsContext *zr_tls_context(const char *cert, const char *key, const char *ca,
    const char *name, const unsigned char *fingerprints, size_t count, char *error, size_t capacity);
void zr_tls_context_free(ZrTlsContext *ctx);
int zr_tls_info(ZrTlsContext *ctx, char *fingerprint, size_t capacity, int64_t *expires, int64_t *ca_expires);
ZrTls *zr_tls_accept(ZrTlsContext *ctx, int fd);
int zr_tls_valid(ZrTls *tls);
int zr_tls_closed(ZrTls *tls);
ptrdiff_t zr_tls_read(ZrTls *tls, void *bytes, size_t length, int64_t deadline);
int zr_tls_write(ZrTls *tls, const void *bytes, size_t length);
int zr_tls_write_deadline(ZrTls *tls, const void *bytes, size_t length, int64_t deadline);
void zr_tls_free(ZrTls *tls);

const char *zr_tls_version(void);
