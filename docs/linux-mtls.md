# Linux TLS operation

Use [AUR client setup](linux-setup.md) for an installed client, or
[development setup](development.md) when building from source. The helper
ships with Python cryptography, OpenSSH, and OpenSSL 3 dependencies in AUR.
mkcert runs on the Mac issuer; Linux generates and retains its own key and CSR.
The installed helper is `zimbr-provision`; from a checkout use
`python3 packaging/linux/provision.py`.

## Import and configuration

Normal setup uses `zimbr-provision setup user@relay.example`. The packaged Mac
helper signs and enrolls over the authenticated SSH session, verifies the relay
restart, and returns the public CA, device certificate, and HTTPS endpoint.
Linux verifies the response and saves the connection before opening the client.
Only CSR metadata and public certificates cross SSH; private keys stay local.
Retries keep the same key and reuse the certificate issued for that CSR.

For manual exchange without SSH, use the lower-level commands below.

The [certificate contract](certificate-management.md) defines the validated CSR
and certificate profile. `request --tls-dir PATH --name DEVICE.zimbr.invalid`
creates the local P-256 key and retained CSR; it refuses to overwrite a key.
The Mac's `issue-device` signs that request with mkcert and enrolls its leaf
fingerprint. Return only the issued certificate and public CA over authenticated
SSH, or authenticate the CA fingerprint independently.

`import` verifies the CA pin, signatures, validity, exact clientAuth purpose,
allowed extensions, SANs, and match to the local CSR/private key. Optional
`--relay-url HTTPS_ORIGIN --launch EXECUTABLE` opens client Settings with the
verified paths filled in. Close an existing client first, then click **Save and
connect** to persist them. Without `--launch`, import only installs certificates
and prints their paths. There is no client JSON file to maintain.

Runtime files must be owned 0600 regular files in owned 0700 directories, with
no symlinks or hardlinks and no unsafe writable ancestors. These checks apply to
parent components too. Use the exact server hostname/IP covered by its SANs;
SSH forwarding configuration does not replace certificate identity checks.

Dev uses `~/.config/zimbr-dev/tls` in the setup guide and stores its database in
`$XDG_STATE_HOME/zimbr-dev` or `~/.local/share/zimbr-dev`. Release uses `zimbr`.
`setup` chooses this directory automatically and honors `XDG_CONFIG_HOME`;
the lower-level commands require `--tls-dir`. Provision the profiles independently. See
[client configuration](linux-client.md#provisioning-and-configuration) for launch
overrides and state paths.

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
credential snapshot. Changing paths or the endpoint in Settings and saving reconnects
automatically. Renewal does not clear the cache, drafts, cursor, or outbox.

For renewal, close Zimbr and select a new private directory:

```sh
zimbr-provision setup user@relay.example --tls-dir "$HOME/.config/zimbr/tls-renewed"
```

This creates and enrolls a new key/certificate and saves its paths, preserving
the cache and drafts. Verify the new fingerprint in Details, then retire the old
one on the Mac with `zimbr-relay-admin revoke --sha256 OLD_LEAF_DER_SHA256`.
A brief overlap of enabled fingerprints is allowed. Manual request/import and
Settings changes remain available. Server renewal retains its hostname and CA;
CA replacement requires a coordinated trust update.

An interrupted POST remains uncertain until lookup by its original UUID; a new
send is kept as a draft while that lookup is outstanding. An authoritative
not-found result is shown as
unconfirmed and is never automatically resubmitted. Back up the client database
with the application stopped before changing deployments.

## Linux verification and server handoff

The client requires libcurl **8.10 or newer with HTTP/2 and the OpenSSL 3 backend**, plus
OpenSSL development headers. Unsupported TLS backends fail closed. Every curl
option is checked. Peer/hostname verification, TLS 1.3 with only
`TLS_AES_256_GCM_SHA384`, HTTPS protocols only, HTTP/2, disabled redirects/proxies,
and disabled TLS session caching apply to API, SSE, and media connections. See the
[cipher choice and tradeoffs](macos-tls.md#cipher-policy). An OpenSSL callback
replaces the entire trust store, including default lookup methods, with the
configured dedicated CA.
Connections are reused only inside one immutable credential configuration.
Only `h2` is offered through ALPN. A pre-request callback also verifies the
negotiated protocol before sending any request, including on reused connections.
SSE and commands can share one connection.

The native `fake-relay` and relay unit tests require OpenSSL **3.5 LTS** headers
and libraries, matching the server wrapper. If the Linux system libraries use a
different minor version, supply a target OpenSSL 3.5 build using
`-Dopenssl-prefix=/absolute/openssl-3.5` in the command below. See
[the relay build instructions](macos-tls.md#build).

```sh
zig build test relay client client-probe fake-relay
python3 tests/cert_management.py  # real mkcert required; ZIMBR_MKCERT may override its path
python3 tests/bootstrap.py        # package-only setup; simulated SSH/launchd, real certificates
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
is installed in system trust stores. The TLS rejection tests also use the
OpenSSL CLI to constrain peers to individual TLS 1.3 ciphers and verify rejection
of AES-128-GCM and ChaCha20-Poly1305. `tests/relay_fixture.py` configures the native
relay and enrolls its test devices. Integration, Details, and performance suites
connect directly to its HTTPS listener. Transport faults use an authenticated
TLS intermediary with its own enrolled upstream certificate; both hops verify
TLS. `tests/tls_fixture.py` retains standalone TLS
endpoints for malformed HTTP/SSE and server-identity negative tests.

`tests/cert_management.py` exercises Linux request → Mac signer/real mkcert →
Linux import, including a correctly signed wrong-SAN certificate and unsafe
retained CSRs. `tests/client_native_tls.py` exercises enrollment, credential
renewal, old/current device revocation with completed relay restart, closure of
pooled HTTP and SSE, saved cursor replay, drafts, and durable send IDs. These
checks use the same relay TLS transport as the Mac, with synthetic message data.
Installed-server verification is described in [macOS TLS operation](macos-tls.md).

The server contract is unchanged API v1 payloads/cursors/request IDs behind a
TLS 1.3, HTTP/2 origin. Both API and event connections present the device leaf;
there is no Authorization header. Validate the installed pair, relay restart,
missed-event replay, and revocation when validating a deployment. Real sends
still require an explicitly selected and authorized recipient.
