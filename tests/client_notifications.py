#!/usr/bin/env python3
"""Exercise the production backend on an isolated freedesktop notification bus.

Requires a C compiler, pkg-config, dbus-run-session and Python GObject bindings.
No notifications are sent to the user's desktop.
"""
import ctypes
import os
from pathlib import Path
import shlex
import subprocess
import socket
import sqlite3
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
if '--session' not in sys.argv:
    with tempfile.TemporaryDirectory(prefix='zimbr-notification-bus-') as temporary:
        config = Path(temporary) / 'session.conf'
        # Exclude the host's service directories so auto-activation cannot start
        # its real notification daemon on our private bus.
        config.write_text('''<busconfig><type>session</type><listen>unix:tmpdir=/tmp</listen>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>
<allow own="*"/></policy></busconfig>''')
        raise SystemExit(subprocess.call(['dbus-run-session', '--config-file', str(config), '--', sys.executable, __file__, '--session', *sys.argv[1:]]))

from gi.repository import Gio, GLib

XML = '''<node><interface name="org.freedesktop.Notifications">
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="Notify">
<arg type="s" direction="in"/><arg type="u" direction="in"/>
<arg type="s" direction="in"/><arg type="s" direction="in"/>
<arg type="s" direction="in"/><arg type="as" direction="in"/>
<arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
<arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
<signal name="ActivationToken"><arg type="u"/><arg type="s"/></signal>
<signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
</interface></node>'''
SERVICE = 'org.freedesktop.Notifications'
OBJECT = '/org/freedesktop/Notifications'


def main():
    with tempfile.TemporaryDirectory(prefix='zimbr-notifications-') as temporary:
        library = Path(temporary) / 'notifications.so'
        flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gio-2.0'], text=True))
        subprocess.run([os.environ.get('CC', 'cc'), '-shared', '-fPIC', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'src/client/notifications.c'), '-o', str(library), *flags], check=True)
        native = ctypes.CDLL(str(library))
        callback_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p)
        native.zc_notifications_new.argtypes = [callback_type, ctypes.c_void_p]
        native.zc_notifications_new.restype = ctypes.c_void_p
        native.zc_notifications_show.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
        native.zc_notifications_dismiss.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        native.zc_notifications_free.argtypes = [ctypes.c_void_p]
        received, closed, actions, held = [], [], [], []
        capabilities = ['body', 'body-markup', 'actions']
        stall = False
        caps_calls = 0
        next_id = 0

        def pump(seconds=.1):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                native.zc_notifications_poll()
                time.sleep(.001)

        def until(predicate, timeout=4):
            end = time.monotonic() + timeout
            while not predicate():
                assert time.monotonic() < end, 'notification operation timed out'
                pump(.005)

        def method(bus, sender, path, interface, name, parameters, invocation):
            nonlocal next_id, caps_calls
            if name == 'GetCapabilities':
                caps_calls += 1
                invocation.return_value(GLib.Variant('(as)', (capabilities,)))
            elif name == 'Notify':
                next_id += 1
                received.append((next_id, parameters.unpack()))
                if stall:
                    held.append((next_id, invocation))
                else:
                    invocation.return_value(GLib.Variant('(u)', (next_id,)))
            else:
                closed.append(parameters.unpack()[0])
                invocation.return_value(GLib.Variant('()', ()))

        def connection():
            return Gio.DBusConnection.new_for_address_sync(
                os.environ['DBUS_SESSION_BUS_ADDRESS'],
                Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
                None, None)

        bus = connection()
        info = Gio.DBusNodeInfo.new_for_xml(XML)
        bus.register_object(OBJECT, info.interfaces[0], method, None, None)

        def name_call(name):
            signature, args = ('(su)', (SERVICE, 0)) if name == 'RequestName' else ('(s)', (SERVICE,))
            return bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                                 name, GLib.Variant(signature, args), GLib.VariantType.new('(u)'),
                                 Gio.DBusCallFlags.NONE, 1000, None)

        @callback_type
        def clicked(context, chat, token):
            actions.append((chat.decode(), token.decode()))

        client = native.zc_notifications_new(clicked, None)
        try:
            # No daemon: construction, polling and submission stay responsive.
            pump()
            native.zc_notifications_show(client, b'absent', b'Absent', b'No daemon')
            pump()
            assert not received
            name_call('RequestName')
            until(lambda: len(received) == 1)
            native.zc_notifications_show(client, b'chat', 'Friends 👋'.encode(), b'<b>literal</b> & "quoted"')
            until(lambda: len(received) == 2)
            ident, values = received[-1]
            app, replaces, icon, title, body, buttons, hints, timeout = values
            assert (app, replaces, icon, title, timeout) == ('Zimbr', 0, 'zimbr', 'Friends 👋', -1)
            assert body == '&lt;b&gt;literal&lt;/b&gt; &amp; &quot;quoted&quot;'
            assert buttons == ['default', 'Open conversation']
            assert hints == {'desktop-entry': 'zimbr', 'category': 'im.received', 'urgency': 1}
            pump()

            def signal(source, name, signature, args):
                source.emit_signal(None, OBJECT, SERVICE, name, GLib.Variant(signature, args))

            # Ignore forged actions from another session-bus peer.
            stranger = connection()
            signal(stranger, 'ActionInvoked', '(us)', (ident, 'default'))
            pump()
            assert not actions
            signal(bus, 'ActivationToken', '(us)', (ident, 'wayland-token'))
            signal(bus, 'ActionInvoked', '(us)', (ident, 'default'))
            until(lambda: actions)
            assert actions == [('chat', 'wayland-token')]
            native.zc_notifications_dismiss(client, b'chat')
            until(lambda: ident in closed)
            signal(bus, 'ActionInvoked', '(us)', (ident, 'default'))
            pump()
            assert len(actions) == 1

            # Replacement and closure do not retain stale action mappings.
            native.zc_notifications_show(client, b'replace', b'First', b'one')
            until(lambda: len(received) == 3)
            previous = received[-1][0]
            pump()
            native.zc_notifications_show(client, b'replace', b'Second', b'two')
            until(lambda: len(received) == 4 and previous in closed)
            latest = received[-1][0]
            pump()
            signal(bus, 'NotificationClosed', '(uu)', (latest, 2))
            signal(bus, 'ActionInvoked', '(us)', (latest, 'default'))
            pump()
            assert len(actions) == 1

            # A restarted daemon can recycle IDs and offer fewer capabilities.
            name_call('ReleaseName')
            pump()
            capabilities[:] = ['body']
            name_call('RequestName')
            until(lambda: caps_calls == 2)
            pump()
            native.zc_notifications_show(client, b'plain', b'Plain', b'<literal> & text')
            until(lambda: len(received) == 5)
            values = received[-1][1]
            assert values[4] == '<literal> & text' and values[5] == []

            # A slow daemon cannot block the UI; reading before a reply closes
            # the returned ID instead of retaining an actionable stale alert.
            stall = True
            start = time.monotonic()
            native.zc_notifications_show(client, b'slow', b'Slow', b'body')
            until(lambda: held)
            assert time.monotonic() - start < .5
            native.zc_notifications_dismiss(client, b'slow')
            slow_id, invocation = held.pop()
            invocation.return_value(GLib.Variant('(u)', (slow_id,)))
            until(lambda: slow_id in closed)
            native.zc_notifications_show(client, b'timeout', b'Timeout', b'body')
            until(lambda: held)
            pump(2.2)
            # Shutdown while an async request remains in flight is safe.
            native.zc_notifications_show(client, b'exit', b'Exit', b'body')
            until(lambda: len(held) == 2)
        finally:
            native.zc_notifications_free(client)
            for ident, invocation in held:
                invocation.return_value(GLib.Variant('(u)', (ident,)))
            pump()
            if '--gui' in sys.argv:
                stall = False
                capabilities[:] = ['body', 'body-markup', 'actions']
                gui_smoke(Path(temporary), pump, until, received, bus)
            bus.close_sync(None)
        print('PASS: freedesktop payload, escaping, actions/tokens, dismissal, daemon absence/restart, timeout and shutdown')


