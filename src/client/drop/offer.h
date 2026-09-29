#include "drop.h"

// File managers send a small URI list here; original file I/O runs separately.
// Bound a stalled or oversized offer before handing paths to the application.
static char* readDropOffer(struct wl_data_offer* offer)
{
    int fds[2];
    if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) == -1) { zc_drop_reject(); return NULL; }
    char* text = _glfw_calloc(ZC_DROP_BYTES + 2, 1);
    if (!text) { close(fds[0]); close(fds[1]); zc_drop_reject(); return NULL; }
    // The receiving end is nonblocking; keep the sender's normal pipe behavior.
    fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) & ~O_NONBLOCK);
    wl_data_offer_receive(offer, "text/uri-list", fds[1]);
    flushDisplay();
    close(fds[1]);
    const uint64_t started = _glfwPlatformGetTimerValue();
    const uint64_t frequency = _glfwPlatformGetTimerFrequency();
    size_t length = 0;
    for (;;)
    {
        const double elapsed = (double)(_glfwPlatformGetTimerValue() - started) / frequency;
        if (elapsed >= 2.0) break;
        struct pollfd ready = { .fd = fds[0], .events = POLLIN };
        int status = poll(&ready, 1, (int)((2.0 - elapsed) * 1000));
        if (status < 0 && errno == EINTR) continue;
        if (status <= 0) break;
        ssize_t n = read(fds[0], text + length, ZC_DROP_BYTES + 1 - length);
        if (n == 0) { close(fds[0]); text[length] = 0; return text; }
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n < 0 || memchr(text + length, 0, (size_t)n)) break;
        length += (size_t)n;
        if (length > ZC_DROP_BYTES) break;
    }
    close(fds[0]);
    _glfw_free(text);
    zc_drop_reject();
    return NULL;
}

