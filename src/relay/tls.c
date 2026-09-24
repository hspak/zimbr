#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "tls.h"
#include "platform.h"
#include <openssl/ssl.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <openssl/err.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <string.h>

#if OPENSSL_VERSION_MAJOR != 3 || OPENSSL_VERSION_MINOR != 5
#error "The relay requires OpenSSL 3.5 LTS (use -Dopenssl-prefix for the target)."
#endif
struct ZrTlsContext { SSL_CTX *ssl; unsigned char fingerprints[256][32]; size_t count; X509 *ca; };
struct ZrTls { SSL *ssl; X509 *peer; int fd; };

/* Walk with openat/O_NOFOLLOW so neither leaf nor ancestor symlinks can change
 * the object being validated. Only the immediate containing directory must be
 * private; system ancestors (e.g. /Users) need not be owner-only. */
static int private_open(const char *path) {
    if (!path || path[0] != '/' || strlen(path) >= PATH_MAX) return -1;
    char copy[PATH_MAX]; strcpy(copy, path + 1);
    int dir = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dir < 0) return -1;
    char *part = copy;
    for (;;) {
        char *slash = strchr(part, '/');
        if (slash) *slash = 0;
        if (!*part || !strcmp(part, ".") || !strcmp(part, "..")) { close(dir); return -1; }
        if (!slash) break;
        int next = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(dir); dir = next;
        if (dir < 0) return -1;
        struct stat ancestor;
        if (fstat(dir, &ancestor) || (ancestor.st_uid != 0 && ancestor.st_uid != getuid()) ||
            ((ancestor.st_mode & 022) && !(ancestor.st_uid == 0 && (ancestor.st_mode & S_ISVTX)))) {
            close(dir); return -1;
        }
        part = slash + 1;
    }
    struct stat s;
    if (fstat(dir, &s) || s.st_uid != getuid() || (s.st_mode & 077) || (s.st_mode & 0700) != 0700) { close(dir); return -1; }
    int fd = openat(dir, part, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    close(dir);
    if (fd < 0) return -1;
    if (fstat(fd, &s) || !S_ISREG(s.st_mode) || s.st_uid != getuid() || (s.st_mode & 077) || s.st_nlink != 1 || s.st_size > 65536) { close(fd); return -1; }
    return fd;
}
int zr_tls_read_file(const char *path, char *out, size_t cap) {
    int fd = private_open(path);
    if (fd < 0) return -1;
    size_t used = 0;
    while (used < cap) {
        ssize_t n = read(fd, out + used, cap - used);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { close(fd); return -1; }
        if (!n) { close(fd); return used < cap ? (int)used : -1; }
        used += (size_t)n;
    }
    close(fd); return -1;
}
static BIO *private_bio(const char *path, const char *kind) {
    char bytes[65536];
    int n = zr_tls_read_file(path, bytes, sizeof(bytes));
    if (n <= 0) return NULL;
    char begin[80], end[80];
    snprintf(begin, sizeof(begin), "-----BEGIN %s-----", kind);
    snprintf(end, sizeof(end), "-----END %s-----", kind);
    bytes[n] = 0;
    if (strncmp(bytes, begin, strlen(begin))) return NULL;
    char *tail = strstr(bytes, end);
    if (!tail) return NULL;
    tail += strlen(end);
    while (*tail == ' ' || *tail == '\r' || *tail == '\n' || *tail == '\t') ++tail;
    if (tail != bytes + n) return NULL; /* Reject bundles and accidentally included issuer keys. */
    BIO *bio = BIO_new(BIO_s_mem());
    if (!bio || BIO_write(bio, bytes, n) != n) { BIO_free(bio); bio = NULL; }
    OPENSSL_cleanse(bytes, sizeof(bytes));
    return bio;
}
static int no_password(char *buf, int size, int rw, void *arg) {
    (void)buf; (void)size; (void)rw; (void)arg; return 0;
}
static int valid_time(X509 *cert) {
    return cert && X509_cmp_current_time(X509_get0_notBefore(cert)) < 0 && X509_cmp_current_time(X509_get0_notAfter(cert)) > 0;
}
static int leaf_purpose(X509 *cert, int nid) {
    if (!cert || X509_check_ca(cert)) return 0;
    EXTENDED_KEY_USAGE *eku = X509_get_ext_d2i(cert, NID_ext_key_usage, NULL, NULL);
    int ok = 0;
    if (eku) {
        for (int i = 0; i < sk_ASN1_OBJECT_num(eku); ++i) if (OBJ_obj2nid(sk_ASN1_OBJECT_value(eku, i)) == nid) ok = 1;
        EXTENDED_KEY_USAGE_free(eku);
    }
    return ok;
}
static int enrolled(ZrTlsContext *ctx, X509 *cert) {
    unsigned char digest[32]; unsigned int length = 0;
    if (!X509_digest(cert, EVP_sha256(), digest, &length) || length != 32) return 0;
    for (size_t i = 0; i < ctx->count; ++i) if (CRYPTO_memcmp(digest, ctx->fingerprints[i], 32) == 0) return 1;
    return 0;
}
static int verify_peer(int verified, X509_STORE_CTX *store) {
    if (!verified) return 0; /* Never override OpenSSL chain/purpose/time failure. */
    if (X509_STORE_CTX_get_error_depth(store) != 0) return 1;
    SSL *ssl = X509_STORE_CTX_get_ex_data(store, SSL_get_ex_data_X509_STORE_CTX_idx());
    ZrTlsContext *ctx = SSL_CTX_get_app_data(SSL_get_SSL_CTX(ssl));
    X509 *cert = X509_STORE_CTX_get_current_cert(store);
    if (!leaf_purpose(cert, NID_client_auth) || !valid_time(cert) || !enrolled(ctx, cert)) {
        X509_STORE_CTX_set_error(store, X509_V_ERR_APPLICATION_VERIFICATION); return 0;
    }
    return 1;
}
static int alpn(SSL *ssl, const unsigned char **out, unsigned char *outlen,
                const unsigned char *in, unsigned int len, void *arg) {
    (void)ssl; (void)arg;
    static const unsigned char http[] = "\x08http/1.1";
    if (SSL_select_next_proto((unsigned char **)out, outlen, http, sizeof(http)-1, in, len) != OPENSSL_NPN_NEGOTIATED)
        return SSL_TLSEXT_ERR_ALERT_FATAL;
    return SSL_TLSEXT_ERR_OK;
}
ZrTlsContext *zr_tls_context(const char *cert_path, const char *key_path, const char *ca_path,
                           const char *name, const unsigned char *fingerprints, size_t count, char *error, size_t capacity) {
    const char *reason = "Cannot allocate TLS context";
    ZrTlsContext *ctx = calloc(1, sizeof(*ctx));
    BIO *bio = NULL; X509 *cert = NULL; EVP_PKEY *key = NULL; X509_STORE_CTX *check = NULL;
    if (!ctx) goto fail;
    if (count > 256) { reason = "At most 256 enabled devices are allowed"; goto fail; }
    ctx->count = count;
    if (count) memcpy(ctx->fingerprints, fingerprints, count * 32);
    ctx->ssl = SSL_CTX_new(TLS_server_method());
    if (!ctx->ssl) goto fail;
    reason = "TLS 1.3 policy unavailable";
    if (!SSL_CTX_set_min_proto_version(ctx->ssl, TLS1_3_VERSION) || !SSL_CTX_set_max_proto_version(ctx->ssl, TLS1_3_VERSION) ||
        !SSL_CTX_set_num_tickets(ctx->ssl, 0) || !SSL_CTX_set_max_early_data(ctx->ssl, 0)) goto fail;
    SSL_CTX_set_session_cache_mode(ctx->ssl, SSL_SESS_CACHE_OFF);
    SSL_CTX_set_options(ctx->ssl, SSL_OP_NO_TICKET | SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION);
    SSL_CTX_set_verify(ctx->ssl, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, verify_peer);
    SSL_CTX_set_verify_depth(ctx->ssl, 2);
    SSL_CTX_set_app_data(ctx->ssl, ctx);
    SSL_CTX_set_alpn_select_cb(ctx->ssl, alpn, NULL);
    reason = "Server certificate missing, unsafe, or invalid PEM (require owner-only file and directory, no symlinks)";
    bio = private_bio(cert_path, "CERTIFICATE"); if (!bio) goto fail;
    cert = PEM_read_bio_X509(bio, NULL, NULL, NULL); BIO_free(bio); bio = NULL;
    if (!cert || !SSL_CTX_use_certificate(ctx->ssl, cert)) goto fail;
    reason = "Server private key missing, unsafe, encrypted, or invalid unencrypted PKCS#8 PEM";
    bio = private_bio(key_path, "PRIVATE KEY"); if (!bio) goto fail;
    key = PEM_read_bio_PrivateKey(bio, NULL, no_password, NULL); BIO_free(bio); bio = NULL;
    if (!key) goto fail;
    reason = "Server certificate/private key mismatch";
    if (!SSL_CTX_use_PrivateKey(ctx->ssl, key) || !SSL_CTX_check_private_key(ctx->ssl)) goto fail;
    reason = "Client CA missing, unsafe, expired, or invalid (require a dedicated CA certificate)";
    bio = private_bio(ca_path, "CERTIFICATE"); if (!bio) goto fail;
    ctx->ca = PEM_read_bio_X509(bio, NULL, NULL, NULL); BIO_free(bio); bio = NULL;
    if (!ctx->ca || !X509_check_ca(ctx->ca) || !valid_time(ctx->ca)) goto fail;
    /* Fresh store: no system roots, default directories, or environment fallback. */
    if (!X509_STORE_add_cert(SSL_CTX_get_cert_store(ctx->ssl), ctx->ca)) goto fail;
    reason = "Server certificate must be a currently valid serverAuth leaf signed by the configured CA";
    if (!valid_time(cert) || !leaf_purpose(cert, NID_server_auth)) goto fail;
    check = X509_STORE_CTX_new();
    if (!check || !X509_STORE_CTX_init(check, SSL_CTX_get_cert_store(ctx->ssl), cert, NULL) ||
        !X509_STORE_CTX_set_purpose(check, X509_PURPOSE_SSL_SERVER) || X509_verify_cert(check) != 1) goto fail;
    reason = "Server certificate SAN does not match server_name";
    if (!name || !*name || (X509_check_ip_asc(cert, name, 0) != 1 &&
        X509_check_host(cert, name, 0, X509_CHECK_FLAG_NEVER_CHECK_SUBJECT | X509_CHECK_FLAG_NO_WILDCARDS, NULL) != 1)) goto fail;
    X509_STORE_CTX_free(check); X509_free(cert); EVP_PKEY_free(key); ERR_clear_error();
    /* OpenSSL's socket BIO can raise SIGPIPE on Linux. */
    signal(SIGPIPE, SIG_IGN);
    return ctx;
fail:
    if (error && capacity) snprintf(error, capacity, "%s", reason);
    BIO_free(bio); X509_free(cert); EVP_PKEY_free(key); X509_STORE_CTX_free(check);
    zr_tls_context_free(ctx); ERR_clear_error(); return NULL;
}
void zr_tls_context_free(ZrTlsContext *ctx) {
    if (ctx) { SSL_CTX_free(ctx->ssl); X509_free(ctx->ca); free(ctx); }
}
static int64_t expiry(X509 *cert) {
    int days = 0, seconds = 0;
    if (!ASN1_TIME_diff(&days, &seconds, NULL, X509_get0_notAfter(cert))) return 0;
    return (int64_t)time(NULL) + (int64_t)days * 86400 + seconds;
}
int zr_tls_info(ZrTlsContext *ctx, char *fingerprint, size_t capacity, int64_t *expires, int64_t *ca_expires) {
    unsigned char digest[32]; unsigned int length;
    X509 *cert = SSL_CTX_get0_certificate(ctx->ssl);
    if (capacity < 65 || !X509_digest(cert, EVP_sha256(), digest, &length) || length != 32) return -1;
    for (size_t i = 0; i < 32; ++i) snprintf(fingerprint + i*2, 3, "%02x", digest[i]);
    *expires = expiry(cert); *ca_expires = expiry(ctx->ca); return 0;
}
static int wait_for(ZrTls *tls, int error, int64_t deadline) {
    short events;
    if (error == SSL_ERROR_WANT_READ) events = POLLIN;
    else if (error == SSL_ERROR_WANT_WRITE) events = POLLOUT;
    else return -1;
    for (;;) {
        int64_t left = deadline - zr_monotonic_ms();
        if (left <= 0) return -1;
        struct pollfd p = { .fd = tls->fd, .events = events };
        int rc = poll(&p, 1, (int)(left > 10000 ? 10000 : left));
        if (rc < 0 && errno == EINTR) continue;
        return rc > 0 && !(p.revents & POLLNVAL) ? 0 : -1;
    }
}
ZrTls *zr_tls_accept(ZrTlsContext *ctx, int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK)) return NULL;
    zr_socket_timeout(fd);
    ZrTls *tls = calloc(1, sizeof(*tls));
    if (!tls) return NULL;
    tls->fd = fd; tls->ssl = SSL_new(ctx->ssl);
    if (!tls->ssl || !SSL_set_fd(tls->ssl, fd)) goto fail;
    int64_t deadline = zr_monotonic_ms() + 5000;
    for (;;) {
        ERR_clear_error(); int rc = SSL_accept(tls->ssl);
        if (rc == 1) break;
        if (wait_for(tls, SSL_get_error(tls->ssl, rc), deadline)) goto fail;
    }
    tls->peer = SSL_get1_peer_certificate(tls->ssl);
    if (SSL_get_verify_result(tls->ssl) != X509_V_OK || !zr_tls_valid(tls) || !enrolled(ctx, tls->peer)) goto fail;
    return tls;
