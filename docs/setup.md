# Set up Zimbr

## Requirements
1. An always on Mac.
2. A linux machine (wayland only)
3. SSH (only for initial setup) and HTTPS access (default port 8731) from linux to Mac
4. (Optional) Tailscale

You need a Mac signed into Messages in its graphical login session, a Linux
Wayland desktop, and SSH access to that same Mac login account. Enable **Remote
Login** on the Mac. Linux must also reach the Mac over HTTPS (default TCP port
**8731**). SSH is used only for enrollment.

Replace `mac-relay.example` with a DNS name or IP that reaches your Mac (even better
if this is your tailscale DNS/IP), and `user` with its login account. An SSH
config alias can be used in the Linux command; it does not change the relay's
HTTPS address.

## 1. On macOS

Install the Apple Silicon package on macOS 27 or newer, then run setup:

```sh
brew install --cask hspak/tap/zimbr-relay
zimbr-relay-setup mac-relay.example
```

Setup creates the relay credentials and a dedicated local CA, configures the
relay, and starts it at login. It chooses a local listening address from the
server name; use `--listen-address IP` if your routing needs a different one.
Use `--port NUMBER` for a custom port.

Complete the [macOS permissions](macos-relay.md#permissions): Full Disk Access,
Messages Automation, and optionally Contacts. These require your approval on
the Mac. If permissions prevent startup, grant them and rerun setup.

## 2. On Linux

Install `zimbr` from AUR with your usual AUR helper, then run setup in your
Wayland session, with Zimbr closed:

```sh
zur -S zimbr
zimbr-provision setup user@mac-relay.example
```

Setup generates this device's private key locally, exchanges only the CSR and
public certificates over SSH, enrolls the device, and opens Zimbr with the
connection saved. No file transfers, certificate commands, or Settings edits are
needed.

That's it! Open **Zimbr** from your application launcher or run `zimbr`. Keep it
running for desktop notifications.

## Retry, update, or troubleshoot

Rerun the same setup command after an interruption. Existing keys are preserved;
retrying a CSR uses its original certificate. Mac setup keeps an existing
configuration and refuses a conflicting endpoint.

After `brew upgrade --cask hspak/tap/zimbr-relay`, run
`zimbr-relay-service start`. AUR upgrades keep the Linux connection and history.

See [Linux setup details](linux-setup.md) for paths and connection failures,
[Mac operation](macos-relay.md) for service controls and permissions, and
[development setup](development.md) to build from source.
