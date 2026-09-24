#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "bridge.h"
#include <curl/curl.h>
#include <openssl/ssl.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <pango/pangocairo.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <math.h>
#include <limits.h>
#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>
#include <gio/gio.h>

_Static_assert(CURL_ERROR_SIZE <= sizeof(((ZcError *)0)->message), "Diagnostic buffer must hold curl errors");

struct Slot {
    CURL *easy; char *body; size_t len; long status; int done, stream, alert;
    int64_t last_rx; struct ZcNet *owner; ZcError error;
    char extensions[128], mime[64];
    int media, fd, extension_seen; size_t expected;
};
struct ZcNet {
    CURLM *multi; struct curl_slist *headers; struct Slot slots[4];
    char *origin, *ca, *cert, *key; size_t ca_len, cert_len, key_len;
    X509 *root; ZcStreamFn fn; void *context;
};
static void failure(ZcError *e, int kind, const char *message) {
    e->kind=kind; snprintf(e->message,sizeof(e->message),"%s",message);
}

/* Never follow symlinks, including directory components. Only the immediate
 * containing directory needs to be private; ancestors must be trusted and not
 * writable by others (the root-owned sticky /tmp exception permits fixtures). */
int zc_private_read(const char *path, char **data, size_t *length) {
    *data=NULL; *length=0;
    if (!path || path[0]!='/' || strlen(path)>=PATH_MAX) return -1;
    char copy[PATH_MAX]; strcpy(copy,path+1);
    int dir=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC), fd=-1, result=-1;
    if (dir<0) return -1;
    char *part=copy;
    for (;;) {
        char *slash=strchr(part,'/'); if (slash) *slash=0;
        if (!*part || !strcmp(part,".") || !strcmp(part,"..")) goto end;
        struct stat st;
        if (fstat(dir,&st)) goto end;
        if (slash) {
            if ((st.st_uid!=0 && st.st_uid!=getuid()) ||
                ((st.st_mode&0022) && !(st.st_uid==0 && (st.st_mode&S_ISVTX)))) goto end;
            int next=openat(dir,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if (next<0) { if (errno==ENOENT) result=0; goto end; }
            close(dir); dir=next; part=slash+1; continue;
        }
        if (st.st_uid!=getuid() || (st.st_mode&0777)!=0700) goto end;
        fd=openat(dir,part,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
        if (fd<0) { if (errno==ENOENT) result=0; goto end; }
        if (fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_uid!=getuid() ||
            (st.st_mode&0777)!=0600 || st.st_nlink!=1 || st.st_size<1 || st.st_size>1024*1024) goto end;
        *length=(size_t)st.st_size;
        *data=calloc(1,*length+1); if (!*data) goto end;
        size_t used=0;
        while (used<*length) {
            ssize_t n=read(fd,*data+used,*length-used);
            if (n<0 && errno==EINTR) continue;
            if (n<=0) goto end;
            used+=(size_t)n;
        }
        char extra;
        if (read(fd,&extra,1)!=0 || memchr(*data,0,*length)) goto end;
        result=1; break;
    }
end:
    if (fd>=0) close(fd);
    close(dir);
    if (result!=1) { zc_private_free(*data,*length); *data=NULL; *length=0; }
    return result;
}
void zc_private_free(char *data, size_t length) {
    if (data) { OPENSSL_cleanse(data,length); free(data); }
}
int zc_origin_valid(const char *origin) {
    if (!origin || strncmp(origin,"https://",8) || strlen(origin)>4096) return 0;
    for (const unsigned char *p=(const unsigned char *)origin; *p; p++)
        if (*p<=32 || *p>=127 || strchr("@?#%\\",*p)) return 0;
    const char *authority=origin+8, *slash=strchr(authority,'/');
    if (!*authority || (slash && slash[1]) || authority==(slash ? slash : origin)) return 0;
    size_t len=slash ? (size_t)(slash-authority) : strlen(authority);
    if (!len || authority[len-1]==':') return 0;
    CURLU *url=curl_url(); if (!url) return 0;
    char *host=NULL, *port=NULL;
    int ok=curl_url_set(url,CURLUPART_URL,origin,0)==CURLUE_OK &&
           curl_url_get(url,CURLUPART_HOST,&host,0)==CURLUE_OK && host && *host;
    if (ok && host[0]!='[') {
        size_t label=0, total=strlen(host);
        if (total>253 || host[0]=='.' || host[0]=='-') ok=0;
        for (size_t i=0;ok && i<total;i++) {
            unsigned char ch=(unsigned char)host[i];
            if (ch=='.') {
                if (!label || host[i-1]=='-') ok=0;
                label=0;
            } else {
                if (!((ch>='a' && ch<='z') || (ch>='A' && ch<='Z') ||
                      (ch>='0' && ch<='9') || ch=='-') || (!label && ch=='-') || ++label>63) ok=0;
            }
        }
        if (host[total-1]=='-') ok=0;
    }
    if (ok && curl_url_get(url,CURLUPART_PORT,&port,0)==CURLUE_OK) {
        char *end=NULL; long number=strtol(port,&end,10);
        ok=*port && !*end && number>0 && number<=65535;
    }
    curl_free(host); curl_free(port); curl_url_cleanup(url); return ok;
}
static int no_password(char *buf, int size, int rwflag, void *context) {
    (void)buf; (void)size; (void)rwflag; (void)context; return 0;
}
static X509 *certificate(const char *pem, size_t len) {
    BIO *bio=BIO_new_mem_buf(pem,(int)len); if (!bio) return NULL;
    X509 *cert=PEM_read_bio_X509(bio,NULL,NULL,NULL); BIO_free(bio); return cert;
}
static int credentials(ZcNet *n, ZcError *e, ZcIdentity *identity) {
    n->root=certificate(n->ca,n->ca_len);
    X509 *cert=certificate(n->cert,n->cert_len);
    BIO *bio=BIO_new_mem_buf(n->key,(int)n->key_len);
    EVP_PKEY *key=bio ? PEM_read_bio_PrivateKey(bio,NULL,no_password,NULL) : NULL;
    BIO_free(bio);
    int ok=0;
    X509_STORE *store=X509_STORE_new(); X509_STORE_CTX *ctx=X509_STORE_CTX_new();
    if (!n->root || !cert || !key || !store || !ctx) {
        failure(e,ZC_CREDENTIALS,"Cannot read PEM CA/certificate or unencrypted private key. Repair the credential files, then Reconnect."); goto end;
    }
    if (X509_check_ca(n->root)<=0 || X509_check_ca(cert)>0 ||
        (X509_get_ext_by_NID(cert,NID_ext_key_usage,-1)<0 || !(X509_get_extended_key_usage(cert)&XKU_SSL_CLIENT)) ||
        X509_check_private_key(cert,key)!=1) {
        failure(e,ZC_CREDENTIALS,"Expected a CA, a non-CA clientAuth certificate and its matching private key. Repair credentials, then Reconnect."); goto end;
    }
    if (!X509_STORE_add_cert(store,n->root) || !X509_STORE_CTX_init(ctx,store,cert,NULL) ||
        !X509_STORE_CTX_set_purpose(ctx,X509_PURPOSE_SSL_CLIENT) || X509_verify_cert(ctx)!=1) {
        e->verify_result=X509_STORE_CTX_get_error(ctx);
        snprintf(e->message,sizeof(e->message),"Client credential verification failed: %s. Renew or repair credentials, then Reconnect.",X509_verify_cert_error_string(e->verify_result));
        e->kind=ZC_CREDENTIALS; goto end;
    }
    unsigned char digest[EVP_MAX_MD_SIZE]; unsigned length=0;
    struct tm expires={0};
    if (!X509_digest(cert,EVP_sha256(),digest,&length) || length!=32 ||
        !ASN1_TIME_to_tm(X509_get0_notAfter(cert),&expires)) {
        failure(e,ZC_CREDENTIALS,"Cannot inspect client certificate identity or expiry."); goto end;
    }
    for (unsigned i=0;i<32;i++) snprintf(identity->fingerprint+i*2,3,"%02x",digest[i]);
    strftime(identity->expires,sizeof(identity->expires),"%Y-%m-%dT%H:%M:%SZ",&expires);
    identity->expires_at=(int64_t)timegm(&expires); ok=1;
end:
    X509_STORE_CTX_free(ctx); X509_STORE_free(store); X509_free(cert); EVP_PKEY_free(key); return ok;
}
static int64_t monotonic_ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return (int64_t)ts.tv_sec*1000+ts.tv_nsec/1000000; }
static int progress(void *context, curl_off_t a, curl_off_t b, curl_off_t c, curl_off_t d) {
    (void)a; (void)b; (void)c; (void)d;
    struct Slot *s=context;
    return s->stream && monotonic_ms()-s->last_rx>45000;
}
static size_t receive(char *data, size_t size, size_t count, void *context) {
    struct Slot *s=context; size_t n=size*count; s->last_rx=monotonic_ms();
    if (s->media) {
        long status=0; curl_easy_getinfo(s->easy,CURLINFO_RESPONSE_CODE,&status);
        if (status==200) {
            if (n>8*1024*1024-s->len) return 0;
            size_t used=0;
            while (used<n) { ssize_t wrote=write(s->fd,data+used,n-used); if (wrote<0 && errno==EINTR) continue; if (wrote<=0) return 0; used+=(size_t)wrote; }
            s->len+=n; return n;
        }
        if (n>8192-s->len) return 0;
    }
    if (s->stream) {
        long status=0; curl_easy_getinfo(s->easy,CURLINFO_RESPONSE_CODE,&status);
        if (status!=200) return n;
        return s->owner->fn(s->owner->context,data,n) ? n : 0;
    }
    if (n>64*1024*1024-s->len) return 0;
    char *next=realloc(s->body,s->len+n+1); if (!next) return 0;
    s->body=next; memcpy(next+s->len,data,n); s->len+=n; next[s->len]=0; return n;
}
static size_t receive_header(char *data, size_t size, size_t count, void *context) {
    struct Slot *s=context; size_t n=size*count;
    if (n>=5 && !memcmp(data,"HTTP/",5)) { s->extensions[0]=0; s->mime[0]=0; s->extension_seen=0; }
    if (n>=13 && !strncasecmp(data,"content-type:",13)) {
        size_t begin=13,end=n;
        while (begin<end && (data[begin]==' ' || data[begin]=='\t')) begin++;
        while (end>begin && (data[end-1]=='\r' || data[end-1]=='\n' || data[end-1]==' ')) end--;
        if (end-begin>=sizeof(s->mime)) return 0;
        memcpy(s->mime,data+begin,end-begin); s->mime[end-begin]=0;
    }
    const char *name="zimbr-event-extensions:"; size_t len=strlen(name);
    if (n>=len && !strncasecmp(data,name,len)) {
        size_t end=n;
        while (len<end && (data[len]==' ' || data[len]=='\t')) len++;
        while (end>len && (data[end-1]=='\r' || data[end-1]=='\n' || data[end-1]==' ' || data[end-1]=='\t')) end--;
        if (end-len>=sizeof(s->extensions) || s->extension_seen) return 0;
        s->extension_seen=1;
        memcpy(s->extensions,data+len,end-len); s->extensions[end-len]=0;
    }
    return n;
}
static void tls_message(int write, int version, int type, const void *buf, size_t len, SSL *ssl, void *context) {
    (void)version; (void)ssl;
    struct Slot *s=context;
    if (!write && type==SSL3_RT_ALERT && len==2) s->alert=((const unsigned char *)buf)[1];
}
static CURLcode tls_context(CURL *easy, void *context, void *user) {
    (void)easy; SSL_CTX *ctx=context; struct Slot *s=user;
    /* Replace the entire store, including lookup methods. Clearing CAPATH and
     * native-root options alone is not the trust isolation boundary. */
    X509_STORE *store=X509_STORE_new();
    if (!store) return CURLE_OUT_OF_MEMORY;
    if (!X509_STORE_add_cert(store,s->owner->root)) { X509_STORE_free(store); return CURLE_SSL_CACERT_BADFILE; }
    SSL_CTX_set_cert_store(ctx,store);
    SSL_CTX_set_msg_callback(ctx,tls_message); SSL_CTX_set_msg_callback_arg(ctx,s);
    SSL_CTX_set_session_cache_mode(ctx,SSL_SESS_CACHE_OFF);
    return CURLE_OK;
}
static void clear_slot(ZcNet *n, int index) {
    struct Slot *s=&n->slots[index];
    if (s->easy) { curl_multi_remove_handle(n->multi,s->easy); curl_easy_cleanup(s->easy); }
    free(s->body); memset(s,0,sizeof(*s));
}
void zc_net_free(ZcNet *n) {
    if (!n) return;
    for (int i=0;i<4;i++) clear_slot(n,i);
    curl_slist_free_all(n->headers);
    if (n->multi) curl_multi_cleanup(n->multi);
    X509_free(n->root); free(n->origin);
    zc_private_free(n->ca,n->ca_len); zc_private_free(n->cert,n->cert_len); zc_private_free(n->key,n->key_len);
    free(n); curl_global_cleanup();
}
ZcNet *zc_net_new(const char *origin, const char *ca, const char *cert, const char *key,
                  ZcStreamFn fn, void *context, ZcError *error, ZcIdentity *identity) {
    memset(error,0,sizeof(*error)); memset(identity,0,sizeof(*identity));
    if (curl_global_init(CURL_GLOBAL_DEFAULT)) { failure(error,ZC_CONFIG,"libcurl initialization failed."); return NULL; }
    ZcNet *n=calloc(1,sizeof(*n));
    if (!n) { curl_global_cleanup(); failure(error,ZC_CONFIG,"Transport allocation failed."); return NULL; }
    const curl_version_info_data *version=curl_version_info(CURLVERSION_NOW);
    if (!version->ssl_version || strncmp(version->ssl_version,"OpenSSL/3.",10) || OpenSSL_version_num()<0x30000000L) {
        failure(error,ZC_CONFIG,"Zimbr requires libcurl with the OpenSSL 3 TLS backend. Install a supported build."); goto fail;
    }
    if (!zc_origin_valid(origin)) { failure(error,ZC_CONFIG,"relay_url must be an HTTPS origin with a hostname and optional port only."); goto fail; }
    n->origin=strdup(origin); if (!n->origin) goto oom;
    size_t len=strlen(n->origin); if (n->origin[len-1]=='/') n->origin[len-1]=0;
    const char *paths[]={ca,cert,key}; char **buffers[]={&n->ca,&n->cert,&n->key};
    size_t *lengths[]={&n->ca_len,&n->cert_len,&n->key_len};
    const char *labels[]={"CA file","Client certificate","Client key"};
    for (int i=0;i<3;i++) if (zc_private_read(paths[i],buffers[i],lengths[i])!=1) {
        snprintf(error->message,sizeof(error->message),"%s missing or unsafe. Use an absolute path, owned 0600 file in a 0700 directory, without symlinks; then Reconnect.",labels[i]);
        error->kind=ZC_CREDENTIALS; goto fail;
    }
    if (!credentials(n,error,identity)) goto fail;
    n->multi=curl_multi_init(); n->headers=curl_slist_append(NULL,"Content-Type: application/json");
    n->fn=fn; n->context=context;
    if (!n->multi || !n->headers) goto oom;
    return n;
oom: failure(error,ZC_CONFIG,"Transport allocation failed.");
fail: zc_net_free(n); return NULL;
}
int zc_net_start(ZcNet *n, int stream, const char *path, const char *body) {
    if (stream<0 || stream>3 || n->slots[stream].easy || path[0]!='/' || path[1]=='/') return 0;
    struct Slot *s=&n->slots[stream]; s->easy=curl_easy_init(); if (!s->easy) return 0;
    s->owner=n; s->stream=stream==1; s->media=stream>=2; s->last_rx=monotonic_ms();
    char url[8192];
    if (snprintf(url,sizeof(url),"%s%s",n->origin,path)>=(int)sizeof(url)) { clear_slot(n,stream); return 0; }
    CURLcode code;
#define SET(option,value) do { code=curl_easy_setopt(s->easy,option,value); if (code!=CURLE_OK) goto setup_error; } while (0)
    struct curl_blob ca={n->ca,n->ca_len,CURL_BLOB_COPY}, cert={n->cert,n->cert_len,CURL_BLOB_COPY}, key={n->key,n->key_len,CURL_BLOB_COPY};
    SET(CURLOPT_ERRORBUFFER,s->error.message);
    SET(CURLOPT_URL,url);
    SET(CURLOPT_PROXY,""); SET(CURLOPT_NOPROXY,"*");
    SET(CURLOPT_PROTOCOLS_STR,"https"); SET(CURLOPT_REDIR_PROTOCOLS_STR,"https");
    SET(CURLOPT_FOLLOWLOCATION,0L); SET(CURLOPT_MAXREDIRS,0L);
    SET(CURLOPT_HTTP_VERSION,(long)CURL_HTTP_VERSION_1_1);
    SET(CURLOPT_SSL_VERIFYPEER,1L); SET(CURLOPT_SSL_VERIFYHOST,2L);
    SET(CURLOPT_SSLVERSION,(long)(CURL_SSLVERSION_TLSv1_3|CURL_SSLVERSION_MAX_TLSv1_3));
    SET(CURLOPT_SSL_OPTIONS,0L); SET(CURLOPT_SSL_SESSIONID_CACHE,0L);
    SET(CURLOPT_CAINFO,NULL); SET(CURLOPT_CAPATH,NULL); SET(CURLOPT_CA_CACHE_TIMEOUT,0L);
    SET(CURLOPT_CAINFO_BLOB,&ca); SET(CURLOPT_SSLCERTTYPE,"PEM"); SET(CURLOPT_SSLKEYTYPE,"PEM");
    SET(CURLOPT_SSLCERT_BLOB,&cert); SET(CURLOPT_SSLKEY_BLOB,&key);
    SET(CURLOPT_SSL_CTX_FUNCTION,tls_context); SET(CURLOPT_SSL_CTX_DATA,s);
    SET(CURLOPT_HTTPHEADER,n->headers); SET(CURLOPT_NOSIGNAL,1L);
    SET(CURLOPT_CONNECTTIMEOUT_MS,3000L); SET(CURLOPT_TIMEOUT_MS,s->stream ? 0L : (s->media ? 30000L : 7000L));
    if (!s->stream) { SET(CURLOPT_LOW_SPEED_LIMIT,1L); SET(CURLOPT_LOW_SPEED_TIME,7L); }
    SET(CURLOPT_NOPROGRESS,0L); SET(CURLOPT_XFERINFOFUNCTION,progress); SET(CURLOPT_XFERINFODATA,s);
    SET(CURLOPT_WRITEFUNCTION,receive); SET(CURLOPT_WRITEDATA,s); SET(CURLOPT_PRIVATE,s);
    SET(CURLOPT_HEADERFUNCTION,receive_header); SET(CURLOPT_HEADERDATA,s);
    if (body) { SET(CURLOPT_POST,1L); SET(CURLOPT_COPYPOSTFIELDS,body); }
    if (curl_multi_add_handle(n->multi,s->easy)!=CURLM_OK) { code=CURLE_FAILED_INIT; goto setup_error; }
    return 1;
setup_error:
    s->error.curl_code=code;
    snprintf(s->error.message,sizeof(s->error.message),"libcurl TLS/request setup failed: %s. Install a supported libcurl/OpenSSL build, then Reconnect.",curl_easy_strerror(code));
    s->error.kind=ZC_CONFIG; s->done=1; return 1;
#undef SET
}
int zc_net_start_file(ZcNet *n, int lane, const char *path, int fd, size_t expected) {
    if (lane<0 || lane>1 || fd<0 || expected>8*1024*1024) return 0;
    int slot=lane+2;
    if (!zc_net_start(n,slot,path,NULL)) return 0;
    n->slots[slot].fd=fd; n->slots[slot].expected=expected;
    return 1;
}
const char *zc_net_media_body(ZcNet *n, int lane, size_t *length) {
    struct Slot *s=&n->slots[lane+2]; *length=s->body ? s->len : 0; return s->body;
}
void zc_net_cancel_stream(ZcNet *n) { clear_slot(n,1); }
void zc_net_cancel_request(ZcNet *n) { clear_slot(n,0); }
int zc_net_wait(ZcNet *n, int wake_fd, int timeout_ms) {
    int ready=0;
    if (n) {
        struct curl_waitfd wake={.fd=wake_fd,.events=CURL_WAIT_POLLIN,.revents=0};
        if (curl_multi_poll(n->multi,&wake,wake_fd>=0 ? 1 : 0,timeout_ms,&ready)!=CURLM_OK) return 0;
    } else {
        struct pollfd wake={.fd=wake_fd,.events=POLLIN}; poll(&wake,wake_fd>=0 ? 1 : 0,timeout_ms);
    }
    if (wake_fd>=0) { char bytes[128]; while (read(wake_fd,bytes,sizeof(bytes))>0) {} }
    return 1;
}
int zc_net_poll(ZcNet *n) {
    int active=0; if (curl_multi_perform(n->multi,&active)!=CURLM_OK) return 0;
    int queued; CURLMsg *m;
    while ((m=curl_multi_info_read(n->multi,&queued))) if (m->msg==CURLMSG_DONE) {
        struct Slot *s=NULL; curl_easy_getinfo(m->easy_handle,CURLINFO_PRIVATE,&s);
        curl_easy_getinfo(m->easy_handle,CURLINFO_RESPONSE_CODE,&s->status);
        curl_easy_getinfo(m->easy_handle,CURLINFO_SSL_VERIFYRESULT,&s->error.verify_result);
        CURLcode code=m->data.result; s->error.curl_code=code;
        if (code!=CURLE_OK) {
            if (!s->error.message[0]) snprintf(s->error.message,sizeof(s->error.message),"%s",curl_easy_strerror(code));
            if (code==CURLE_PEER_FAILED_VERIFICATION || code==CURLE_SSL_ISSUER_ERROR) s->error.kind=ZC_SERVER_TRUST;
            else if (code==CURLE_SSL_CERTPROBLEM || code==CURLE_SSL_CACERT_BADFILE) s->error.kind=ZC_CREDENTIALS;
            else if ((s->alert>=42 && s->alert<=46) || s->alert==48 || s->alert==116) s->error.kind=ZC_CLIENT_REJECTED;
            else if (code==CURLE_SSL_CONNECT_ERROR || s->alert) s->error.kind=ZC_TLS;
            else s->error.kind=ZC_NETWORK;
        } else if (s->status>=300 || (s->stream && s->status!=200)) {
            s->error.kind=ZC_HTTP;
            snprintf(s->error.message,sizeof(s->error.message),"Relay returned HTTP %ld%s",s->status,s->status<400 ? "; redirects are disabled. Check relay_url, then Reconnect." : ".");
        }
        if (code==CURLE_OK && s->stream && s->status==200) {
            failure(&s->error,ZC_NETWORK,"Event stream closed. Reconnecting from the saved cursor.");
        }
        if (code==CURLE_OK && s->media && s->status==200) {
            curl_off_t length=-1;
            curl_easy_getinfo(s->easy,CURLINFO_CONTENT_LENGTH_DOWNLOAD_T,&length);
            if (length<1 || (uint64_t)length!=s->len || (s->expected && s->expected!=s->len) ||
                (strcmp(s->mime,"image/png") && strcmp(s->mime,"image/jpeg"))) {
                failure(&s->error,ZC_HTTP,"Invalid image response length or content type.");
                s->error.curl_code=CURLE_PARTIAL_FILE;
            }
        }
        /* Keep the actual HTTP status even for truncated 200 responses. */
        s->done=1;
    }
    return 1;
}
int zc_net_done(ZcNet *n, int stream) { return n->slots[stream].done; }
long zc_net_status(ZcNet *n, int stream) {
    struct Slot *s=&n->slots[stream]; long status=s->status;
    if (s->easy && !s->done) curl_easy_getinfo(s->easy,CURLINFO_RESPONSE_CODE,&status);
    return status;
}
void zc_net_error(ZcNet *n, int stream, ZcError *error) { *error=n->slots[stream].error; }
const char *zc_net_extensions(ZcNet *n) { return n->slots[1].extensions; }
const char *zc_net_body(ZcNet *n, size_t *length) { *length=n->slots[0].len; return n->slots[0].body; }
void zc_net_ack(ZcNet *n, int stream) { clear_slot(n,stream); }

