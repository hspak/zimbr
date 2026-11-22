/* Private Weston 15 input backend. No app-side input injection in this boundary. */
#define _GNU_SOURCE
#include <libweston/libweston.h>
#include <libweston/desktop.h>
#include <wayland-server-core.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Weston 15 backend entrypoints are exported but not installed in the public header. */
void weston_seat_init(struct weston_seat *, struct weston_compositor *, const char *);
int weston_seat_init_pointer(struct weston_seat *);
int weston_seat_init_keyboard(struct weston_seat *, struct xkb_keymap *);
void weston_seat_release(struct weston_seat *);
void notify_motion_absolute(struct weston_seat *, const struct timespec *, struct weston_coord_global);
void notify_button(struct weston_seat *, const struct timespec *, int32_t, enum wl_pointer_button_state);
void notify_key(struct weston_seat *, const struct timespec *, uint32_t, enum wl_keyboard_key_state, enum weston_key_state_update);
void notify_pointer_frame(struct weston_seat *);
int zrct_weston_scale_init(struct weston_compositor *);

struct driver {
    struct weston_compositor *compositor;
    struct weston_seat seat;
    struct wl_listener destroy;
    struct wl_event_source *listener;
    int fd;
    char path[108];
    struct peer *peers[8];
};
struct peer {
    struct driver *driver;
    struct wl_event_source *source, *timer;
    int fd, slot;
};
static void dispose(struct peer *p) {
    p->driver->peers[p->slot] = NULL;
    wl_event_source_remove(p->source);
    wl_event_source_remove(p->timer);
    close(p->fd);
    free(p);
}
static int expired(void *data) { dispose(data); return 0; }
static struct weston_view *find_view(struct driver *d, const char *name) {
    struct weston_view *v;
    wl_list_for_each(v, &d->compositor->view_list, link) {
        if (!weston_surface_is_desktop_surface(v->surface)) continue;
        struct weston_desktop_surface *surface = weston_surface_get_desktop_surface(v->surface);
        const char *id = weston_desktop_surface_get_app_id(surface);
        const char *title = weston_desktop_surface_get_title(surface);
        if ((id && !strcmp(id, name)) || (title && !strncasecmp(title, name, strlen(name)))) return v;
    }
    return NULL;
}
static int receive(int fd, uint32_t mask, void *data) {
    (void)mask;
    struct peer *p = data;
    struct driver *d = p->driver;
    char input[1024], op[32], app[128], response[512];
    ssize_t n = recv(fd, input, sizeof(input) - 1, MSG_DONTWAIT);
    if (n < 0 && errno == EAGAIN) return 0;
    if (n <= 0) { dispose(p); return 0; }
    input[n] = 0;
    snprintf(response, sizeof(response), "{\"error\":\"invalid desktop command\"}\n");
    double x, y;
    unsigned code, state;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (sscanf(input, "%31s", op) != 1) goto reply;
    if (!strcmp(op, "hello")) {
        snprintf(response, sizeof(response), "{\"version\":1,\"boundary\":\"compositor_input\",\"operations\":[\"move\",\"button\",\"key\",\"activate\",\"geometry\",\"scale\"]}\n");
    } else if ((!strcmp(op, "move") || !strcmp(op, "geometry") || !strcmp(op, "activate")) && sscanf(input, "%*s %127s", app) == 1) {
        struct weston_view *view = find_view(d, app);
        if (!view) { snprintf(response, sizeof(response), "{\"error\":\"application surface is not mapped\"}\n"); goto reply; }
        struct weston_geometry geometry = weston_desktop_surface_get_geometry(weston_surface_get_desktop_surface(view->surface));
        if (!strcmp(op, "activate")) {
            weston_view_activate_input(view, &d->seat, WESTON_ACTIVATE_FLAG_CONFIGURE);
        } else if (!strcmp(op, "move")) {
            if (sscanf(input, "%*s %*s %lf %lf", &x, &y) != 2 || !isfinite(x) || !isfinite(y) || fabs(x) > 10000 || fabs(y) > 10000) goto reply;
            struct weston_coord_surface local = { .c = { x, y }, .coordinate_space_id = view->surface };
            weston_view_update_transform(view);
            struct weston_coord_global global = weston_coord_surface_to_global(view, local);
            notify_motion_absolute(&d->seat, &now, global);
            notify_pointer_frame(&d->seat);
            struct weston_pointer *pointer = weston_seat_get_pointer(&d->seat);
            snprintf(response, sizeof(response),
                     "{\"ok\":true,\"focused\":%s,\"width\":%d,\"height\":%d,\"time_ns\":%lld}\n",
                     pointer->focus == view ? "true" : "false", geometry.width, geometry.height,
                     (long long)now.tv_sec * 1000000000 + now.tv_nsec);
            goto reply;
        }
        snprintf(response, sizeof(response), "{\"ok\":true,\"width\":%d,\"height\":%d,\"time_ns\":%lld}\n", geometry.width, geometry.height, (long long)now.tv_sec * 1000000000 + now.tv_nsec);
    } else if (!strcmp(op, "scale") && sscanf(input, "%*s %u", &state) == 1 && state >= 1 && state <= 2) {
        struct weston_output *output = weston_compositor_find_output_by_name(d->compositor, "headless");
        if (!output) goto reply;
        weston_output_set_scale(output, (int32_t)state);
        snprintf(response, sizeof(response), "{\"ok\":true,\"scale\":%u}\n", state);
    } else if ((!strcmp(op, "key") || !strcmp(op, "button")) && sscanf(input, "%*s %u %u", &code, &state) == 2 && state <= 1) {
        if (!strcmp(op, "key")) {
            if (code > 255) goto reply;
            notify_key(&d->seat, &now, code, state, STATE_UPDATE_AUTOMATIC);
        } else {
            if (code < 272 || code > 276) goto reply;
            notify_button(&d->seat, &now, code, state);
            notify_pointer_frame(&d->seat);
        }
        snprintf(response, sizeof(response), "{\"ok\":true,\"time_ns\":%lld}\n", (long long)now.tv_sec * 1000000000 + now.tv_nsec);
    }
reply:
    /* The app's frame barrier must see these events before the driver can release
       the held input. A reply on this separate socket alone does not order them. */
    wl_display_flush_clients(d->compositor->wl_display);
    (void)send(fd, response, strlen(response), MSG_NOSIGNAL);
    dispose(p);
    return 0;
}
static int accept_peer(int fd, uint32_t mask, void *data) {
    (void)mask;
    struct driver *d = data;
    int slot;
    for (slot = 0; slot < 8 && d->peers[slot]; slot++);
    int client = accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (client < 0) return 0;
    if (slot == 8) { close(client); return 0; }
    struct peer *p = calloc(1, sizeof(*p));
    if (!p) { close(client); return 0; }
    p->fd = client; p->slot = slot; p->driver = d;
    struct wl_event_loop *loop = wl_display_get_event_loop(d->compositor->wl_display);
    p->source = wl_event_loop_add_fd(loop, client, WL_EVENT_READABLE, receive, p);
    p->timer = wl_event_loop_add_timer(loop, expired, p);
    if (!p->source || !p->timer) {
        if (p->source) wl_event_source_remove(p->source);
        if (p->timer) wl_event_source_remove(p->timer);
        close(client); free(p); return 0;
    }
    d->peers[slot] = p;
    wl_event_source_timer_update(p->timer, 2000);
    return 0;
}
static void destroy(struct wl_listener *listener, void *data) {
    (void)data;
    struct driver *d = wl_container_of(listener, d, destroy);
    for (int i = 0; i < 8; i++) if (d->peers[i]) dispose(d->peers[i]);
    wl_event_source_remove(d->listener);
    wl_list_remove(&d->destroy.link);
    weston_seat_release(&d->seat);
    close(d->fd); unlink(d->path); free(d);
}
__attribute__((visibility("default")))
int wet_module_init(struct weston_compositor *compositor, int *argc, char *argv[]) {
    (void)argc; (void)argv;
    int major, minor, micro;
    weston_version(&major, &minor, &micro);
    if (major != 15) return -1;
    const char *path = getenv("ZRCT_DESKTOP_SOCKET");
    if (!path || strlen(path) >= 108) return -1;
    struct driver *d = calloc(1, sizeof(*d));
    if (!d) return -1;
    d->compositor = compositor;
    strcpy(d->path, path);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strcpy(address.sun_path, path);
    d->fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (d->fd < 0 || bind(d->fd, (struct sockaddr *)&address, sizeof(address)) || listen(d->fd, 8)) {
        if (d->fd >= 0) close(d->fd);
        free(d); return -1;
    }
    chmod(path, 0600);
    weston_seat_init(&d->seat, compositor, "zrct");
    if (weston_seat_init_pointer(&d->seat) || weston_seat_init_keyboard(&d->seat, NULL)) {
        weston_seat_release(&d->seat); close(d->fd); unlink(path); free(d); return -1;
    }
    d->listener = wl_event_loop_add_fd(wl_display_get_event_loop(compositor->wl_display), d->fd, WL_EVENT_READABLE, accept_peer, d);
    if (!d->listener) { weston_seat_release(&d->seat); close(d->fd); unlink(path); free(d); return -1; }
    d->destroy.notify = destroy;
    wl_signal_add(&compositor->destroy_signal, &d->destroy);
    if (zrct_weston_scale_init(compositor) < 0) { destroy(&d->destroy, NULL); return -1; }
    return 0;
}
