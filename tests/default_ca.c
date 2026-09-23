/* Test-only backend-default trust lookup injection. LD_PRELOAD loads this into
 * both an unisolated curl control and the production worker. No host trust
 * files are changed. The worker must discard this SSL_CTX lookup method. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <openssl/ssl.h>
#include <stdlib.h>

static SSL_CTX *with_default(SSL_CTX *ctx) {
    const char *path = getenv("ZIMBR_TEST_DEFAULT_CA_DIR");
    if (ctx && path && !X509_STORE_load_path(SSL_CTX_get_cert_store(ctx), path)) abort();
    return ctx;
}
SSL_CTX *SSL_CTX_new(const SSL_METHOD *method) {
    SSL_CTX *(*real)(const SSL_METHOD *) = dlsym(RTLD_NEXT, "SSL_CTX_new");
    return with_default(real(method));
}
SSL_CTX *SSL_CTX_new_ex(OSSL_LIB_CTX *libctx, const char *propq, const SSL_METHOD *method) {
    SSL_CTX *(*real)(OSSL_LIB_CTX *, const char *, const SSL_METHOD *) = dlsym(RTLD_NEXT, "SSL_CTX_new_ex");
    return with_default(real(libctx, propq, method));
}
