#include <wayland-client.h>
#include <string.h>
#include "xdg-activation-v1-client-protocol.h"

/* GLFW owns dispatch and the display. Bind asynchronously on that same queue;
 * never roundtrip or dispatch a second connection to activate its surface. */
extern struct wl_display *glfwGetWaylandDisplay(void);
static struct wl_registry *registry;
static struct xdg_activation_v1 *activation;
static uint32_t activation_name;
static void global(void *data, struct wl_registry *reg, uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "xdg_activation_v1") && !activation) {
        activation = wl_registry_bind(reg, name, &xdg_activation_v1_interface, 1);
        activation_name = name;
    }
}
static void removed(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg;
    if (activation && name == activation_name) {
        xdg_activation_v1_destroy(activation);
        activation = NULL;
    }
}
static const struct wl_registry_listener listener = { global, removed };
void zc_activation_init(void) {
    struct wl_display *display = glfwGetWaylandDisplay();
    if (!display) return;
    registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &listener, NULL);
    wl_display_flush(display);
}
int zc_activation_activate(void *surface, const char *token) {
    if (!activation || !surface || !token || !*token) return 0;
    xdg_activation_v1_activate(activation, token, surface);
    wl_display_flush(glfwGetWaylandDisplay());
    return 1;
}
void zc_activation_free(void) {
    if (activation) xdg_activation_v1_destroy(activation);
    if (registry) wl_registry_destroy(registry);
    activation = NULL; registry = NULL;
}
