# macOS TLS operation

Start with [first-run setup](setup.md), which builds the relay, generates its
configuration with mkcert, and enrolls Linux. Every HTTP/SSE connection requires
TLS 1.3, HTTP/1.1, and an enabled client certificate. The
[certificate contract](certificate-management.md) defines issuance and validation.

Commands default to **dev** (port 8732). Select `--profile release` for Homebrew
(port 8731), including enrollment/revocation and installation. See
[profiles](macos-profiles.md).

## Build

Use Zig 0.16.0 and OpenSSL **3.5 LTS**, including current patches. The repository
tooling defaults to **3.5.8**. Obtain source and verify its
published digest from [OpenSSL downloads](https://openssl-library.org/source/).
Build static libraries for the target architecture, for example on Apple Silicon:

```sh
./Configure darwin64-arm64-cc no-shared no-module no-tests --prefix=/absolute/openssl-3.5
make -j8
make install_sw
zig build relay fake-relay test -Dopenssl-prefix=/absolute/openssl-3.5
```

The prefix must contain `include`, `lib/libssl.a`, and `lib/libcrypto.a`.
Cross builds require libraries built for that target, plus the target macOS SDK.
The source rejects other OpenSSL minor versions at compile time. The installed relay links
OpenSSL statically and uses system libraries and frameworks; it has no Homebrew
runtime path. Ship OpenSSL's license with the app, and rebuild/re-sign for
security updates.

Provisioning uses Python with `cryptography` (`tools/requirements-tls.txt`) and
mkcert 1.4.4. Network tests and Mac API tools require a Python `ssl` module with
TLS 1.3; the Apple system Python/LibreSSL is insufficient.
Provisioning tools are not relay runtime dependencies.

## Provisioning

`tools/tls_admin.py setup --server-name NAME --listen-address IP` generates a
server key/CSR and a separate Mac administrative key/CSR, asks **mkcert** to sign
both, enrolls the administrator, writes `relay.json` and `admin.json`, and runs
`relay check-config`. Its defaults are:

| Material | Dev location |
| --- | --- |
| Dedicated signing CA | `~/.config/zimbr-dev-ca` |
| Staging configuration/credentials | `~/.config/zimbr-dev-setup` |
| Installed configuration | `~/Library/Application Support/Zimbr Dev/relay.json` |
| Installed administrative configuration | `~/Library/Application Support/Zimbr Dev/admin.json` |

Use `--directory`, `--caroot`, and `--relay` for explicit paths, `--name` for
additional SANs, and `--port` to override the profile port. Release setup defaults
to `zimbr-release-ca` and `zimbr-release-setup`. Staging must be empty; setup never
rotates an existing installation implicitly. Reuse the issuer after a failed run,
with a new staging directory. Install only after validation succeeds.

The CA stays outside source/runtime directories. Never copy its `rootCA-key.pem`
into the bundle or onto Linux. Do not run `mkcert -install` or reuse a broadly
trusted development CA. mkcert uses a dedicated `CAROOT` and its `-csr` mode;
client authentication purpose comes from the validated CSR, not `-client`.

All security paths must be absolute without symlinks. On macOS, use a private
folder in your home or `/private/tmp`, since `/tmp` is a symlink. Keys,
certificates, allowlists and configurations are 0600 files in owned 0700
directories. The installer creates immutable runtime credential generations
outside the app; staging can be removed after checking installation and backups.
Keep the signing CA for renewal and device issuance.

For Linux requests, `issue-device` combines validated signing, enrollment and
verified service restart. Its output directory contains only the public CA and
issued device certificate. It verifies that `--caroot` matches the installed
relay CA. Existing deployments should explicitly select their original issuer.
Use the lower-level `create-key`, `sign`, `enroll`, and `revoke` commands from the
[certificate contract](certificate-management.md) for custom administration.

`relay.json` contains `listen_address`, `port`, `server_name`,
`server_cert_file`, `server_key_file`, `client_ca_file`, and
`device_allowlist_file`. Optional `contacts_phone_region` provides national-number
context. Use relay Settings to edit these fields with validation.
The allowlist contains objects with `label`, `sha256` (64 hexadecimal digits over
the entire leaf DER), and `enabled`. An empty list admits nobody; invalid or
duplicate entries prevent startup. The limit is 256 devices.

`admin.json` contains `relay_url`, `ca_file`, `client_cert_file` and
`client_key_file`. Administrative API tools use the same mTLS policy as Linux.
The local `doctor` command needs no administrative certificate.

## Code signing and installation

Run once in Terminal on the Mac, without sudo:

```sh
.tools/python/bin/python3 packaging/macos/signing.py setup
```

Approve the local certificate trust prompt. This creates a persistent Keychain
and code-signing identity under `~/.config/zimbr-code-signing`. It is separate
from the TLS CA. The helper can resume interrupted setup and preserves the login
Keychain/search list. Back up this identity; changing it may require new Full
Disk Access, Automation, and Contacts grants.

The installer uses that identity by default, pinning the signing certificate and
selected bundle ID. `--identity NAME_OR_SHA1` selects another managed identity;
`--identity -` opts into disposable ad-hoc signing. Local signing does not provide
Developer ID distribution trust or notarization. Homebrew uses the publisher's
signed bundle and may need fresh privacy/Gatekeeper approval.

Follow [setup](setup.md#2-generate-credentials-and-install-on-the-mac) for the
first install. Later source updates reuse installed TLS material:

```sh
./tools/update-relay.sh --profile dev --release=safe
```

Keep the toolchain environment overrides from setup. Installation validates and
signs before stopping the old process, preserves a consistent journal backup,
and verifies process exit and the new listener. A failed startup leaves the
service stopped for repair. Epoch, history and durable request IDs are retained.
Run the installed doctor through Launch Services to check permission attribution;
a Terminal binary's access does not establish the installed app's access.

## Renewal and revocation

Generate a new key/CSR in a fresh directory on the device, sign and verify the
replacement, then enroll the new fingerprint. A short overlap is allowed:

```sh
python3 tools/tls_admin.py enroll --cert /private/import/new-client.pem \
  --label 'Linux desktop'
# Reconnect with the new Linux credential, then retire the old fingerprint:
python3 tools/tls_admin.py revoke --sha256 OLD_64_HEX_FINGERPRINT
```

These commands validate a candidate allowlist, write atomically, restart only the
installed Zimbr LaunchAgent, and verify old-process exit plus the new configured
listener. They refuse to restart a service using a different config/executable.
Errors propagate: failed restart never claims completed revocation. `--stage`
explicitly changes files without applying access policy and prints that restart
is still required. A restart closes **all** old pooled connections and SSE
streams; the new process reauthenticates every connection. Already accepted
sends retain their journal identities and normal recovery semantics.

Server renewal uses the same CA and endpoint SANs and fresh locally generated
key/CSR. Stage a new relay config, validate it, then install/restart. Reconnect
clients afterwards. CA replacement requires a coordinated explicit trust update.
No online enrollment, OCSP/CRL service, or automatic renewal is provided. Read
actual certificate expiry; `doctor` warns within 30 days for the server or CA.
Client devices monitor their own leaf expiry. Active requests/SSE sessions close
when their certificate validity expires, including CA/server validity.

## Verification

Run the native build and unit suite, `tests/integration.py`, `tests/relay_tls.py`,
`tests/cert_management.py`, and `tests/mac_acceptance_test.py`. Use temporary
certificates and synthetic message data for transport and fault tests.

For an installed deployment, verify the app signature, configured listener,
TLS 1.3/HTTP/1.1 negotiation, explicit CA and hostname checks, and rejection of
plaintext, missing client certificates, and revoked devices. Check both HTTP and
SSE connections, including closure and reauthentication after renewal/revocation.

Verify permissions under the installed app identity and preserve epoch, message
IDs, durable send records, and cursor replay across upgrades and restarts.
Keep backups, endpoint configuration, certificate inventories, and acceptance
evidence in private administrative storage outside the public repository.
