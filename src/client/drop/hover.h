#include "drop.h"

static void zcDropEnter(void* userData, struct wl_data_device* device,
                        uint32_t serial, struct wl_surface* surface,
                        wl_fixed_t x, wl_fixed_t y, struct wl_data_offer* offer)
{
    zc_drop_set_hovered(0);
    dataDeviceHandleEnter(userData, device, serial, surface, x, y, offer);
    zc_drop_set_hovered(_glfw.wl.dragOffer != NULL);
}

static void zcDropLeave(void* userData, struct wl_data_device* device)
{
    zc_drop_set_hovered(0);
    dataDeviceHandleLeave(userData, device);
}

static void zcDropFinish(void* userData, struct wl_data_device* device)
{
    zc_drop_set_hovered(0);
    dataDeviceHandleDrop(userData, device);
}

const struct wl_data_device_listener dataDeviceListener =
{
    dataDeviceHandleDataOffer,
    zcDropEnter,
    zcDropLeave,
    dataDeviceHandleMotion,
    zcDropFinish,
    dataDeviceHandleSelection,
};

