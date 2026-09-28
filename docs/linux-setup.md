# Set up the Linux client installed from AUR

Use this guide after installing the `zimbr` AUR package. It includes `zimbr`,
`zimbr-provision`, and the **Zimbr** desktop launcher. Run the Linux commands
in a terminal in your Wayland session, as your ordinary user. No Linux source
checkout, Zig command, or additional installer is needed after package installation.

The package uses the **release** profile: the relay's default port is **8731**,
and the suggested certificate directory is `~/.config/zimbr/tls`. If you already
saved a working connection, open **Zimbr** from your application launcher or run
`zimbr`; enrollment is only needed for a new device or replacement credentials.

## 1. Have the Mac relay ready

The Mac must be signed into Messages in its graphical login session, with its
relay configured and running. For a new packaged relay, complete
[Homebrew setup](macos-relay.md#homebrew), including macOS permissions and
`zimbr-relay-service start`, before continuing here.

You need:

- The relay's HTTPS address, such as `https://relay.example:8731`. Its hostname
  or IP must match the server certificate and be directly reachable from Linux.
- Authenticated SSH access to the Mac, with its host key verified, for the file
  exchange below. Enable Remote Login on the Mac if using this method.
- Access to the Mac's certificate issuer to approve this device. The Mac's
  `tools/tls_admin.py` helper currently requires a matching source checkout and
  its Python environment, even when the relay itself is installed with Homebrew.
  The [Homebrew instructions](macos-relay.md#homebrew) prepare those tools.

Replace `relay.example` and `user@mac.example` with your deployment values.
The SSH address and relay address can differ; an SSH alias alone does not make
the HTTPS address reachable. Permit TCP port 8731 through the relevant firewall.
If the relay uses a custom port, use that port throughout.

## 2. Request a certificate on Linux

Close Zimbr before provisioning. In a Linux terminal:

```sh
umask 077
mkdir -p "$HOME/.config/zimbr"
chmod 700 "$HOME/.config/zimbr"
zimbr-provision request \
  --tls-dir "$HOME/.config/zimbr/tls" --name linux-desktop.zimbr.invalid
```

`linux-desktop.zimbr.invalid` is a device label, not a hostname that needs to
resolve. Choose a different name under `zimbr.invalid` for each device and use
the same name when approving it on the Mac. Keep both `client-key.pem` and
`client.csr` on Linux; import needs the retained request to verify the response.
The helper refuses to overwrite an existing key. For renewal, use a new private
directory as described in [Linux TLS operation](linux-mtls.md#operation-and-renewal).

Transfer only the certificate request to the Mac:

```sh
MAC_SSH=user@mac.example
ssh "$MAC_SSH" 'umask 077; mkdir -p "$HOME/.config/zimbr-inbox"; chmod 700 "$HOME/.config/zimbr-inbox"'
scp "$HOME/.config/zimbr/tls/client.csr" "$MAC_SSH:.config/zimbr-inbox/client.csr"
```

## 3. Approve the device on the Mac

In a Mac terminal, from the matching checkout with the Python environment
prepared during Homebrew setup:

```sh
chmod 600 "$HOME/.config/zimbr-inbox/client.csr"
.tools/python/bin/python3 tools/tls_admin.py issue-device --profile release \
  --csr "$HOME/.config/zimbr-inbox/client.csr" \
  --name linux-desktop.zimbr.invalid --label 'Linux desktop' \
  --directory "$HOME/.config/zimbr-return"
```

This signs the request, enables its certificate fingerprint, restarts the
installed release relay, and verifies its listener. Wait for it to succeed
before continuing. The return directory must be new or empty; choose another
directory for subsequent devices and adjust the transfer commands below.
If the relay uses a custom issuer directory, add `--caroot` pointing to its
original CA. The default release issuer is `~/.config/zimbr-release-ca`.

Only `ca.pem` and `client.pem` return to Linux. The CA private key stays on the
Mac; the device private key stays on Linux.

## 4. Import and connect on Linux

Return to the Linux terminal, with Zimbr still closed:

```sh
umask 077
MAC_SSH=user@mac.example
tls_dir="$HOME/.config/zimbr/tls"
scp "$MAC_SSH:.config/zimbr-return/ca.pem" "$tls_dir/returned-ca.pem"
scp "$MAC_SSH:.config/zimbr-return/client.pem" "$tls_dir/issued.pem"
ca_sha256=$(openssl x509 -in "$tls_dir/returned-ca.pem" -noout -fingerprint -sha256)
ca_sha256=${ca_sha256#*=}
zimbr-provision import --tls-dir "$tls_dir" \
  --ca "$tls_dir/returned-ca.pem" --cert "$tls_dir/issued.pem" --ca-sha256 "$ca_sha256" \
  --relay-url https://relay.example:8731 --launch /usr/bin/zimbr
```

These commands authenticate the returned CA through the verified SSH connection.
If you transfer the files another way, obtain the CA SHA-256 fingerprint
independently from the Mac and pass that value to `--ca-sha256`.

The importer verifies the certificates against the retained request and local
key, then opens **Settings** with the connection fields filled in. Click
**Save and connect** to persist them. No client JSON file needs editing.
Open **Details** (Ctrl+D) to check the endpoint, authentication, and certificate.
Conversation history appears as synchronization progresses; setup sends no messages.

For later launches, use the **Zimbr** desktop launcher or run:

```sh
zimbr
```

Settings, cached history, and drafts are saved in `client.db` under
`$XDG_STATE_HOME/zimbr`, falling back to `~/.local/share/zimbr`. Certificates
remain in the directory above. Keep Zimbr running to receive notifications;
closing it stops notification delivery.

## If it does not connect

- **A development build opens:** run `/usr/bin/zimbr --help` and check for
  `Profile: release`. A previous `~/.local/bin/zimbr` or user-local desktop entry
  can take precedence over the package; use `/usr/bin/zimbr` to open the package.
- **Connection refused or hostname lookup fails:** check the Mac service with
  `zimbr-relay-service status`, the HTTPS hostname, port, routing, and firewall.
  Release defaults to 8731; source builds default to 8732.
- **TLS or access failure:** check the endpoint against the server certificate,
  certificate expiry, and the device fingerprint's enrollment on the Mac.
  **Open Logs** in the relay menu and Linux **Details** show diagnostics.
- **Credential permissions rejected:** certificate/key files must be owned by
  you with mode 0600 in owned directories with mode 0700, without symlinks.
  The provisioning helper creates these permissions; preserve them when moving files.

After correcting a connection problem, choose **Reconnect** in Details.
See [Linux TLS operation](linux-mtls.md) for renewal and
[Linux client](linux-client.md) for controls, notifications, and offline use.