fail:
    X509_free(tls->peer); SSL_free(tls->ssl); free(tls); ERR_clear_error(); return NULL;
}
int zr_tls_valid(ZrTls *tls) {
    ZrTlsContext *ctx = SSL_CTX_get_app_data(SSL_get_SSL_CTX(tls->ssl));
    return valid_time(tls->peer) && valid_time(ctx->ca) && valid_time(SSL_get_certificate(tls->ssl));
}
ptrdiff_t zr_tls_read(ZrTls *tls, void *bytes, size_t length, int64_t deadline) {
    for (;;) {
        if (zr_monotonic_ms() >= deadline) return -1;
        size_t n = 0; ERR_clear_error(); int rc = SSL_read_ex(tls->ssl, bytes, length, &n);
        if (rc == 1) return (ptrdiff_t)n;
        int error = SSL_get_error(tls->ssl, rc);
        if (error == SSL_ERROR_ZERO_RETURN) return 0;
        if (wait_for(tls, error, deadline)) return -1;
    }
}
int zr_tls_write(ZrTls *tls, const void *bytes, size_t length) {
    return zr_tls_write_deadline(tls, bytes, length, zr_monotonic_ms() + 10000);
}
int zr_tls_write_deadline(ZrTls *tls, const void *bytes, size_t length, int64_t deadline) {
    size_t offset = 0;
    while (offset < length) {
        if (zr_monotonic_ms() >= deadline || !zr_tls_valid(tls)) return -1;
        size_t n = 0; ERR_clear_error(); int rc = SSL_write_ex(tls->ssl, (const char *)bytes + offset, length - offset, &n);
        if (rc == 1) { offset += n; continue; }
        if (wait_for(tls, SSL_get_error(tls->ssl, rc), deadline)) return -1;
    }
    return 0;
}
int zr_tls_closed(ZrTls *tls) {
    char byte; size_t n; ERR_clear_error(); int rc = SSL_peek_ex(tls->ssl, &byte, 1, &n);
    if (rc == 1) return 1; /* No inbound application data is valid after an SSE request. */
    int error = SSL_get_error(tls->ssl, rc);
    return error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE;
}
void zr_tls_free(ZrTls *tls) {
    if (!tls) return;
    int64_t deadline = zr_monotonic_ms() + 200;
    for (;;) {
        ERR_clear_error(); int rc = SSL_shutdown(tls->ssl);
        if (rc >= 0 || wait_for(tls, SSL_get_error(tls->ssl, rc), deadline)) break;
    }
    X509_free(tls->peer); SSL_free(tls->ssl); free(tls);
}

const char *zr_tls_version(void) { return OpenSSL_version(OPENSSL_VERSION); }
