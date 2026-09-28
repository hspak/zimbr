# macOS TLS operation

Start with [two-step setup](setup.md), which configures the installed relay and
enrolls Linux over SSH without a source checkout. Every HTTP/SSE connection requires
TLS 1.3 with `TLS_AES_256_GCM_SHA384`, HTTP/2, and an enabled client certificate. The
[certificate contract](certificate-management.md) defines issuance and validation.

The packaged `zimbr-relay-admin` selects **release** (port 8731). The source
helper `python3 tools/tls_admin.py` defaults to **dev** (port 8732); use
`--profile release` when administering a release install from source. See
[profiles](macos-profiles.md).

## Cipher policy

The relay and native Linux client enable exactly one TLS 1.3 cipher suite:
`TLS_AES_256_GCM_SHA384` (AES-256-GCM authenticated encryption with SHA-384 for
the TLS key schedule and transcript). The shared policy covers API, SSE, and
media connections. Configuration fails closed if the cipher is unavailable;
peers offering only another cipher cannot complete a handshake. Administrative
Python clients negotiate this same cipher with the relay.

Security margin takes priority over peak throughput: AES-256 provides a larger
key-search margin than AES-128. ChaCha20-Poly1305 also has a 256-bit key and is a
strong alternative. AES-GCM benefits from hardware acceleration on Apple Silicon
and modern x86 CPUs; ChaCha20 can be faster on machines without AES acceleration.
This choice does not imply 256-bit security for the whole TLS connection:
authentication and key exchange are negotiated separately, and GCM uses a
128-bit authentication tag. See [TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446.html)
and the [ChaCha20 comparison](https://www.rfc-editor.org/rfc/rfc8439.html#section-1).

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

Provisioning uses Python with `cryptography` and administrative API calls use `h2`
(`tools/requirements-tls.txt`), plus
mkcert 1.4.4. Network tests and Mac API tools require a Python `ssl` module with
TLS 1.3; the Apple system Python/LibreSSL is insufficient.
Provisioning tools are not relay runtime dependencies.

## Provisioning

Run `zimbr-relay-setup relay.example` after installing the cask. It generates
server and Mac administrative credentials with mkcert, installs their
configuration, starts the login service, and verifies the listener. Its defaults:

| Material | Release location |
| --- | --- |
| Dedicated signing CA | `~/Library/Application Support/Zimbr/ca/` |
| Configuration | `~/Library/Application Support/Zimbr/relay.json` |
| Administrative configuration | `~/Library/Application Support/Zimbr/admin.json` |
| Server certificate and key | `~/Library/Application Support/Zimbr/server.pem`, `server-key.pem` |
| Client verification CA and device list | `~/Library/Application Support/Zimbr/ca.pem`, `devices.json` |
| Administrative credentials | `~/Library/Application Support/Zimbr/admin/ca.pem`, `client.pem`, `client-key.pem` |

These locations are fixed; configuration and Settings do not accept credential
paths. Reruns retain the existing configuration, credentials, and enrolled devices.

The installed package needs no files under `~/.config`. Rerunning setup or
enrolling a device moves the former `~/.config/zimbr-release-ca` directory into
`ca/`, preserving the CA certificate and private key. A formerly configured
custom issuer is copied there, leaving the original available to any other
installation sharing it. Migration removes the obsolete `provisioning.json`.
Server and administrative credentials from older layouts are validated and
copied to the fixed locations before their path fields are removed from JSON.
Legacy credential copies remain available for recovery. Migration refuses to
overwrite different credentials already at a fixed destination. The dev profile
migrates independently. Existing clients and server credentials remain valid;
a relay cache reset preserves all credentials.

The bundled `zimbr-relay-admin issue-ssh` accepts the Linux helper's JSON request
on stdin. The authenticated SSH login authorizes the requested device name.
The helper validates the CSR, signs it, enrolls its fingerprint, verifies restart,
and returns only the CA, certificate, and endpoint as JSON. It retains issued
certificates by CSR hash so retries reuse the same identity. The HTTPS API does
not expose certificate enrollment.

For source installations and custom staging, `python3 tools/tls_admin.py setup`
provides `--directory`, `--relay`, `--server-name`, `--listen-address`,
`--name`, and `--port`; see [development setup](development.md). Staging must be
empty. This lower-level command validates credentials but leaves installation
and service startup to the source installer.

The CA stays in the private data directory, outside the source and app bundle.
Never copy its `rootCA-key.pem` into the bundle or onto Linux. Do not run
`mkcert -install` or reuse a broadly
trusted development CA. mkcert uses a dedicated `CAROOT` and its `-csr` mode;
client authentication purpose comes from the validated CSR, not `-client`.

All security paths must be absolute without symlinks. On macOS, use a private
folder in your home or `/private/tmp`, since `/tmp` is a symlink. Keys,
certificates, allowlists and configurations are 0600 files in owned 0700
directories. The installer stops the old relay before replacing credentials at
their fixed locations outside the app. Separate source-installer staging can be
removed after verifying the installed credentials.
Keep the signing CA for renewal and device issuance.

For Linux requests, `issue-device` combines validated signing, enrollment and
verified service restart. Its output directory contains only the public CA and
issued device certificate. It verifies that the profile's fixed signing CA
matches the installed relay CA. The signing commands select the issuer by
`--profile`; there is no `--caroot` override.
Use the lower-level `create-key`, `sign`, `enroll`, and `revoke` commands from the
[certificate contract](certificate-management.md) for custom administration.

`relay.json` contains `listen_address`, `port`, and `server_name`.
Optional `contacts_phone_region` provides national-number
context. Use relay Settings to edit these fields with validation.
The allowlist contains objects with `label`, `sha256` (64 hexadecimal digits over
the entire leaf DER), and `enabled`. An empty list admits nobody; invalid or
duplicate entries prevent startup. The limit is 256 devices.

`admin.json` contains only `relay_url`; its credentials live under `admin/`.
Administrative API tools use the same mTLS policy as Linux.
The local `doctor` command needs no administrative certificate.

## Code signing and installation

This section applies to source builds. Homebrew already installs a signed app.
For development, run once in Terminal on the Mac, without sudo:

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

Follow [development setup](development.md#2-generate-credentials-and-install-on-the-mac) for the
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
zimbr-relay-admin enroll --cert /private/import/new-client.pem \
  --label 'Linux desktop'
# Reconnect with the new Linux credential, then retire the old fingerprint:
zimbr-relay-admin revoke --sha256 OLD_64_HEX_FINGERPRINT
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
key/CSR. Stage the new certificate and key beside a relay config, validate them,
then stop the relay, replace `server.pem` and `server-key.pem`, and restart. Reconnect
clients afterwards. CA replacement requires a coordinated explicit trust update.
Enrollment uses SSH, with no HTTPS enrollment endpoint, OCSP/CRL service, or
automatic renewal. Read
actual certificate expiry; `doctor` warns within 30 days for the server or CA.
Client devices monitor their own leaf expiry. Active requests/SSE sessions close
when their certificate validity expires, including CA/server validity.

## Verification

Run the native build and unit suite, `tests/integration.py`, `tests/relay_tls.py`,
`tests/cert_management.py`, and `tests/mac_acceptance_test.py`. Use temporary
certificates and synthetic message data for transport and fault tests.

For an installed deployment, verify the app signature, configured listener,
TLS 1.3/HTTP/2 negotiation with `TLS_AES_256_GCM_SHA384`, explicit CA and hostname
checks, and rejection of other ciphers, plaintext, missing client certificates,
and revoked devices. The TLS tests require the OpenSSL CLI to exercise peers
restricted to AES-128-GCM and ChaCha20-Poly1305. Check both HTTP and
SSE connections, including closure and reauthentication after renewal/revocation.

Verify permissions under the installed app identity and preserve epoch, message
IDs, durable send records, and cursor replay across upgrades and restarts.
Keep backups, endpoint configuration, certificate inventories, and acceptance
evidence in private administrative storage outside the public repository.

## HTTP/2 transport

The relay requires ALPN `h2` and rejects HTTP/1 and missing ALPN. The session
adapter is adapted from [zhtps](https://github.com/hspak/zhtps) at commit
`621bb2e70a4810a8ac0ed46f203ec8013559d3a5`; Zig fetches and statically builds pinned
nghttp2 1.70.0 sources. No system nghttp2 installation is required by the relay.
The signed app includes its license.

Each authenticated connection owns at most 16 streams and accepts at most 64
requests before graceful shutdown. Decoded headers are capped at 16 KiB per
block, request bodies at 64 KiB, and nghttp2 allocations at 1 MiB per connection.
Application response storage remains separately bounded by the API's page, image,
and SSE batch limits. The existing global limits of eight SSE streams and four
image responses include streams waiting for HTTP/2 window credit. A stalled
response expires after ten seconds; resetting one stream releases its resources
without terminating other streams. A connection owner checks pending events at
most every 50 ms and produces another journal batch only after the prior batch
has drained.

Install `tools/requirements-tls.txt` for the administrative HTTP/2 client and wire
tests. After building `fake-relay`, run `python3 tests/relay_http2.py` alongside the
existing relay and client integration suites. Wire-specific tests cover ALPN
rejection, simultaneous SSE and commands, flow control, oversized headers,
request deadlines, graceful connection rotation, and body limits without
Content-Length.
