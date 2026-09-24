#include "bridge.h"
#include <gio/gio.h>
#include <string.h>

/* All entry points and callbacks run on the UI thread. No synchronous D-Bus
 * calls: an absent or stalled daemon must not stall rendering or message sync. */
#define SERVICE "org.freedesktop.Notifications"
#define OBJECT "/org/freedesktop/Notifications"
#define LIMIT 64
typedef struct {
    char *chat, *summary, *body, *token;
    guint id;
    guint64 serial;
    gboolean pending;
} Notice;
struct ZcNotifications {
    guint refs, watch, subscription;
    guint64 serial, generation;
    gboolean stopped, ready, actions, markup;
    GDBusConnection *bus;
    GCancellable *cancel;
    char *owner;
    Notice notices[LIMIT];
    ZcNotificationAction action;
    void *context;
};
typedef struct {
    ZcNotifications *n;
    guint64 generation, serial;
    guint slot;
} Call;
static void clear_notice(Notice *v) {
    g_free(v->chat); g_free(v->summary); g_free(v->body); g_free(v->token);
    memset(v, 0, sizeof(*v));
}
static void release(ZcNotifications *n) {
    if (--n->refs) return;
    g_clear_object(&n->bus);
    g_clear_object(&n->cancel);
    g_free(n->owner);
    for (guint i = 0; i < LIMIT; ++i) clear_notice(&n->notices[i]);
    g_free(n);
}
static Call *new_call(ZcNotifications *n, guint slot) {
    Call *c = g_new0(Call, 1);
    c->n = n; ++n->refs;
    c->generation = n->generation;
    c->slot = slot;
    c->serial = n->notices[slot].serial;
    return c;
}
static void close_id(ZcNotifications *n, guint id) {
    if (id && n->bus && n->owner)
        g_dbus_connection_call(n->bus, n->owner, OBJECT, SERVICE,
            "CloseNotification", g_variant_new("(u)", id), NULL,
            G_DBUS_CALL_FLAGS_NONE, 2000, NULL, NULL, NULL);
}
static void notified(GObject *object, GAsyncResult *result, gpointer data) {
    Call *c = data;
    ZcNotifications *n = c->n;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), result, NULL);
    if (reply) {
        guint id = 0;
        g_variant_get(reply, "(u)", &id);
        if (!n->stopped && c->generation == n->generation) {
            Notice *v = &n->notices[c->slot];
            if (v->chat && v->serial == c->serial) v->id = id;
            else close_id(n, id); /* Read or evicted while Notify was in flight. */
        }
        g_variant_unref(reply);
    } else if (c->generation == n->generation && n->notices[c->slot].serial == c->serial) {
        clear_notice(&n->notices[c->slot]);
    }
    release(n); g_free(c);
}
static void send_notice(ZcNotifications *n, guint slot) {
    Notice *v = &n->notices[slot];
    if (!n->ready || !v->chat || !v->pending) return;
    v->pending = FALSE;
    GVariantBuilder hints, actions;
    g_variant_builder_init(&hints, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&hints, "{sv}", "desktop-entry", g_variant_new_string("zimbr"));
    g_variant_builder_add(&hints, "{sv}", "category", g_variant_new_string("im.received"));
    g_variant_builder_add(&hints, "{sv}", "urgency", g_variant_new_byte(1));
    g_variant_builder_init(&actions, G_VARIANT_TYPE_STRING_ARRAY);
    if (n->actions) {
        g_variant_builder_add(&actions, "s", "default");
        g_variant_builder_add(&actions, "s", "Open conversation");
    }
    char *body = n->markup ? g_markup_escape_text(v->body, -1) : g_strdup(v->body);
    g_dbus_connection_call(n->bus, n->owner, OBJECT, SERVICE, "Notify",
        g_variant_new("(susssasa{sv}i)", "Zimbr", 0u, "zimbr", v->summary,
                      body, &actions, &hints, -1),
        G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 2000, n->cancel,
        notified, new_call(n, slot));
    g_free(body);
}
static void capabilities(GObject *object, GAsyncResult *result, gpointer data) {
    Call *c = data;
    ZcNotifications *n = c->n;
    GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), result, NULL);
    if (!n->stopped && c->generation == n->generation) {
        n->actions = n->markup = FALSE;
        if (reply) {
            char **caps;
            g_variant_get(reply, "(^as)", &caps);
            n->actions = g_strv_contains((const char *const *)caps, "actions");
            n->markup = g_strv_contains((const char *const *)caps, "body-markup");
            g_strfreev(caps);
        }
        n->ready = TRUE;
        for (guint i = 0; i < LIMIT; ++i) send_notice(n, i);
    }
    if (reply) g_variant_unref(reply);
    release(n); g_free(c);
}
static void signal_received(GDBusConnection *bus, const char *sender, const char *path,
                            const char *interface, const char *signal, GVariant *parameters, gpointer data) {
    (void)bus; (void)path; (void)interface;
    ZcNotifications *n = data;
    if (n->stopped || g_strcmp0(sender, n->owner)) return;
    guint id;
    const char *value = NULL;
    if (!strcmp(signal, "NotificationClosed")) {
        if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(uu)"))) return;
        guint reason;
        g_variant_get(parameters, "(uu)", &id, &reason);
    } else if (!strcmp(signal, "ActivationToken") || !strcmp(signal, "ActionInvoked")) {
        if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(us)"))) return;
        g_variant_get(parameters, "(u&s)", &id, &value);
    } else return;
    for (guint i = 0; i < LIMIT; ++i) {
        Notice *v = &n->notices[i];
        if (!v->chat || !id || v->id != id) continue;
        if (!strcmp(signal, "ActivationToken")) {
            g_free(v->token); v->token = g_strdup(value);
        } else if (!strcmp(signal, "ActionInvoked")) {
            if (!strcmp(value, "default") && n->action) {
                /* The callback may dismiss this notice while selecting a chat. */
                char *chat = g_strdup(v->chat), *token = g_strdup(v->token);
                n->action(n->context, chat, token ? token : "");
                g_free(chat); g_free(token);
            }
        } else clear_notice(v);
        break;
    }
}
static void appeared(GDBusConnection *bus, const char *name, const char *owner, gpointer data) {
    (void)name;
    ZcNotifications *n = data;
    ++n->generation;
    n->ready = FALSE;
    g_set_object(&n->bus, bus);
    g_free(n->owner); n->owner = g_strdup(owner);
    n->subscription = g_dbus_connection_signal_subscribe(bus, owner, SERVICE, NULL,
        OBJECT, NULL, G_DBUS_SIGNAL_FLAGS_NONE, signal_received, n, NULL);
    g_dbus_connection_call(bus, owner, OBJECT, SERVICE, "GetCapabilities", NULL,
        G_VARIANT_TYPE("(as)"), G_DBUS_CALL_FLAGS_NONE, 2000, n->cancel,
        capabilities, new_call(n, 0));
}
static void vanished(GDBusConnection *bus, const char *name, gpointer data) {
    (void)bus; (void)name;
    ZcNotifications *n = data;
    ++n->generation;
    n->ready = FALSE;
    if (n->subscription) g_dbus_connection_signal_unsubscribe(n->bus, n->subscription);
    n->subscription = 0;
    g_clear_pointer(&n->owner, g_free);
    for (guint i = 0; i < LIMIT; ++i) clear_notice(&n->notices[i]);
}
ZcNotifications *zc_notifications_new(ZcNotificationAction action, void *context) {
    ZcNotifications *n = g_new0(ZcNotifications, 1);
    n->refs = 1; n->action = action; n->context = context;
    n->cancel = g_cancellable_new();
    n->watch = g_bus_watch_name(G_BUS_TYPE_SESSION, SERVICE, G_BUS_NAME_WATCHER_FLAGS_AUTO_START,
                               appeared, vanished, n, NULL);
    return n;
}
void zc_notifications_poll(void) {
    /* Bound dispatch work even if a bus peer produces a signal storm. */
    for (int i = 0; i < 64 && g_main_context_iteration(NULL, FALSE); ++i) {}
}
void zc_notifications_dismiss(ZcNotifications *n, const char *chat) {
    if (!n) return;
    for (guint i = 0; i < LIMIT; ++i) {
        Notice *v = &n->notices[i];
        if (v->chat && !strcmp(v->chat, chat)) {
            close_id(n, v->id);
            clear_notice(v);
        }
    }
}
void zc_notifications_show(ZcNotifications *n, const char *chat, const char *summary, const char *body) {
    if (!n || !g_utf8_validate(chat, -1, NULL) || !g_utf8_validate(summary, -1, NULL) || !g_utf8_validate(body, -1, NULL)) return;
    /* Keep at most one current alert per conversation, including queued calls. */
    zc_notifications_dismiss(n, chat);
    guint slot = 0;
    for (guint i = 0; i < LIMIT; ++i) {
        if (!n->notices[i].chat) { slot = i; break; }
        if (n->notices[i].serial < n->notices[slot].serial) slot = i;
    }
    Notice *v = &n->notices[slot];
    close_id(n, v->id);
    clear_notice(v);
    v->chat = g_strdup(chat); v->summary = g_strdup(summary); v->body = g_strdup(body);
    v->serial = ++n->serial; v->pending = TRUE;
    send_notice(n, slot);
}
void zc_notifications_free(ZcNotifications *n) {
    if (!n) return;
    n->stopped = TRUE;
    g_bus_unwatch_name(n->watch);
    if (n->subscription) g_dbus_connection_signal_unsubscribe(n->bus, n->subscription);
    for (guint i = 0; i < LIMIT; ++i) close_id(n, n->notices[i].id);
    g_cancellable_cancel(n->cancel);
    release(n);
}