int zc_url_host(const char *value, char *output, size_t size) {
    if (!value || strlen(value)>8192) return 0;
    for (const unsigned char *p=(const unsigned char *)value; *p; p++)
        if (*p<=32 || *p==127 || *p=='\\') return 0;
    if (strncasecmp(value,"https://",8) && strncasecmp(value,"http://",7)) return 0;
    const char *authority=strstr(value,"://")+3;
    if (!*authority || *authority=='/' || *authority=='?' || *authority=='#') return 0;
    CURLU *url=curl_url(); if (!url) return 0;
    char *host=NULL, *user=NULL, *password=NULL;
    int ok=curl_url_set(url,CURLUPART_URL,value,0)==CURLUE_OK &&
        curl_url_get(url,CURLUPART_HOST,&host,0)==CURLUE_OK && host && *host && strlen(host)<size &&
        curl_url_get(url,CURLUPART_USER,&user,0)==CURLUE_NO_USER &&
        curl_url_get(url,CURLUPART_PASSWORD,&password,0)==CURLUE_NO_PASSWORD;
    if (ok) snprintf(output,size,"%s",host);
    curl_free(host); curl_free(user); curl_free(password); curl_url_cleanup(url); return ok;
}
int zc_url_open(const char *url) {
    char host[512]; if (!zc_url_host(url,host,sizeof(host))) return 0;
    /* The desktop API receives a URI argument; no command or shell expansion. */
    g_app_info_launch_default_for_uri_async(url,NULL,NULL,NULL,NULL);
    return 1;
}

