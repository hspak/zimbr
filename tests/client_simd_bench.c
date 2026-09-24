/* Complete client operations, synthetic data only; no display or network. */
#define _GNU_SOURCE
#include "bridge.h"
#include <stdio.h>
#include <jpeglib.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#define SAMPLES 15
static double now_us(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec*1000000.0+t.tv_nsec/1000.0;
}
static void require(int ok) { if (!ok) { fputs("benchmark operation failed\n",stderr); exit(1); } }
static int ascending(const void *a, const void *b) {
    double x=*(const double *)a, y=*(const double *)b;
    return (x>y)-(x<y);
}
static uint64_t hash(const unsigned char *bytes, size_t length) {
    uint64_t value=14695981039346656037ull;
    for (size_t i=0;i<length;i++) value=(value^bytes[i])*1099511628211ull;
    return value;
}
static void report(const char *name, double *times, uint64_t checksum) {
    qsort(times,SAMPLES,sizeof(*times),ascending);
    printf("{\"case\":\"%s\",\"p50_us\":%.3f,\"p95_us\":%.3f,\"checksum\":\"%016llx\"}\n",
           name,times[SAMPLES/2],times[SAMPLES-1],(unsigned long long)checksum);
}
static char *repeat(const char *phrase, size_t count) {
    size_t length=strlen(phrase);
    char *body=malloc(length*count+1); require(body!=NULL);
    for (size_t i=0;i<count;i++) memcpy(body+i*length,phrase,length);
    body[length*count]=0;
    return body;
}
static uint64_t raster_checksum(ZcText *text, unsigned background) {
    int height=zc_text_height(text); if (height>2048) height=2048;
    const unsigned char *pixels=zc_text_pixels_on(text,0xe9d8c7ff,0,0,0,height,background);
    require(pixels!=NULL);
    uint64_t value=hash(pixels,(size_t)zc_text_width(text)*height*4);
    zc_text_clear_pixels(text);
    return value ^ (uint64_t)zc_text_height(text);
}
static void raster(const char *name, const char *body, int width, double scale, unsigned background, int iterations) {
    ZcText *text=zc_text_new_with_options(body,(int)strlen(body),16,width,scale,0,(background&255)==255);
    require(text!=NULL);
    int height=zc_text_height(text); if (height>2048) height=2048;
    uint64_t checksum=raster_checksum(text,background);
    double times[SAMPLES];
    for (int sample=-1;sample<SAMPLES;sample++) {
        double start=now_us();
        for (int i=0;i<iterations;i++) {
            require(zc_text_pixels_on(text,0xe9d8c7ff,0,0,0,height,background)!=NULL);
            zc_text_clear_pixels(text);
        }
        if (sample>=0) times[sample]=(now_us()-start)/iterations;
    }
    report(name,times,checksum);
    zc_text_free(text);
}
static void layout(const char *name, const char *body, int iterations) {
    double times[SAMPLES]; uint64_t checksum=0;
    for (int sample=-1;sample<SAMPLES;sample++) {
        double start=now_us();
        for (int i=0;i<iterations;i++) {
            ZcText *text=zc_text_new_with_options(body,(int)strlen(body),16,480,1.25,0,1);
            require(text!=NULL);
            zc_text_free(text);
        }
        if (sample>=0) times[sample]=(now_us()-start)/iterations;
    }
    ZcText *text=zc_text_new_with_options(body,(int)strlen(body),16,480,1.25,0,1);
    require(text!=NULL); checksum=raster_checksum(text,0x202020ff); zc_text_free(text);
    report(name,times,checksum);
}
static void jpeg(const char *name, int width, int height, int grayscale, int iterations) {
    char directory[]="/tmp/zimbr-simd-jpeg-XXXXXX"; require(mkdtemp(directory)!=NULL);
    int dir=open(directory,O_RDONLY|O_DIRECTORY|O_CLOEXEC); require(dir>=0);
    const char *key="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    int fd=openat(dir,key,O_WRONLY|O_CREAT|O_EXCL,0600); require(fd>=0);
    FILE *file=fdopen(fd,"wb"); require(file!=NULL);
    struct jpeg_compress_struct encoder; struct jpeg_error_mgr errors;
    encoder.err=jpeg_std_error(&errors); jpeg_create_compress(&encoder);
    jpeg_stdio_dest(&encoder,file);
    encoder.image_width=width; encoder.image_height=height;
    encoder.input_components=grayscale ? 1 : 3;
    encoder.in_color_space=grayscale ? JCS_GRAYSCALE : JCS_RGB;
    jpeg_set_defaults(&encoder); jpeg_set_quality(&encoder,85,TRUE);
    jpeg_start_compress(&encoder,TRUE);
    unsigned char *line=malloc((size_t)width*encoder.input_components); require(line!=NULL);
    uint32_t noise=42;
    while (encoder.next_scanline<encoder.image_height) {
        for (int x=0;x<width;x++) for (int ch=0;ch<encoder.input_components;ch++) {
            noise=noise*1664525u+1013904223u;
            line[x*encoder.input_components+ch]=(unsigned char)(x/4+encoder.next_scanline/3+ch*47+(noise>>28));
        }
        JSAMPROW row=line; require(jpeg_write_scanlines(&encoder,&row,1)==1);
    }
    jpeg_finish_compress(&encoder); jpeg_destroy_compress(&encoder); free(line); require(fclose(file)==0);
    double times[SAMPLES]; uint64_t checksum=0;
    for (int sample=-1;sample<SAMPLES;sample++) {
        double start=now_us();
        for (int i=0;i<iterations;i++) {
            ZcPixels pixels;
            require(zc_image_read(dir,key,&pixels)==1);
            require(pixels.width==width && pixels.height==height);
            zc_pixels_free(&pixels);
        }
        if (sample>=0) times[sample]=(now_us()-start)/iterations;
    }
    ZcPixels pixels; require(zc_image_read(dir,key,&pixels)==1);
    checksum=hash(pixels.data,pixels.bytes); zc_pixels_free(&pixels);
    report(name,times,checksum);
    require(unlinkat(dir,key,0)==0); close(dir); require(rmdir(directory)==0);
}
int main(int argc, char **argv) {
    require(argc==2);
    if (!strcmp(argv[1],"raster")) {
        char *body=repeat("Opaque text, é 👩‍💻 and Unicode fallback.\n",6);
        char *long_body=repeat("A longer wrapped message with several lines of text.\n",50);
        raster("short", "A short message",480,1.25,0x202020ff,1000);
        raster("unicode",body,480,1.25,0x202020ff,200);
        raster("long_hidpi",long_body,720,2,0x202020ff,10);
        raster("transparent",body,480,1.25,0,100);
        free(body); free(long_body);
    } else if (!strcmp(argv[1],"jpeg")) {
        jpeg("avatar",128,128,0,200);
        jpeg("photo",1920,1080,0,5);
        jpeg("large_photo",2560,1440,0,3);
        jpeg("grayscale",1024,768,1,10);
    } else if (!strcmp(argv[1],"layout")) {
        char *body=repeat("A typical message contains ordinary words and spaces. ",72);
        char *draft=repeat("A long draft contains words, spaces, and newlines.\n",1000);
        char *mixed=repeat("Mixed text: Café é 👩‍💻 שלום مرحبا. ",72);
        layout("short_ascii","A short message about lunch tomorrow.",500);
        layout("ascii_4k",body,20);
        layout("long_draft",draft,2);
        layout("mixed_unicode",mixed,20);
        free(body); free(draft); free(mixed);
    } else return 1;
    return 0;
}
