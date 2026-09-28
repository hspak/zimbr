# Development setup: build a Mac relay and Linux client

For normal installation, use the [two-step package setup](setup.md).
This guide is for working on Zimbr itself.

Run commands from a checkout of the same revision on both computers. The Mac
must be signed into Messages in its graphical login session; Linux needs a
Wayland desktop. Install the Zig version in [`.zigversion`](../.zigversion)
(currently **0.16.0**) from [Zig's downloads](https://ziglang.org/download/).
Run setup as your ordinary user.

These steps use the source build's **dev** profile: port **8732**, **Zimbr Relay
Dev.app**, and separate `zimbr-dev` client state. For packaged releases, use
`release` consistently in build and administration commands, port **8731**, and
the paths in [profiles](macos-profiles.md). Optimization does not select a profile.

## 1. Build on the Mac

Install Apple's Command Line Tools (`xcode-select --install` if absent), then:

```sh
brew install mkcert python@3.14 cryptography openssl@3.5
mkdir -p .tools
"$(brew --prefix python@3.14)/bin/python3.14" -m venv .tools/python
.tools/python/bin/python3 -m pip install -r tools/requirements-tls.txt
. .tools/python/bin/activate
export ZIMBR_PYTHON="$PWD/.tools/python/bin/python3"
export ZIMBR_ZIG="$(command -v zig)"
export ZIMBR_OPENSSL_PREFIX="$(brew --prefix openssl@3.5)"
export ZIMBR_OPENSSL_LICENSE="$ZIMBR_OPENSSL_PREFIX/LICENSE.txt"
test "$(zig version)" = "$(cat .zigversion)"
test -f "$ZIMBR_OPENSSL_PREFIX/lib/libssl.a"
test -f "$ZIMBR_OPENSSL_PREFIX/lib/libcrypto.a"
test -f "$ZIMBR_OPENSSL_LICENSE"
zig build relay test test-macos-enrichment -Dprofile=dev -Doptimize=ReleaseSafe \
  -Dopenssl-prefix="$ZIMBR_OPENSSL_PREFIX"
```

Use the versioned [OpenSSL 3.5 formula](https://formulae.brew.sh/formula/openssl@3.5);
the relay requires 3.5 headers and static archives. For a custom toolchain, see
[TLS build details](macos-tls.md#build). Keep these environment overrides for
future [updates](macos-relay.md#update-the-running-relay). In a new Mac shell,
activate the environment with `. .tools/python/bin/activate` before using guides
that invoke `python3`.

## 2. Generate credentials and install on the Mac

Choose a DNS name or IP that Linux can reach **directly**, and a local Mac IP to
listen on. Replace the documentation placeholders below. The server name must
resolve to the Mac from both computers; SSH aliases do not provide that routing.
Allow the selected TCP port through the Mac/network firewall when needed.

```sh
.tools/python/bin/python3 tools/tls_admin.py setup --profile dev \
  --server-name relay.example --listen-address 192.0.2.10
.tools/python/bin/python3 packaging/macos/signing.py setup
.tools/python/bin/python3 packaging/macos/install.py --profile dev --install --start \
  --tls-config "$HOME/.config/zimbr-dev-setup/relay.json" \
  --admin-config "$HOME/.config/zimbr-dev-setup/admin.json" \
  --openssl-license "$ZIMBR_OPENSSL_LICENSE"
```

`setup` uses **mkcert** to create a dedicated CA and sign server and Mac
administrative CSRs, writes the allowlist and both configurations, and validates
them with the built relay. No JSON editing is needed. Add `--name OTHER_NAME`
for additional server identities, or `--port NUMBER` to override the profile port.
It refuses to replace existing staging credentials. After an interrupted run,
use `--directory` with a new private directory and pass its configurations to
the installer. Keep the existing CA for retries and renewal.

The issuer lives at `~/.config/zimbr-dev-ca`; **keep `rootCA-key.pem` on the Mac**.
mkcert's [`CAROOT` and CSR options](https://github.com/FiloSottile/mkcert#advanced-topics)
provide issuance. Zimbr uses explicit trust, so do not run `mkcert -install` or
reuse your general development CA. Code signing is a separate identity; approve
its one-time prompt locally on the Mac. Back up both identities privately.

The installer copies runtime credentials outside the app and starts a login
LaunchAgent. Complete the macOS permission steps:

1. Add `~/Applications/Zimbr Relay Dev.app` to **System Settings → Privacy &
   Security → Full Disk Access**.
2. Run this from the Mac's Terminal and approve Messages Automation:

   ```sh
   open -n -W -a "$HOME/Applications/Zimbr Relay Dev.app" --args doctor --check-automation
   ```

3. Choose **Restart Relay** from its menu after granting access. For optional
   contact names/photos, run:

   ```sh
   open -n -a "$HOME/Applications/Zimbr Relay Dev.app" --args doctor --request-contacts --read-only
   ```

Use the menu's **Check Permissions** and **Open Logs** to verify readiness.
The relay needs this user's graphical login after reboot; locking the screen
does not log the user out. Permission grants cannot be automated by the installer.

## 3. Build and connect on Linux

Install Zig 0.16.0 and the [Linux build dependencies](linux-client.md#build-and-install),
including OpenSSH, Python cryptography, and OpenSSL. Then:

```sh
zig build client -Dprofile=dev -Doptimize=ReleaseSafe
packaging/linux/install.sh
zimbr-provision setup user@mac.example --profile dev --launch "$HOME/.local/bin/zimbr"
```

The dev app includes the same SSH enrollment helper as the release app. Its
helper uses the Homebrew Python and mkcert installed above. Alternatively, set
`ZIMBR_PYTHON` in the Mac's SSH environment to the Python environment prepared
above. No source checkout is used during enrollment.

Setup generates the Linux key, sends its CSR over SSH, enrolls the returned
certificate, saves the connection, and opens the client. It targets only the dev
profile (port 8732). The default credentials are under
`$XDG_CONFIG_HOME/zimbr-dev/tls` or `~/.config/zimbr-dev/tls`.

Open **Details** (Ctrl+D) to check authentication and sync. Setup sends no messages.
See [TLS operation](linux-mtls.md) for renewal and [Mac validation](mac-validation.md)
for permissions, restart, and deliberate send checks.
