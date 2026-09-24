#define _GNU_SOURCE
#include <wayland-client.h>
#include <string.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include "xdg-activation-v1-client-protocol.h"

/* GLFW owns dispatch and the display. Bind asynchronously on that same queue;
 * never roundtrip or dispatch a second connection to activate its surface. */
extern struct wl_display *glfwGetWaylandDisplay(void);
static struct wl_registry *registry;
static struct xdg_activation_v1 *activation;
static uint32_t activation_name;
static int wake_pipe[2] = {-1, -1};
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
    // Set up before workers start; tear down only after they have joined.
    if (pipe2(wake_pipe, O_NONBLOCK | O_CLOEXEC) != 0) wake_pipe[0] = wake_pipe[1] = -1;
    struct wl_display *display = glfwGetWaylandDisplay();
    if (!display) return;
    registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &listener, NULL);
    wl_display_flush(display);
}
void zc_activation_wake(void) {
    if (wake_pipe[1] >= 0) while (write(wake_pipe[1], "v", 1) < 0 && errno == EINTR) {}
}
int zc_activation_wait(int timeout_ms) {
    struct wl_display *display = glfwGetWaylandDisplay();
    // Wait for readiness without dispatching callbacks. raylib must reset its
    // input state before GLFW dispatches; glfwWaitEvents would lose key edges.
    struct pollfd fds[2] = {{display ? wl_display_get_fd(display) : -1, POLLIN, 0},
                            {wake_pipe[0], POLLIN, 0}};
    (void)poll(fds, 2, timeout_ms);
    if (!(fds[1].revents & POLLIN)) return 0;
    char bytes[128];
    while (read(wake_pipe[0], bytes, sizeof(bytes)) > 0) {}
    return 1;
}
int zc_activation_activate(void *surface, const char *token) {
    if (!activation || !surface || !token || !*token) return 0;
    xdg_activation_v1_activate(activation, token, surface);
    wl_display_flush(glfwGetWaylandDisplay());
    return 1;
}
void zc_activation_free(void) {
    if (wake_pipe[0] >= 0) close(wake_pipe[0]);
    if (wake_pipe[1] >= 0) close(wake_pipe[1]);
    wake_pipe[0] = wake_pipe[1] = -1;
    if (activation) xdg_activation_v1_destroy(activation);
    if (registry) wl_registry_destroy(registry);
    activation = NULL; registry = NULL;
}
