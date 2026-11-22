/* Surface scale notifications for the single-output Weston 15 headless profile.
 * Weston already implements wp_viewporter, but not fractional-scale-v1. SDL3
 * uses this protocol to update mapped windows when the output scale changes.
 * Only actual integer output scales are advertised; this adds no fractional
 * output configuration or application-side scaling workaround.
 */
#include <libweston/libweston.h>
#include <stdlib.h>
#include "fractional-scale-v1-server-protocol.h"

struct scale_manager {
    struct weston_output *output;
    struct wl_global *global;
    struct wl_list surfaces;
    struct wl_listener resized, destroy;
};

struct surface_scale {
    struct scale_manager *manager;
    struct weston_surface *surface;
    struct wl_resource *resource;
    struct wl_list link;
    struct wl_listener destroy;
};

static void destroy_resource(struct wl_client *client, struct wl_resource *resource) {
    (void)client;
    wl_resource_destroy(resource);
}

static void surface_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct surface_scale *scale = wl_container_of(listener, scale, destroy);
    wl_list_remove(&scale->destroy.link);
    scale->surface = NULL;
}

static void scale_destroyed(struct wl_resource *resource) {
    struct surface_scale *scale = wl_resource_get_user_data(resource);
    if (scale->surface) wl_list_remove(&scale->destroy.link);
    wl_list_remove(&scale->link);
    free(scale);
}

static const struct wp_fractional_scale_v1_interface scale_implementation = {
    .destroy = destroy_resource,
};

static void send_scale(struct surface_scale *scale) {
    if (scale->surface)
        wp_fractional_scale_v1_send_preferred_scale(scale->resource,
            (uint32_t)scale->manager->output->current_scale * 120);
}

static void get_scale(struct wl_client *client, struct wl_resource *resource,
                      uint32_t id, struct wl_resource *surface_resource) {
    struct scale_manager *manager = wl_resource_get_user_data(resource);
    struct weston_surface *surface = wl_resource_get_user_data(surface_resource);
    struct surface_scale *scale;
    wl_list_for_each(scale, &manager->surfaces, link) {
        if (scale->surface == surface) {
            wl_resource_post_error(resource,
                WP_FRACTIONAL_SCALE_MANAGER_V1_ERROR_FRACTIONAL_SCALE_EXISTS,
                "surface already has a fractional scale object");
            return;
        }
    }
    scale = calloc(1, sizeof(*scale));
    if (!scale) { wl_client_post_no_memory(client); return; }
    scale->resource = wl_resource_create(client, &wp_fractional_scale_v1_interface, 1, id);
    if (!scale->resource) { free(scale); wl_client_post_no_memory(client); return; }
    scale->manager = manager;
    scale->surface = surface;
    scale->destroy.notify = surface_destroyed;
    wl_signal_add(&surface->destroy_signal, &scale->destroy);
    wl_list_insert(&manager->surfaces, &scale->link);
    wl_resource_set_implementation(scale->resource, &scale_implementation, scale, scale_destroyed);
    send_scale(scale);
}

static const struct wp_fractional_scale_manager_v1_interface manager_implementation = {
    .destroy = destroy_resource,
    .get_fractional_scale = get_scale,
};

static void bind_manager(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *resource = wl_resource_create(client,
        &wp_fractional_scale_manager_v1_interface, version, id);
    if (!resource) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(resource, &manager_implementation, data, NULL);
}

static void output_resized(struct wl_listener *listener, void *data) {
    struct scale_manager *manager = wl_container_of(listener, manager, resized);
    if (data != manager->output) return;
    struct surface_scale *scale;
    wl_list_for_each(scale, &manager->surfaces, link) send_scale(scale);
}

static void manager_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct scale_manager *manager = wl_container_of(listener, manager, destroy);
    struct surface_scale *scale, *next;
    wl_list_for_each_safe(scale, next, &manager->surfaces, link)
        wl_resource_destroy(scale->resource);
    wl_global_destroy(manager->global);
    wl_list_remove(&manager->resized.link);
    wl_list_remove(&manager->destroy.link);
    free(manager);
}

int zrct_weston_scale_init(struct weston_compositor *compositor) {
    struct weston_output *output = weston_compositor_find_output_by_name(compositor, "headless");
    /* The nested/display profile has no controllable headless output. */
    if (!output || wl_list_length(&compositor->output_list) != 1) return 0;
    struct scale_manager *manager = calloc(1, sizeof(*manager));
    if (!manager) return -1;
    manager->output = output;
    wl_list_init(&manager->surfaces);
    manager->global = wl_global_create(compositor->wl_display,
        &wp_fractional_scale_manager_v1_interface, 1, manager, bind_manager);
    if (!manager->global) { free(manager); return -1; }
    manager->resized.notify = output_resized;
    wl_signal_add(&compositor->output_resized_signal, &manager->resized);
    manager->destroy.notify = manager_destroyed;
    wl_signal_add(&compositor->destroy_signal, &manager->destroy);
    return 0;
}
