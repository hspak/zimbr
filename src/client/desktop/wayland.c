#define _GNU_SOURCE
#include "desktop.h"
#include "drop.h"
#include "xdg-activation-v1-client-protocol.h"
#include <SDL3/SDL.h>
#include <wayland-client.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

/* SDL owns dispatch and the display. Bind on its default queue without a
 * roundtrip or a second connection. A separate data device retains raw URIs;
 * SDL's file/text drop events must be disabled before this device is created. */
static SDL_Window *window;
static struct wl_display *display;
static struct wl_registry *registry;
static struct xdg_activation_v1 *activation;
static uint32_t activation_name, manager_name, seat_name;
static struct wl_data_device_manager *manager;
static struct wl_seat *seat;
static struct wl_data_device *device;
typedef struct Offer {
    struct Offer *next;
    struct wl_data_offer *proxy;
    int uris;
    uint32_t action;
} Offer;
static Offer *offers, *drag;

/* The UI owns at most one nonblocking transfer. The offer outlives drag leave
 * until EOF, rejection, timeout or shutdown releases it. */
static struct {
    Offer *offer;
    int fd;
    char *text;
    size_t length;
    Uint64 deadline;
} transfer = { .fd = -1 };

static void destroy_offer(Offer *offer) {
    if (!offer) return;
    for (Offer **p = &offers; *p; p = &(*p)->next) {
        if (*p == offer) { *p = offer->next; break; }
    }
    if (drag == offer) drag = NULL;
    wl_data_offer_destroy(offer->proxy);
    free(offer);
}
static void mime(void *data, struct wl_data_offer *proxy, const char *type) {
    (void)proxy;
    if (!strcmp(type, "text/uri-list")) ((Offer *)data)->uris = 1;
}
static void source_actions(void *data, struct wl_data_offer *proxy, uint32_t actions) {
    (void)data; (void)proxy; (void)actions;
}
static void action(void *data, struct wl_data_offer *proxy, uint32_t selected) {
    (void)proxy;
    ((Offer *)data)->action = selected;
}
static const struct wl_data_offer_listener offer_listener = { mime, source_actions, action };
static void offered(void *data, struct wl_data_device *dev, struct wl_data_offer *proxy) {
    (void)data; (void)dev;
    size_t count = 0;
    for (Offer *p = offers; p; p = p->next) count++;
    // Bound unclassified offers as well as accepted payloads.
    Offer *offer = count < 32 ? calloc(1, sizeof(*offer)) : NULL;
    if (!offer) { wl_data_offer_destroy(proxy); zc_drop_reject(); return; }
    offer->proxy = proxy;
    offer->next = offers;
    offers = offer;
    wl_data_offer_add_listener(proxy, &offer_listener, offer);
}
static void enter(void *data, struct wl_data_device *dev, uint32_t serial,
                  struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y,
                  struct wl_data_offer *proxy) {
    (void)data; (void)dev; (void)x; (void)y;
    destroy_offer(drag);
    zc_drop_set_hovered(0);
    if (!proxy) return;
    Offer *offer = wl_data_offer_get_user_data(proxy);
    void *own_surface = SDL_GetPointerProperty(SDL_GetWindowProperties(window),
        SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, NULL);
    const int accept = offer && offer->uris && surface == own_surface;
    wl_data_offer_accept(proxy, serial, accept ? "text/uri-list" : NULL);
    if (wl_data_offer_get_version(proxy) >= 3)
        wl_data_offer_set_actions(proxy, accept ? WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY : 0,
                                  accept ? WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY : 0);
    drag = offer;
    zc_drop_set_hovered(accept);
}
static void leave(void *data, struct wl_data_device *dev) {
    (void)data; (void)dev;
    zc_drop_set_hovered(0);
    destroy_offer(drag);
}
static void motion(void *data, struct wl_data_device *dev, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    (void)data; (void)dev; (void)time; (void)x; (void)y;
}
static void finish_transfer(int complete) {
    if (!transfer.offer) return;
    if (complete) zc_drop_offer(transfer.text, transfer.length);
    else zc_drop_reject();
    if (wl_data_offer_get_version(transfer.offer->proxy) >= 3 &&
        transfer.offer->action == WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY)
        wl_data_offer_finish(transfer.offer->proxy);
    close(transfer.fd);
    free(transfer.text);
    destroy_offer(transfer.offer);
    memset(&transfer, 0, sizeof(transfer));
    transfer.fd = -1;
}
void zc_wayland_poll(void) {
    if (!transfer.offer) return;
    if (SDL_GetTicks() >= transfer.deadline) { finish_transfer(0); return; }
    while (transfer.length <= ZC_DROP_BYTES) {
        const ssize_t n = read(transfer.fd, transfer.text + transfer.length,
                               ZC_DROP_BYTES + 1 - transfer.length);
        if (n == 0) { finish_transfer(1); return; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && errno == EAGAIN) return;
        if (n < 0 || memchr(transfer.text + transfer.length, 0, (size_t)n)) {
            finish_transfer(0); return;
        }
        transfer.length += (size_t)n;
    }
    finish_transfer(0);
}
int zc_wayland_wait_limit(int timeout_ms) {
    // SDL owns Wayland dispatch; only an active raw pipe needs this short cadence.
    return transfer.offer && (timeout_ms < 0 || timeout_ms > 10) ? 10 : timeout_ms;
}
static void dropped(void *data, struct wl_data_device *dev) {
    (void)data; (void)dev;
    if (drag && zc_drop_hovered()) {
        int fds[2];
        char *text = NULL;
        if (transfer.offer || pipe2(fds, O_CLOEXEC | O_NONBLOCK) < 0) {
            zc_drop_reject();
        } else if (!(text = malloc(ZC_DROP_BYTES + 1))) {
            close(fds[0]); close(fds[1]); zc_drop_reject();
        } else {
            fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) & ~O_NONBLOCK);
            wl_data_offer_receive(drag->proxy, "text/uri-list", fds[1]);
            wl_display_flush(display);
            close(fds[1]);
            transfer.offer = drag;
            transfer.fd = fds[0];
            transfer.text = text;
            transfer.length = 0;
            transfer.deadline = SDL_GetTicks() + 2000;
            drag = NULL;
        }
    }
    zc_drop_set_hovered(0);
    destroy_offer(drag);
}
static void selection(void *data, struct wl_data_device *dev, struct wl_data_offer *proxy) {
    (void)data; (void)dev;
    // Clipboard ownership stays entirely in SDL.
    if (proxy) destroy_offer(wl_data_offer_get_user_data(proxy));
}
static const struct wl_data_device_listener device_listener = {
    offered, enter, leave, motion, dropped, selection,
};
static void seat_capabilities(void *data, struct wl_seat *proxy, uint32_t capabilities) {
    (void)data; (void)proxy; (void)capabilities;
}
static void seat_label(void *data, struct wl_seat *proxy, const char *name) {
    (void)data; (void)proxy; (void)name;
}
static const struct wl_seat_listener seat_listener = { seat_capabilities, seat_label };
static void bind_device(void) {
    if (manager && seat && !device) {
        device = wl_data_device_manager_get_data_device(manager, seat);
        wl_data_device_add_listener(device, &device_listener, NULL);
    }
}
static void global(void *data, struct wl_registry *reg, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, "xdg_activation_v1") && !activation) {
        activation = wl_registry_bind(reg, name, &xdg_activation_v1_interface, 1);
        activation_name = name;
    } else if (!strcmp(interface, "wl_data_device_manager") && !manager) {
        manager = wl_registry_bind(reg, name, &wl_data_device_manager_interface, version < 3 ? version : 3);
        manager_name = name;
    } else if (!strcmp(interface, "wl_seat") && !seat) {
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
        wl_seat_add_listener(seat, &seat_listener, NULL);
        seat_name = name;
    }
    bind_device();
}
static void free_device(void) {
    finish_transfer(0);
    while (offers) destroy_offer(offers);
    if (device) {
        if (wl_data_device_get_version(device) >= 2) wl_data_device_release(device);
        else wl_data_device_destroy(device);
        device = NULL;
    }
    zc_drop_set_hovered(0);
}
static void removed(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg;
    if (activation && name == activation_name) { xdg_activation_v1_destroy(activation); activation = NULL; }
    if (seat && name == seat_name) { free_device(); wl_seat_destroy(seat); seat = NULL; }
    if (manager && name == manager_name) { free_device(); wl_data_device_manager_destroy(manager); manager = NULL; }
}
static const struct wl_registry_listener registry_listener = { global, removed };
void zc_wayland_init(SDL_Window *created) {
    window = created;
    display = SDL_GetPointerProperty(SDL_GetWindowProperties(window), SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, NULL);
    if (!display) return;
    registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_flush(display);
}
int zc_desktop_activate(const char *token) {
    if (!activation || !token || !*token) return 0;
    void *surface = SDL_GetPointerProperty(SDL_GetWindowProperties(window), SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, NULL);
    if (!surface) return 0;
    xdg_activation_v1_activate(activation, token, surface);
    wl_display_flush(display);
    return 1;
}
void zc_wayland_free(void) {
    free_device();
    if (seat) wl_seat_destroy(seat);
    if (manager) wl_data_device_manager_destroy(manager);
    if (activation) xdg_activation_v1_destroy(activation);
    if (registry) wl_registry_destroy(registry);
    seat = NULL; manager = NULL; activation = NULL; registry = NULL;
    display = NULL; window = NULL;
}
