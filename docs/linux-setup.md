# Linux package setup

First complete the [Mac step](setup.md#1-on-macos). Install `zimbr` from AUR,
close any running Zimbr instance, and run this in your Wayland session:

```sh
zimbr-provision setup user@relay.example
```

Use the Mac account running the relay. SSH config aliases, keys, custom ports,
and jump hosts work through your normal SSH configuration. Verify its host key
when prompted. No source checkout is needed on either computer.

The helper generates a private key on Linux, sends the CSR through SSH to the
packaged Mac helper, verifies the returned certificates, saves the connection,
and opens Zimbr. The relay supplies its HTTPS endpoint; there is no second URL
to type. Setup sends no messages. Later launches need only `zimbr` or the desktop
launcher.

## Options and storage

- `--label 'Work laptop'` chooses the device display name on the Mac.
- `--tls-dir /absolute/private/directory` chooses credential storage, including a
  new directory for [renewal](linux-mtls.md#operation-and-renewal).
- `--profile dev --launch /path/to/zimbr` targets a separately installed dev build.

Defaults use the release profile and port 8731. Credentials live in
`$XDG_CONFIG_HOME/zimbr/tls`, falling back to `~/.config/zimbr/tls`. Settings,
history, and drafts live in `client.db` under `$XDG_STATE_HOME/zimbr`, falling back
to `~/.local/share/zimbr`. Setup creates private directories and files. Keep the
private key and retained CSR on this device.

Interrupted setup can be rerun with the same command; it reuses the local key and
request and the Mac's issued certificate. A failed enrollment or restart leaves
the client unopened. Fix the reported error and retry. An already running client
must be closed before the new connection can be saved.

## If it does not connect

- **SSH fails:** enable Remote Login, check the login account and SSH configuration,
  and verify the Mac host key. The account must own the running relay and its CA.
- **Helper missing:** upgrade the Mac package and run `zimbr-relay-setup` there.
- **Wrong client profile:** a development install can shadow `/usr/bin/zimbr`.
  Use `/usr/bin/zimbr-provision setup user@relay.example --launch /usr/bin/zimbr`.
- **Connection refused or DNS fails:** check `zimbr-relay-service status` on the
  Mac and direct access to its HTTPS hostname and port. SSH access alone does not
  provide HTTPS routing. Permit the relay port through the firewall.
- **TLS or access failure:** check the certificate expiry and enrolled fingerprint
  in **Details** (Ctrl+D), and **Open Logs** on the Mac. Then choose **Reconnect**.
- **Unsafe file permissions:** credential files must be owned 0600 regular files
  in owned 0700 directories, with no symlinks or hardlinks. Preserve the modes
  created by setup.

Use [Linux TLS operation](linux-mtls.md) for renewal, revocation, and manual CSR
exchange when SSH is unavailable. [Client controls](linux-client.md) covers daily use.