struct ZcText { PangoLayout *layout; cairo_surface_t *surface; int width, height, subpixel; double scale; };
static cairo_t *text_context(cairo_surface_t *surface, double scale, int top, int subpixel) {
    cairo_t *cr = cairo_create(surface);
    // Keep glyph coordinates unchanged across tiles, including color emoji.
    cairo_surface_set_device_offset(surface, 0, -top);
    cairo_scale(cr, scale, scale);
    cairo_font_options_t *options = cairo_font_options_create();
    // Cairo/FreeType falls back when the font backend cannot render LCD glyphs.
    // Transparent textures use grayscale; RGB coverage needs an opaque backdrop.
    cairo_font_options_set_antialias(options, subpixel ? CAIRO_ANTIALIAS_SUBPIXEL : CAIRO_ANTIALIAS_GRAY);
    cairo_font_options_set_subpixel_order(options, CAIRO_SUBPIXEL_ORDER_RGB);
    cairo_font_options_set_hint_style(options, CAIRO_HINT_STYLE_SLIGHT);
    cairo_font_options_set_hint_metrics(options, CAIRO_HINT_METRICS_ON);
    cairo_set_font_options(cr, options);
    cairo_font_options_destroy(options);
    return cr;
}
ZcText *zc_text_new_with_options(const char *text, int length, double size, int width, double scale, int single_line, int subpixel) {
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
    ZcText *t = calloc(1, sizeof(*t)); if (!t) return NULL; t->scale = scale; t->subpixel = subpixel;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
    // Shape and hint at the same device scale used for rasterization. Creating
    // the layout at 1x then drawing it at fractional scale softens small text.
    cairo_t *cr = text_context(surface, scale, 0, subpixel); t->layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_new();
    pango_font_description_set_family(font, "sans-serif");
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_layout_set_font_description(t->layout, font); pango_font_description_free(font);
    pango_layout_set_text(t->layout, text, length);
    pango_layout_set_width(t->layout, width > 0 ? width * PANGO_SCALE : -1);
    pango_layout_set_wrap(t->layout, char_wrap ? PANGO_WRAP_CHAR : PANGO_WRAP_WORD_CHAR);
    if (single_line) {
        pango_layout_set_single_paragraph_mode(t->layout, TRUE);
        pango_layout_set_height(t->layout, -1);
        pango_layout_set_ellipsize(t->layout, PANGO_ELLIPSIZE_END);
    }
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
ZcText *zc_text_new(const char *text, int length, double size, int width, double scale) {
    return zc_text_new_with_options(text, length, size, width, scale, 0, 0);
}
ZcText *zc_text_new_line(const char *text, int length, double size, int width, double scale) {
    return zc_text_new_with_options(text, length, size, width, scale, 1, 0);
}
void zc_text_clear_pixels(ZcText *t) { if (t->surface) cairo_surface_destroy(t->surface); t->surface = NULL; }
void zc_text_free(ZcText *t) { if (!t) return; zc_text_clear_pixels(t); g_object_unref(t->layout); free(t); }
int zc_text_width(ZcText *t) { return t->width; }
int zc_text_height(ZcText *t) { return t->height; }
double zc_text_ink_center_x(ZcText *t) {
    PangoRectangle ink;
    pango_layout_get_extents(t->layout, &ink, NULL);
    return (ink.x + ink.width / 2.0) / PANGO_SCALE;
}
double zc_text_ink_center_y(ZcText *t) {
    PangoRectangle ink;
    pango_layout_get_extents(t->layout, &ink, NULL);
    return (ink.y + ink.height / 2.0) / PANGO_SCALE;
}
unsigned char *zc_text_pixels(ZcText *t, unsigned color, int start, int end, int top, int height) {
    return zc_text_pixels_on(t, color, start, end, top, height, 0);
}
unsigned char *zc_text_pixels_on(ZcText *t, unsigned color, int start, int end, int top, int height, unsigned background) {
    zc_text_clear_pixels(t);
    if (top < 0 || top >= t->height || height < 1 || height > 2048 ||
        height > t->height - top || (size_t)t->width * (size_t)height > 8*1024*1024 ||
        (t->subpixel && (background & 255) != 255)) return NULL;
    // Cairo can clip glyph coverage differently when a glyph straddles a surface
    // edge. Include whole intersecting lines, then return just the requested tile.
    int raster_top = top, raster_bottom = top + height;
    PangoLayoutIter *bounds = pango_layout_get_iter(t->layout);
    do {
        PangoRectangle ink, logical;
        pango_layout_iter_get_line_extents(bounds, &ink, &logical);
        int y = (int)floor(MIN(ink.y, logical.y)/(double)PANGO_SCALE*t->scale) - 2;
        int bottom = (int)ceil(MAX(ink.y + ink.height, logical.y + logical.height)/(double)PANGO_SCALE*t->scale) + 2;
        if (bottom < top || y > top + height) continue;
        raster_top = MIN(raster_top, y);
        raster_bottom = MAX(raster_bottom, bottom);
    } while (pango_layout_iter_next_line(bounds));
    pango_layout_iter_free(bounds);
    if ((size_t)t->width * (size_t)(raster_bottom - raster_top) > 8*1024*1024) return NULL;
    t->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, t->width, raster_bottom - raster_top);
    if (cairo_surface_status(t->surface) != CAIRO_STATUS_SUCCESS) { zc_text_clear_pixels(t); return NULL; }
    cairo_t *cr = text_context(t->surface, t->scale, raster_top, t->subpixel);
    if ((background & 255) == 255) {
        // Composite each RGB coverage channel onto its real background before
        // uploading; a single texture alpha cannot preserve three coverages.
        cairo_set_source_rgb(cr, ((background>>24)&255)/255., ((background>>16)&255)/255., ((background>>8)&255)/255.);
        cairo_paint(cr);
    }
    // Use the measured layout unchanged. Only draw lines intersecting this
    // tile; drawing the entire document still shapes/rasterizes offscreen text.
    PangoLayoutIter *it = pango_layout_get_iter(t->layout);
    do {
        PangoRectangle ink, logical;
        pango_layout_iter_get_line_extents(it, &ink, &logical);
        double bottom = MAX(ink.y + ink.height, logical.y + logical.height)/(double)PANGO_SCALE*t->scale;
        double line_top = MIN(ink.y, logical.y)/(double)PANGO_SCALE*t->scale;
        // LCD filtering can extend glyph coverage beyond the reported ink box.
        if (bottom + 2 < top || line_top - 2 > top + height) continue;
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
    unsigned char *pixels = cairo_image_surface_get_data(t->surface) + (top - raster_top)*cairo_image_surface_get_stride(t->surface);
    // Cairo is premultiplied native ARGB; raylib expects straight RGBA.
    const int width = t->width;
    const int stride = cairo_image_surface_get_stride(t->surface);
    if ((background & 255) == 255) {
        // A whole-pixel expression lets the compiler use SIMD shuffles.
        // memcpy keeps unaligned access and C aliasing rules well defined.
        for (int y=0; y<height; ++y) for (int x=0; x<width; ++x) {
            unsigned char *p = pixels+y*stride+x*4;
            uint32_t pixel; memcpy(&pixel,p,sizeof(pixel));
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
            pixel=(pixel & 0xff00ff00u) | ((pixel & 0xffu)<<16) | ((pixel>>16)&0xffu);
#else
            pixel=(pixel<<8) | (pixel>>24);
#endif
            memcpy(p,&pixel,sizeof(pixel));
        }
    } else {
        for (int y=0; y<height; ++y) for (int x=0; x<t->width; ++x) {
            unsigned char *p = pixels+y*stride+x*4;
            unsigned b=p[0], g=p[1], r=p[2], a=p[3];
            p[0]=a ? (unsigned char)(r*255/a) : 0; p[1]=a ? (unsigned char)(g*255/a) : 0; p[2]=a ? (unsigned char)(b*255/a) : 0;
        }
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