def gui_smoke(root, pump, until, received, bus):
    """Actual relay -> worker -> Wayland GUI -> D-Bus, then click -> conversation."""
    from fixture import create, add_message
    from relay_fixture import Fixture
    source, client = root / 'source.db', root / 'client'
    create(source, count=8)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    tls = Fixture(root, port)
    args = ['--data-dir', str(root / 'relay'), '--messages-db', str(source), '--config', str(tls.config)]
    binary = ROOT / 'zig-out/bin'
    subprocess.run([str(binary / 'fake-relay'), 'setup', *args], check=True, capture_output=True)
    env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'), WAYLAND_DEBUG='client')
    gui = None

    def rows(sql):
        try:
            with sqlite3.connect(client / 'client.db') as db:
                return db.execute(sql).fetchall()
        except sqlite3.OperationalError:
            return []

    with (root / 'gui.log').open('w+') as log:
        relay = subprocess.Popen([str(binary / 'fake-relay'), 'serve', *args], stdout=log, stderr=log)
        def start():
            return subprocess.Popen([str(binary / 'zimbr'), '--details', '--data-dir', str(client), *tls.client_args()], env=env, stdout=log, stderr=log)
        try:
            baseline = len(received)
            gui = start()
            until(lambda: rows("SELECT value FROM meta WHERE key='bootstrapped'") == [('1',)], timeout=20)
            pump(.5)
            assert gui.poll() is None and len(received) == baseline, 'Historical startup generated an alert'
            with sqlite3.connect(source) as db:
                add_message(db, 'Notification integration <hello> 👋', chat=2)
            until(lambda: len(received) > baseline, timeout=20)
            ident, notification = received[-1]
            assert notification[3] == 'Fixture group'
            assert notification[4] == 'Notification integration &lt;hello&gt; 👋'
            pump()
            bus.emit_signal(None, OBJECT, SERVICE, 'ActivationToken', GLib.Variant('(us)', (ident, 'fixture-activation-token')))
            bus.emit_signal(None, OBJECT, SERVICE, 'ActionInvoked', GLib.Variant('(us)', (ident, 'default')))
            until(lambda: rows("SELECT json_extract(record,'$.title') FROM records WHERE kind='conversation' AND id=(SELECT value FROM meta WHERE key='selected')") == [('Fixture group',)])
            pump()
            log.flush()
            trace = (root / 'gui.log').read_text()
            assert 'xdg_activation_v1' in trace and 'activate("fixture-activation-token"' in trace, 'Missing Wayland activation request'
            gui.terminate()
            gui.wait(timeout=5)
            baseline = len(received)
            gui = start()
            pump(2)
            assert gui.poll() is None and len(received) == baseline, 'Restart replayed an alert'
        finally:
            for process in (gui, relay):
                if process and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
    print('PASS: native relay -> Wayland GUI -> notification -> conversation/activation; restart stays quiet')


if __name__ == '__main__':
    main()
