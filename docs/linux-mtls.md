# Linux mTLS setup and handoff

The Linux client and native macOS relay use direct HTTPS with TLS 1.3,
HTTP/1.1, and an enrolled device certificate. The provisioning and integration
mismatches from [the review](linux-mtls-review.md) are resolved. Linux worker
suites now connect directly to the production TLS implementation in `fake-relay`.
No client fallback, plaintext adapter, or tunnel is used.

The Mac owns issuance and enrollment policy. Follow the authoritative
[certificate management contract](certificate-management.md): request an explicit
device SAN, have the Mac signer validate that exact name, and validate the returned
SAN against the retained local CSR during import. Examples use the reserved placeholder `https://relay.example:8731`; replace it
with your relay endpoint. Installed two-host
acceptance is separate from the synthetic tests documented here.

## Provision a Linux device

Choose the Mac's reachable DNS name or IP and ensure that exact identity is in
its server certificate's SANs. SSH aliases and jump hosts do not supply direct
TCP connectivity. The examples use `relay.example:8731`.

The helper requires Python 3, `cryptography` (43 or newer), and the OpenSSL command
line tool. The installed name is `zimbr-provision`; from the checkout use
`python3 packaging/linux/provision.py`.

```sh
umask 077
mkdir -p "$HOME/.config/zimbr"
chmod 700 "$HOME/.config/zimbr"
python3 packaging/linux/provision.py request \
  --tls-dir "$HOME/.config/zimbr/tls" \
  --name linux-desktop.zimbr.invalid --label 'Linux desktop'
```

This creates a 0600 local P-256 key and `client.csr` in a 0700 directory. `--name`
is the explicit device DNS SAN under `zimbr.invalid`; `--label` is human-readable
subject metadata. Neither authorizes access. Keep the CSR locally for import
verification, and pass the same `--name` to the Mac signer. The helper refuses
to overwrite an existing key. Old CSRs without a SAN need a fresh key/CSR in a
new private directory. Transfer **only the CSR** to the Mac's
administrator using the existing trusted SSH channel. The administrator must
inspect the CSR's signature, non-CA constraint, digital-signature key usage,
and clientAuth EKU, exact SAN, and absence of unexpected extensions before signing. With the
dedicated Zimbr `CAROOT`, sign using mkcert's `-csr` support; do not combine
`-csr` with `-client`, run `mkcert -install`, or reuse a general development CA.
Use the existing Mac `tools/tls_admin.py sign --role client --name ...` and
`enroll` commands from the certificate contract for issuance and access.

Return the issued device certificate and public `rootCA.pem`. Authenticate the
CA's entire-DER SHA-256 fingerprint over trusted SSH or an independent channel
before passing it to the helper. An unauthenticated fingerprint accompanying an
unauthenticated file does not establish trust. On the trusted administrator host:

```sh
openssl x509 -in rootCA.pem -noout -fingerprint -sha256
```

Then on Linux, using that verified fingerprint:

```sh
python3 packaging/linux/provision.py import \
  --tls-dir "$HOME/.config/zimbr/tls" \
  --ca /absolute/path/to/returned/rootCA.pem \
  --cert /absolute/path/to/returned/linux-client.pem \
  --ca-sha256 VERIFIED_CA_DER_SHA256
```

Import verifies the pin, leaf signature, purpose, validity, extensions, allowed
key usages, and the certificate/CSR/private-key match before replacing runtime
public certificates. Its SAN must exactly match the signed local CSR, which
must also be an owned 0600 regular file without symlinks or hardlinks. Enroll the **client leaf
DER SHA-256** printed by the helper in the relay's enabled-device allowlist.
The CA key stays in protected administrator storage; neither the helper nor the
Linux application needs it. Private-key contents are never command arguments.

Create `~/.config/zimbr/config.json` (or `$XDG_CONFIG_HOME/zimbr/config.json`):

```json
{
  "relay_url": "https://relay.example:8731",
  "ca_file": "/home/USER/.config/zimbr/tls/ca.pem",
  "client_cert_file": "/home/USER/.config/zimbr/tls/client.pem",
  "client_key_file": "/home/USER/.config/zimbr/tls/client-key.pem",
  "enter_to_send": true
}
```

Use real absolute paths and set the config file to 0600. Runtime credential and
configuration files must be owned by the current user, mode 0600, in owned 0700
containing directories. Symlinks (including parent components), hardlinked files,
unsafe writable ancestors, missing material, and key mismatches are rejected.
Shared system ancestors such as `/home` may be root-owned; they need not be 0700.
The root-owned sticky `/tmp` ancestor is allowed for temporary test directories.

