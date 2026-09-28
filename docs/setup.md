# Development setup: build a Mac relay and Linux client

Installed from AUR? Use [AUR client setup](linux-setup.md). For the packaged Mac
relay, use [Homebrew setup](macos-relay.md#homebrew). This guide builds from source.

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
brew install mkcert python openssl@3.5
mkdir -p .tools
"$(brew --prefix)/bin/python3" -m venv .tools/python
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

## 3. Build and request a device certificate on Linux

Install Zig 0.16.0 and the [Linux build dependencies](linux-client.md#build-and-install).
On Arch Linux, for example:

```sh
sudo pacman -S --needed base-devel pkgconf sqlite curl openssl pango cairo fontconfig \
  glib2 libpng libjpeg-turbo mesa wayland wayland-protocols libxkbcommon \
  ttf-dejavu noto-fonts-emoji python python-cryptography
zig build client -Dprofile=dev -Doptimize=ReleaseSafe
packaging/linux/install.sh
umask 077
mkdir -p "$HOME/.config/zimbr-dev"
chmod 700 "$HOME/.config/zimbr-dev"
python3 packaging/linux/provision.py request \
  --tls-dir "$HOME/.config/zimbr-dev/tls" --name linux-desktop.zimbr.invalid
```

The name is a device label; it does not need DNS. Its key stays on Linux.
Use authenticated SSH with a verified Mac host key to transfer **only the CSR**:

```sh
MAC_SSH=user@mac.example
ssh "$MAC_SSH" 'umask 077; mkdir -p "$HOME/.config/zimbr-inbox"; chmod 700 "$HOME/.config/zimbr-inbox"'
scp "$HOME/.config/zimbr-dev/tls/client.csr" "$MAC_SSH:.config/zimbr-inbox/client.csr"
```

## 4. Approve the device on the Mac

From the Mac checkout:

```sh
chmod 600 "$HOME/.config/zimbr-inbox/client.csr"
.tools/python/bin/python3 tools/tls_admin.py issue-device --profile dev \
  --csr "$HOME/.config/zimbr-inbox/client.csr" \
  --name linux-desktop.zimbr.invalid --label 'Linux desktop' \
  --directory "$HOME/.config/zimbr-return"
```

This checks the requested name, signs with mkcert, enrolls the leaf fingerprint,
restarts the installed relay, and verifies the new listener. The return directory
contains only `ca.pem` and `client.pem`. Existing installations with a different
issuer path must pass `--caroot` pointing to that original CA. A failed restart
leaves policy staged; fix the service before treating enrollment as complete.

## 5. Import and connect on Linux

Keep Zimbr closed during this step. In the Linux shell with `MAC_SSH` set:

```sh
umask 077
tls_dir="$HOME/.config/zimbr-dev/tls"
scp "$MAC_SSH:.config/zimbr-return/ca.pem" "$tls_dir/returned-ca.pem"
scp "$MAC_SSH:.config/zimbr-return/client.pem" "$tls_dir/issued.pem"
ca_sha256=$(openssl x509 -in "$tls_dir/returned-ca.pem" -noout -fingerprint -sha256)
ca_sha256=${ca_sha256#*=}
python3 packaging/linux/provision.py import --tls-dir "$tls_dir" \
  --ca "$tls_dir/returned-ca.pem" --cert "$tls_dir/issued.pem" --ca-sha256 "$ca_sha256" \
  --relay-url https://relay.example:8732 --launch "$HOME/.local/bin/zimbr"
```

The verified SSH transfer authenticates the public CA used to calculate this
fingerprint. For another transfer method, obtain the CA fingerprint independently
from the Mac. Import checks the CA, certificate, retained CSR and local key before
opening Settings with all connection fields filled in. Click **Save and connect**
to persist them. Subsequent launches use the desktop launcher with no flags.

Open **Details** (Ctrl+D) to check the connection and certificate. If it fails,
check the endpoint/SAN, direct TCP access, the enabled device fingerprint, and Mac
logs; then choose **Reconnect**. Read [Linux TLS operation](linux-mtls.md) for
renewal/revocation and [Mac validation](mac-validation.md) for restart, permissions,
and deliberate send checks. Setup itself sends no messages.
