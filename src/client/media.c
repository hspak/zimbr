#define _GNU_SOURCE
#include "bridge.h"
#include <png.h>
#include <stdio.h>
#include <jpeglib.h>
#include <setjmp.h>
#include <sys/stat.h>
#include <sys/random.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <time.h>

#define ENCODED_LIMIT (8u*1024*1024)
#define PIXEL_LIMIT (32u*1024*1024)
static int cache_name(const char *name) {
    size_t n=strlen(name);
    if (n!=64 && n!=36) return 0;
    size_t start=0;
    if (n==36) { if (strncmp(name,"tmp-",4)) return 0; start=4; }
    for (size_t i=start;i<n;i++) if (!((name[i]>='a' && name[i]<='f') || (name[i]>='0' && name[i]<='9'))) return 0;
    return 1;
}
int zc_cache_open(const char *path) {
    if (mkdir(path,0700) && errno!=EEXIST) return -1;
    int dir=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (dir<0) return -1;
    struct stat st;
    if (fstat(dir,&st) || st.st_uid!=getuid() || (st.st_mode&0777)!=0700) { close(dir); return -1; }
    return dir;
}
int zc_cache_temp(int dir, char *name, size_t size) {
    if (size<37) return -1;
    unsigned char random[16];
    if (getrandom(random,sizeof(random),0)!=(ssize_t)sizeof(random)) return -1;
    memcpy(name,"tmp-",4);
    for (size_t i=0;i<sizeof(random);i++) snprintf(name+4+i*2,3,"%02x",random[i]);
    return openat(dir,name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
}
int zc_cache_install(int dir, const char *temporary, const char *key, int fd) {
    if (!cache_name(temporary) || !cache_name(key) || strlen(key)!=64 || fsync(fd)) return 0;
    if (renameat(dir,temporary,dir,key)) return 0;
    return fsync(dir)==0;
}
void zc_cache_remove(int dir, const char *name) {
    if (cache_name(name)) unlinkat(dir,name,0);
}
struct Entry { char name[65]; off_t bytes; struct timespec used; };
static int oldest(const void *aa, const void *bb) {
    const struct Entry *a=aa,*b=bb;
    if (a->used.tv_sec!=b->used.tv_sec) return a->used.tv_sec<b->used.tv_sec ? -1 : 1;
    return a->used.tv_nsec<b->used.tv_nsec ? -1 : a->used.tv_nsec>b->used.tv_nsec;
}
void zc_cache_prune(int dir, size_t budget) {
    int copy=openat(dir,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC); if (copy<0) return;
    DIR *scan=fdopendir(copy); if (!scan) { close(copy); return; }
    struct Entry *entries=NULL; size_t count=0,bytes=0;
    struct dirent *entry;
    while ((entry=readdir(scan))) {
        if (!cache_name(entry->d_name)) continue;
        if (strlen(entry->d_name)==36) {
            struct stat temporary;
            if (!fstatat(dir,entry->d_name,&temporary,AT_SYMLINK_NOFOLLOW) && S_ISREG(temporary.st_mode)) {
                if (time(NULL)-temporary.st_mtime>60) unlinkat(dir,entry->d_name,0);
                else if (temporary.st_size>0) bytes+=(size_t)temporary.st_size;
            }
            continue;
        }
        struct stat st;
        if (fstatat(dir,entry->d_name,&st,AT_SYMLINK_NOFOLLOW) || !S_ISREG(st.st_mode) || st.st_uid!=getuid() || st.st_size<0) continue;
        if (count==8192) { unlinkat(dir,entry->d_name,0); continue; }
        struct Entry *next=realloc(entries,(count+1)*sizeof(*entries)); if (!next) break;
        entries=next;
        snprintf(entries[count].name,sizeof(entries[count].name),"%s",entry->d_name);
        entries[count].bytes=st.st_size; entries[count].used=st.st_mtim;
        bytes+=(size_t)st.st_size; count++;
    }
    closedir(scan); if (count>1) qsort(entries,count,sizeof(*entries),oldest);
    for (size_t i=0;i<count && bytes>budget;i++) {
        if (!unlinkat(dir,entries[i].name,0)) bytes-=(size_t)entries[i].bytes;
    }
    free(entries);
}
static int dimensions(int w, int h) {
    return w>0 && h>0 && w<=2560 && h<=2560 && (uint64_t)w*h*4<=PIXEL_LIMIT;
}
static int decode_png(const unsigned char *bytes, size_t length, ZcPixels *output) {
    png_image image; memset(&image,0,sizeof(image)); image.version=PNG_IMAGE_VERSION;
    if (!png_image_begin_read_from_memory(&image,bytes,length)) return 0;
    int ok=0;
    if (image.width>2560 || image.height>2560 || !dimensions((int)image.width,(int)image.height)) goto end;
    image.format=PNG_FORMAT_RGBA;
    output->bytes=PNG_IMAGE_SIZE(image); output->data=malloc(output->bytes);
    if (!output->data || !png_image_finish_read(&image,NULL,output->data,0,NULL)) goto end;
    output->width=(int)image.width; output->height=(int)image.height; ok=1;
end:
    png_image_free(&image); return ok;
}
struct JpegError { struct jpeg_error_mgr base; jmp_buf jump; };
static void jpeg_failure(j_common_ptr common) {
    struct JpegError *error=(struct JpegError *)common->err; longjmp(error->jump,1);
}
static void jpeg_silent(j_common_ptr common) { (void)common; }
static int decode_jpeg(const unsigned char *bytes, size_t length, ZcPixels *output) {
    struct jpeg_decompress_struct image; memset(&image,0,sizeof(image));
    struct JpegError error; image.err=jpeg_std_error(&error.base);
    error.base.error_exit=jpeg_failure; error.base.output_message=jpeg_silent;
    if (setjmp(error.jump)) { jpeg_destroy_decompress(&image); return 0; }
    jpeg_create_decompress(&image);
    image.mem->max_memory_to_use=32*1024*1024;
    jpeg_mem_src(&image,bytes,(unsigned long)length);
    int ok=0;
    if (jpeg_read_header(&image,TRUE)!=JPEG_HEADER_OK || image.image_width>2560 || image.image_height>2560 || !dimensions((int)image.image_width,(int)image.image_height)) goto end;
#ifdef JCS_ALPHA_EXTENSIONS
    // libjpeg-turbo converts directly into the texture, including opaque alpha,
    // using its SIMD color conversion without an intermediate RGB row.
    image.out_color_space=JCS_EXT_RGBA;
    const int components=4;
#else
    image.out_color_space=JCS_RGB;
    const int components=3;
#endif
    if (!jpeg_start_decompress(&image) || image.output_components!=components) goto end;
    output->width=(int)image.output_width; output->height=(int)image.output_height;
    output->bytes=(size_t)output->width*output->height*4;
    output->data=malloc(output->bytes); if (!output->data) goto end;
#ifndef JCS_ALPHA_EXTENSIONS
    unsigned char line[2560*3];
#endif
    while (image.output_scanline<image.output_height) {
        size_t y=image.output_scanline;
#ifdef JCS_ALPHA_EXTENSIONS
        JSAMPROW row=output->data+y*output->width*4;
#else
        JSAMPROW row=line;
#endif
        if (jpeg_read_scanlines(&image,&row,1)!=1) goto end;
#ifndef JCS_ALPHA_EXTENSIONS
        for (int x=0;x<output->width;x++) {
            unsigned char *dst=output->data+(y*output->width+x)*4;
            dst[0]=line[x*3]; dst[1]=line[x*3+1]; dst[2]=line[x*3+2]; dst[3]=255;
        }
#endif
    }
    ok=jpeg_finish_decompress(&image) && error.base.num_warnings==0;
end:
    jpeg_destroy_decompress(&image); return ok;
}
void zc_pixels_free(ZcPixels *pixels) { free(pixels->data); memset(pixels,0,sizeof(*pixels)); }
int zc_image_read(int dir, const char *name, ZcPixels *output) {
    memset(output,0,sizeof(*output));
    if (!cache_name(name)) return -1;
    int fd=openat(dir,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if (fd<0) return errno==ENOENT ? 0 : -1;
    struct stat st; int result=-1;
    unsigned char *bytes=NULL;
    if (fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_uid!=getuid() || (st.st_mode&0777)!=0600 || st.st_nlink!=1 || st.st_size<8 || st.st_size>ENCODED_LIMIT) goto end;
    bytes=malloc((size_t)st.st_size); if (!bytes) goto end;
    size_t used=0;
    while (used<(size_t)st.st_size) {
        ssize_t n=read(fd,bytes+used,(size_t)st.st_size-used);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) goto end;
        used+=(size_t)n;
    }
    unsigned char extra;
    if (read(fd,&extra,1)!=0) goto end;
    int decoded=0;
    if (!memcmp(bytes,"\x89PNG\r\n\x1a\n",8)) decoded=decode_png(bytes,used,output);
    else if (bytes[0]==0xff && bytes[1]==0xd8 && bytes[2]==0xff) decoded=decode_jpeg(bytes,used,output);
    if (!decoded) goto end;
    futimens(fd,NULL); result=1;
end:
    free(bytes); close(fd);
    if (result!=1) zc_pixels_free(output);
    return result;
}
void zc_cache_clear_avatars(int dir) {
    int copy=openat(dir,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC); if (copy<0) return;
    DIR *scan=fdopendir(copy); if (!scan) { close(copy); return; }
    struct dirent *entry;
    while ((entry=readdir(scan))) if (strlen(entry->d_name)==64 && entry->d_name[0]=='a' && cache_name(entry->d_name)) unlinkat(dir,entry->d_name,0);
    closedir(scan);
}