CLI overrides are `--relay-url`, `--ca-file`, `--client-cert-file`,
`--client-key-file`, and `--data-dir`. An origin may include a port and
a trailing `/`, but no userinfo, query, fragment, or application path. Old
`port`/`token_file` settings and `--port`/`--token-file` fail with migration guidance.
Remove obsolete fields even when providing new CLI overrides.

## Operation and renewal

Details shows the endpoint, mTLS state, client fingerprint and expiry, HTTP
status, libcurl result, certificate verification result, and bounded error text.
The status bar warns during the last 30 days of the client certificate's life.
DNS/network errors and ambiguous TLS failures retry with bounded backoff.
Explicit trust, credential, configuration, certificate-rejection, and HTTP
access/redirect failures wait for **Reconnect** after correction. A generic TLS
handshake failure is never reported as proven client-certificate rejection.
The native relay currently sends a generic handshake-failure alert for an
unenrolled or disabled fingerprint. For that diagnostic, check enrollment of the
fingerprint shown in Details and the relay TLS configuration; bounded retries
continue until the connection succeeds or you click Reconnect.

Reconnect validates and reloads credentials and destroys all old HTTP/SSE
connections and TLS session state. File changes alone do not change a running
credential snapshot. Changing configuration paths or endpoint requires restarting
the application. Renewal does not clear the cache, drafts, cursor, or outbox.

For renewal, generate a new key/CSR in another private directory, have it signed,
import and verify it there, and enroll the new leaf fingerprint on the Mac. A
brief overlap of enabled device fingerprints is permitted. Quit the client,
update its credential paths and restart, or replace the validated files at its
existing paths while disconnected and click Reconnect. Remove the old enrollment
after verifying the new fingerprint. Server renewal retains its hostname and CA;
CA replacement requires a coordinated trust update.

The existing client database format is unchanged. An interrupted POST remains
uncertain until lookup by its original UUID; a new send is kept as a draft while
that lookup is outstanding. An authoritative not-found result is shown as
unconfirmed and is never automatically resubmitted. Back up the client database
with the application stopped for the coordinated release cutover.

## Linux verification and server handoff

The client requires libcurl **7.88 or newer with the OpenSSL 3 backend**, plus
OpenSSL development headers. Unsupported TLS backends fail closed. Every curl
option is checked. Peer/hostname verification, TLS 1.3 only, HTTPS protocols only,
HTTP/1.1, disabled redirects/proxies, and disabled TLS session caching apply to
both API and SSE connections. An OpenSSL callback replaces the entire trust
store, including default lookup methods, with the configured dedicated CA.
Connections are reused only inside one immutable credential configuration.

The native `fake-relay` and relay unit tests require OpenSSL **3.5 LTS** headers
and libraries, matching the server wrapper. If the Linux system libraries use a
different minor version, supply a target OpenSSL 3.5 build using
`-Dopenssl-prefix=/absolute/openssl-3.5` in the command below. See
[the relay build instructions](macos-tls.md#build).

```sh
zig build test client client-probe fake-relay
python3 tests/cert_management.py  # real mkcert required; ZIMBR_MKCERT may override its path
python3 tests/client_tls.py
python3 tests/client_native_tls.py
python3 tests/client_integration.py
python3 tests/client_transport.py
python3 tests/client_details.py
python3 tests/performance.py --samples 3 --history 40 --burst 20
zig build test-gui  # running Wayland desktop required
zig fmt --check build.zig src
```

Python client harnesses require `cryptography` and use ephemeral CAs; no test CA
is installed in system trust stores. `tests/relay_fixture.py` configures the native
relay and enrolls its test devices. Integration, Details, and performance suites
connect directly to its HTTPS listener. Transport faults use an authenticated
TLS intermediary with its own enrolled upstream certificate; both hops verify
TLS and no bearer token is sent. `tests/tls_fixture.py` retains standalone TLS
endpoints for malformed HTTP/SSE and server-identity negative tests.

`tests/cert_management.py` exercises Linux request → Mac signer/real mkcert →
Linux import, including a correctly signed wrong-SAN certificate and unsafe
retained CSRs. `tests/client_native_tls.py` exercises enrollment, credential
renewal, old/current device revocation with completed relay restart, closure of
pooled HTTP and SSE, saved cursor replay, drafts, and durable send IDs. These
checks use the same relay TLS transport as the Mac, with synthetic message data.
Installed-server verification is described in [macOS TLS operation](macos-tls.md).

The server contract is unchanged API v1 payloads/cursors/request IDs behind a
TLS 1.3, HTTP/1.1 origin. Both API and event connections present the device leaf;
there is no Authorization header. Validate the installed pair, relay restart,
missed-event replay, and revocation before the coordinated cutover. Real sends
still require an explicitly selected and authorized recipient.
