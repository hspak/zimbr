/* Synthetic pixel boundary checks; run under ASan/UBSan via client_pixel_safety.py. */
#define _GNU_SOURCE
#include "bridge.h"
#include <assert.h>
#include <stdio.h>
#include <jpeglib.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static const char *key="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
static uint64_t checksum=14695981039346656037ull;
static unsigned accepted, rejected, tiles;
static void hash(const unsigned char *bytes, size_t length) {
    for (size_t i=0;i<length;i++) checksum=(checksum^bytes[i])*1099511628211ull;
}
static void decode(int dir, const unsigned char *bytes, size_t length, int width, int height, int gray) {
    int fd=openat(dir,key,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC,0600); assert(fd>=0);
    size_t used=0;
    while (used<length) {
        ssize_t written=write(fd,bytes+used,length-used); assert(written>0); used+=(size_t)written;
    }
    assert(close(fd)==0);
    ZcPixels pixels;
    memset(&pixels,0xcc,sizeof(pixels));
    int status=zc_image_read(dir,key,&pixels);
    if (!width) {
        assert(status==-1 && !pixels.data && !pixels.bytes && !pixels.width && !pixels.height);
        rejected++;
    } else {
        assert(status==1 && pixels.width==width && pixels.height==height);
        assert(pixels.bytes==(size_t)width*height*4);
        for (size_t i=0;i<pixels.bytes;i+=4) {
            assert(pixels.data[i+3]==255);
            if (gray) assert(pixels.data[i]==pixels.data[i+1] && pixels.data[i+1]==pixels.data[i+2]);
        }
        hash(pixels.data,pixels.bytes);
        accepted++;
    }
    zc_pixels_free(&pixels);
}
static void jpeg(int dir, int width, int mode) {
    const int gray=mode==1, height=3;
    struct jpeg_compress_struct encoder;
    struct jpeg_error_mgr error;
    encoder.err=jpeg_std_error(&error); jpeg_create_compress(&encoder);
    unsigned char *bytes=NULL; unsigned long length=0;
    jpeg_mem_dest(&encoder,&bytes,&length);
    encoder.image_width=width; encoder.image_height=height;
    encoder.input_components=gray ? 1 : 3; encoder.in_color_space=gray ? JCS_GRAYSCALE : JCS_RGB;
    jpeg_set_defaults(&encoder);
    if (mode==2) jpeg_simple_progression(&encoder);
    jpeg_start_compress(&encoder,TRUE);
    unsigned char *line=malloc((size_t)width*encoder.input_components); assert(line);
    while (encoder.next_scanline<encoder.image_height) {
        for (int x=0;x<width*encoder.input_components;x++) line[x]=(unsigned char)(x*13+encoder.next_scanline*37);
        JSAMPROW row=line; assert(jpeg_write_scanlines(&encoder,&row,1)==1);
    }
    jpeg_finish_compress(&encoder); jpeg_destroy_compress(&encoder); free(line);
    decode(dir,bytes,length,width,height,gray);
    if (width==17) {
        // Every truncated prefix must fail, including failures after allocation.
        for (size_t end=0;end<length;end++) decode(dir,bytes,end,0,0,0);
        size_t sof=0;
        for (size_t i=2;i+9<length;i++) if (bytes[i]==0xff && (bytes[i+1]==0xc0 || bytes[i+1]==0xc2)) { sof=i; break; }
        assert(sof);
        for (size_t at=sof+5;at<=sof+7;at+=2) {
            unsigned char saved[2]={bytes[at],bytes[at+1]};
            const unsigned sizes[]={0,2561,65535};
            for (size_t i=0;i<sizeof(sizes)/sizeof(*sizes);i++) {
                bytes[at]=(unsigned char)(sizes[i]>>8); bytes[at+1]=(unsigned char)sizes[i];
                decode(dir,bytes,length,0,0,0);
            }
            memcpy(bytes+at,saved,2);
        }
        unsigned char precision=bytes[sof+4]; bytes[sof+4]=0;
        decode(dir,bytes,length,0,0,0); bytes[sof+4]=precision;
        // A failed decoder must not poison the next valid read.
        decode(dir,bytes,length,width,height,gray);
    }
    free(bytes);
}
static void text_pixels(int width, double scale) {
    const char *body="Text ABC é 👩‍💻 שלום مرحبا\nSecond line with selection";
    for (int mode=0;mode<3;mode++) {
        unsigned background=mode ? 0x172839ff : 0;
        ZcText *text=zc_text_new_with_options(body,(int)strlen(body),16,width,scale,0,mode==2);
        if ((width+2.0)*scale>4096) { assert(!text); continue; }
        assert(text);
        int height=zc_text_height(text);
        int top=height>1 ? 1 : 0;
        height-=top; if (height>257) height=257;
        unsigned char *pixels=zc_text_pixels_on(text,0xfedcba80,0,8,top,height,background);
        assert(pixels);
        size_t length=(size_t)zc_text_width(text)*height*4;
        if (background) for (size_t i=3;i<length;i+=4) assert(pixels[i]==255);
        hash(pixels,length); tiles++;
        assert(!zc_text_pixels_on(text,0xffffffff,0,0,-1,1,background));
        assert(!zc_text_pixels_on(text,0xffffffff,0,0,0,2049,background));
        zc_text_free(text);
    }
}
int main(void) {
    char directory[]="/tmp/zimbr-pixel-safety-XXXXXX"; assert(mkdtemp(directory));
    int dir=zc_cache_open(directory); assert(dir>=0);
    const int widths[]={1,2,3,15,16,17,31,32,33,127,129,2559,2560};
    const double scales[]={.5,1,1.25,2,8};
    for (size_t i=0;i<sizeof(widths)/sizeof(*widths);i++) {
        for (int mode=0;mode<3;mode++) jpeg(dir,widths[i],mode);
        for (size_t j=0;j<sizeof(scales)/sizeof(*scales);j++) text_pixels(widths[i],scales[j]);
    }
    int fd=openat(dir,key,O_WRONLY|O_TRUNC|O_CLOEXEC); assert(fd>=0);
    assert(!ftruncate(fd,8*1024*1024+1)); assert(!close(fd));
    ZcPixels pixels;
    assert(zc_image_read(dir,key,&pixels)==-1 && !pixels.data && !pixels.bytes);
    assert(!unlinkat(dir,key,0)); assert(!close(dir)); assert(!rmdir(directory));
    printf("%u valid JPEGs, %u rejected JPEGs, %u text tiles; checksum %016llx\n",accepted,rejected,tiles,(unsigned long long)checksum);
}
