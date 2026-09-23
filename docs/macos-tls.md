# macOS TLS operation

The macOS relay now requires TLS 1.3, HTTP/1.1, and a separately enrolled client
certificate on **every** API and SSE connection. The Linux transport code is
also available.
Its provisioning and test adapters need the corrections recorded in
[the integration review](linux-mtls-review.md); execution of the Linux client
remains on the Linux host.
There is no plaintext listener, bearer token, or automatic fallback.

## Build

Use Zig 0.16.0 and OpenSSL **3.5 LTS**, including current patches. The native
migration build uses **3.5.8**, released 2026-08-25. Obtain source and verify its
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
The source rejects other OpenSSL minor versions at compile time. The installed
relay links only system SQLite/libSystem dynamically; it has no Homebrew runtime
path. Ship OpenSSL's license with the app, and rebuild/re-sign for security updates.

Provisioning uses Python with `cryptography` (`tools/requirements-tls.txt`) and
mkcert 1.4.4. Network tests and Mac API tools require a Python `ssl` module with
TLS 1.3; the Apple system Python/LibreSSL is insufficient.
Provisioning tools are not relay runtime dependencies.

## Provisioning

The Mac owns certificate issuance and enrollment. The authoritative
[certificate management contract](certificate-management.md) specifies the CSR,
issued-leaf, import, and renewal rules that clients must follow.

Use a dedicated private administrative CA directory **outside the repository and
runtime state**, such as `~/.config/zimbr-ca-admin`. Never run `mkcert -install`,
reuse a broadly trusted development CA, or copy `rootCA-key.pem` into the app,
client distributions, or runtime state. The helper marks its dedicated CAROOT and
rejects an existing unmarked CA. Keep the CA key for future manual renewals.

Choose a reachable DNS name and an explicit private-network listening address.
An SSH alias is not a certificate identity. The examples use the reserved name
`relay.example` and documentation address `192.0.2.10`; replace both with your
deployment values and include the identities clients use in the server SANs.
Verify direct TCP reachability before installation. Keep actual endpoints and
network configuration in private deployment records.

Generate the server key **on the Mac**, then sign only its CSR. All paths in
configuration must be absolute, without symlinks (on macOS use `/private/tmp`,
not `/tmp`). Key, certificate, CA, allowlist, and configuration files are 0600 in
owner-owned 0700 directories. Ancestors must not be writable by other users,
except root-owned sticky temporary directories.

```sh
umask 077
python3 tools/tls_admin.py create-key --role server \
  --directory /private/staging/server \
  --name relay.example --name 192.0.2.10
python3 tools/tls_admin.py sign --role server \
  --caroot /Users/USER/.config/zimbr-ca-admin \
  --csr /private/staging/server/server.csr \
  --cert /private/staging/server/server.pem \
  --name relay.example --name 192.0.2.10 --mkcert /path/to/mkcert
```

Replace example names/addresses with the selected endpoint. Create a separate
administrative client key/certificate on the Mac using `--role client` and
`--name mac-admin.zimbr.invalid`. Client SANs/subjects are metadata; only the leaf
DER SHA-256 fingerprint authorizes a device. Explicit SANs prevent mkcert from
inventing a SAN from the CSR Common Name. The helper requires a non-CA leaf,
exact EKU/SANs, safe key usage and strength, and no unexpected extensions. It
validates the issued chain, purpose, dates, SANs and CSR public key before
publishing the certificate. `-csr` is deliberately never combined with `-client`.

Linux creates its own key and CSR locally. Transfer only CSRs, issued leaf
certificates, and the public `rootCA.pem` via authenticated SSH or a verified
fingerprint. The CA file must be authenticated before importing it. Copy the
public CA to each runtime TLS directory as `ca.pem` and chmod it to 0600.
No Linux private key is generated or held by the Mac.

Relay configuration (`relay.json`):

```json
{
  "listen_address": "192.0.2.10",
  "port": 8731,
  "server_name": "relay.example",
  "server_cert_file": "/private/staging/server/server.pem",
  "server_key_file": "/private/staging/server/server-key.pem",
  "client_ca_file": "/private/staging/server/ca.pem",
  "device_allowlist_file": "/private/staging/server/devices.json"
}
```

`devices.json` is an array of objects containing `label`, `sha256` (64 hex
characters, SHA-256 over the entire leaf's DER), and `enabled` (boolean). Use the
fingerprint printed after signing, or `openssl x509 -in client.pem -noout
-fingerprint -sha256` with colons removed. An empty array admits nobody; invalid,
duplicate, or unreadable entries prevent startup. Maximum 256 device entries.

Mac administrative tools use a separate 0600 `admin.json`:

```json
{
  "relay_url": "https://relay.example:8731",
  "ca_file": "/private/staging/admin/ca.pem",
  "client_cert_file": "/private/staging/admin/client.pem",
  "client_key_file": "/private/staging/admin/client-key.pem"
}
```

Enroll this administrative certificate as an enabled device before startup.
Administrative tools verify the exact server identity using only the explicit
CA, load their own client certificate, disable older TLS, and do not follow
redirects. No localhost bypass exists. The local `doctor` command uses files
and the database directly and therefore needs no administrative certificate.

## Install, restart, and verify

First stage and inspect, then install:

```sh
zig-out/bin/relay check-config --config /private/staging/relay.json
python3 packaging/macos/install.py \
  --tls-config /private/staging/relay.json --admin-config /private/staging/admin.json \
  --openssl-license /openssl-source/LICENSE.txt
python3 packaging/macos/install.py --install --start \
  --tls-config /private/staging/relay.json --admin-config /private/staging/admin.json \
  --openssl-license /openssl-source/LICENSE.txt
```

The installer validates before stopping the old service, verifies process exit,
backs up the journal consistently under `Zimbr/backups/TIMESTAMP/relay.db`, installs
new private credential directories and configuration, removes the runtime token,
and starts the same LaunchAgent identity: `com.hsp.zimbr.relay`. The app remains
`~/Applications/Zimbr Relay.app`. Epoch, cursor, history, and durable request IDs
are unchanged. Future upgrades can reuse installed material by omitting
`--tls-config`/`--admin-config`. There is no database migration.

The LaunchAgent has `RunAtLoad`, `KeepAlive`, and the existing Aqua login-session
requirement. The installer verifies the actual process's configured listener;
failed startup leaves it stopped for repair. Ad-hoc builds may need Full Disk
Access and Automation grants refreshed. Check the installed identity, not just
a terminal/development executable:

```sh
"$HOME/Applications/Zimbr Relay.app/Contents/MacOS/relay" doctor --check-automation
python3 - <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, 'tools')
from mac_acceptance import Client
print(Client(Path.home()/'Library/Application Support/Zimbr').request('/v1/status'))
PY
```

Use `tools/read_only_smoke.py --relay-config ... --tls-config ...` for a separate
read-only development process on an **unused** explicit address/port, with an
enrolled administrative certificate. It uses a temporary journal and does not
send messages. `tools/mac_acceptance.py --tls-config ...` retains its requirement
for an explicitly selected recipient and `--confirm-send`. Real-message checks require an explicitly authorized recipient.

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
