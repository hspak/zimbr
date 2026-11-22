/* A real Wayland data-device source, used only by the desktop drop fixture. */
#define _GNU_SOURCE
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>

struct helper {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct wl_seat *seat;
    struct wl_pointer *pointer;
    struct wl_data_device_manager *manager;
    struct wl_data_device *device;
    struct wl_data_source *source;
    struct xdg_wm_base *wm;
    struct wl_surface *surface;
    struct wl_buffer *buffer;
    struct xdg_surface *xdg;
    struct xdg_toplevel *top;
    const char *uris;
    int done, ready, hold;
};
static void ping(void *data, struct xdg_wm_base *wm, uint32_t serial) { (void)data; xdg_wm_base_pong(wm, serial); }
static const struct xdg_wm_base_listener wm_listener = { .ping = ping };
static void registry_global(void *data, struct wl_registry *r, uint32_t name, const char *interface, uint32_t version) {
    struct helper *h = data;
    if (!strcmp(interface,"wl_compositor")) h->compositor=wl_registry_bind(r,name,&wl_compositor_interface,4);
    else if (!strcmp(interface,"wl_shm")) h->shm=wl_registry_bind(r,name,&wl_shm_interface,1);
    else if (!strcmp(interface,"wl_seat") && !h->seat) h->seat=wl_registry_bind(r,name,&wl_seat_interface,version<5?version:5);
    else if (!strcmp(interface,"wl_data_device_manager")) h->manager=wl_registry_bind(r,name,&wl_data_device_manager_interface,3);
    else if (!strcmp(interface,"xdg_wm_base")) { h->wm=wl_registry_bind(r,name,&xdg_wm_base_interface,1); xdg_wm_base_add_listener(h->wm,&wm_listener,h); }
}
static void registry_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d;(void)r;(void)n; }
static const struct wl_registry_listener registry_listener={registry_global,registry_remove};
static void acknowledged(void *data, struct wl_callback *callback, uint32_t serial) {
    (void)serial;
    wl_callback_destroy(callback);
    puts((const char *)data);
    fflush(stdout);
}
static const struct wl_callback_listener acknowledged_listener={acknowledged};
static void configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    struct helper *h=data;
    xdg_surface_ack_configure(surface,serial);
    wl_surface_attach(h->surface,h->buffer,0,0);
    wl_surface_damage(h->surface,0,0,240,100);
    if (!h->ready) {
        h->ready=1;
        /* A submitted buffer is not yet a mapped compositor view. */
        wl_callback_add_listener(wl_surface_frame(h->surface),&acknowledged_listener,"ready");
    }
    wl_surface_commit(h->surface);
}
static const struct xdg_surface_listener surface_listener={configure};
static void top_configure(void*d,struct xdg_toplevel*t,int32_t w,int32_t h,struct wl_array*s){(void)d;(void)t;(void)w;(void)h;(void)s;}
static void top_close(void*d,struct xdg_toplevel*t){(void)t;((struct helper*)d)->done=1;}
static const struct xdg_toplevel_listener top_listener={.configure=top_configure,.close=top_close};
static void target(void*d,struct wl_data_source*s,const char*m){(void)d;(void)s;(void)m;}
static void send_data(void*d,struct wl_data_source*s,const char*m,int32_t fd){
    (void)s; struct helper*h=d;
    if (m && !strcmp(m,"text/uri-list")) {
        size_t length=strlen(h->uris), offset=0;
        if (h->hold) {
            /* Keep a partial URI pending until the test releases stdin. */
            if (length && write(fd,h->uris,1)==1) offset=1;
            puts("sending"); fflush(stdout);
            char release;
            while (read(STDIN_FILENO,&release,1)<0 && errno==EINTR);
        }
        while(offset<length){ssize_t n=write(fd,h->uris+offset,length-offset);if(n<0&&errno==EINTR)continue;if(n<=0)break;offset+=(size_t)n;}
    }
    close(fd); puts("sent"); fflush(stdout);
}
static void cancelled(void*d,struct wl_data_source*s){(void)s;((struct helper*)d)->done=1;puts("cancelled");fflush(stdout);}
static void dropped(void*d,struct wl_data_source*s){(void)d;(void)s;puts("dropped");fflush(stdout);}
static void finished(void*d,struct wl_data_source*s){(void)s;((struct helper*)d)->done=1;puts("finished");fflush(stdout);}
static void action(void*d,struct wl_data_source*s,uint32_t a){(void)d;(void)s;(void)a;}
static const struct wl_data_source_listener source_listener={target,send_data,cancelled,dropped,finished,action};
static void enter(void*d,struct wl_pointer*p,uint32_t s,struct wl_surface*w,wl_fixed_t x,wl_fixed_t y){(void)d;(void)p;(void)s;(void)w;(void)x;(void)y;}
static void leave(void*d,struct wl_pointer*p,uint32_t s,struct wl_surface*w){(void)d;(void)p;(void)s;(void)w;}
static void motion(void*d,struct wl_pointer*p,uint32_t t,wl_fixed_t x,wl_fixed_t y){(void)d;(void)p;(void)t;(void)x;(void)y;}
static void button(void*d,struct wl_pointer*p,uint32_t serial,uint32_t time,uint32_t button,uint32_t state){
    (void)p;(void)time;(void)button;struct helper*h=d;
    if(state==WL_POINTER_BUTTON_STATE_PRESSED&&!h->source){
        h->source=wl_data_device_manager_create_data_source(h->manager);
        wl_data_source_add_listener(h->source,&source_listener,h);
        wl_data_source_offer(h->source,"text/uri-list");
        wl_data_source_set_actions(h->source,WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
        wl_data_device_start_drag(h->device,h->source,h->surface,NULL,serial);
        /* Acknowledge the established drag before the driver moves its pointer. */
        wl_callback_add_listener(wl_display_sync(h->display),&acknowledged_listener,"dragging");
        wl_display_flush(h->display);
    }
}
static void axis(void*d,struct wl_pointer*p,uint32_t t,uint32_t a,wl_fixed_t v){(void)d;(void)p;(void)t;(void)a;(void)v;}
static void frame(void*d,struct wl_pointer*p){(void)d;(void)p;}
static void axis_source(void*d,struct wl_pointer*p,uint32_t s){(void)d;(void)p;(void)s;}
static void axis_stop(void*d,struct wl_pointer*p,uint32_t t,uint32_t a){(void)d;(void)p;(void)t;(void)a;}
static void axis_discrete(void*d,struct wl_pointer*p,uint32_t a,int32_t v){(void)d;(void)p;(void)a;(void)v;}
static const struct wl_pointer_listener pointer_listener={.enter=enter,.leave=leave,.motion=motion,.button=button,.axis=axis,.frame=frame,.axis_source=axis_source,.axis_stop=axis_stop,.axis_discrete=axis_discrete};
static void capabilities(void*d,struct wl_seat*s,uint32_t caps){struct helper*h=d;if((caps&WL_SEAT_CAPABILITY_POINTER)&&!h->pointer){h->pointer=wl_seat_get_pointer(s);wl_pointer_add_listener(h->pointer,&pointer_listener,h);}}
static void seat_name(void*d,struct wl_seat*s,const char*n){(void)d;(void)s;(void)n;}
static const struct wl_seat_listener seat_listener={capabilities,seat_name};
int main(int argc,char **argv){
    if((argc!=2 && (argc!=3 || strcmp(argv[2],"--hold")))||strlen(argv[1])>16384)return 2;
    signal(SIGPIPE,SIG_IGN);
    struct helper h={.uris=argv[1],.hold=argc==3};
    h.display=wl_display_connect(NULL);if(!h.display)return 3;
    struct wl_registry*r=wl_display_get_registry(h.display);wl_registry_add_listener(r,&registry_listener,&h);
    if(wl_display_roundtrip(h.display)<0||!h.compositor||!h.shm||!h.seat||!h.wm||!h.manager)return 4;
    wl_seat_add_listener(h.seat,&seat_listener,&h);
    h.device=wl_data_device_manager_get_data_device(h.manager,h.seat);
    int fd=memfd_create("zrct-drop",MFD_CLOEXEC);if(fd<0||ftruncate(fd,240*100*4))return 5;
    uint32_t*p=mmap(NULL,240*100*4,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(p==MAP_FAILED)return 5;
    for(int i=0;i<240*100;i++)p[i]=0xff287cb0;
    struct wl_shm_pool*pool=wl_shm_create_pool(h.shm,fd,240*100*4);h.buffer=wl_shm_pool_create_buffer(pool,0,240,100,240*4,WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);munmap(p,240*100*4);close(fd);
    h.surface=wl_compositor_create_surface(h.compositor);h.xdg=xdg_wm_base_get_xdg_surface(h.wm,h.surface);xdg_surface_add_listener(h.xdg,&surface_listener,&h);
    h.top=xdg_surface_get_toplevel(h.xdg);xdg_toplevel_add_listener(h.top,&top_listener,&h);xdg_toplevel_set_app_id(h.top,"zrct-dnd");xdg_toplevel_set_title(h.top,"zrct-dnd");wl_surface_commit(h.surface);
    while(!h.done&&wl_display_dispatch(h.display)>=0);
    wl_display_disconnect(h.display);return h.done?0:6;
}
