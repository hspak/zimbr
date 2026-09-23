# Linux mTLS integration review

Reviewed the initial client mTLS migration on 2026-09-23 after pulling
it into the macOS worktree. The Mac implementation was preserved. Linux binaries
and GUI tests were not run on this host.

The server is authoritative for certificate management. The chosen
[certificate contract](certificate-management.md) retains strict CSR validation,
an explicit client device SAN, a dedicated Mac-held CA, and leaf-fingerprint
enrollment. The Linux implementation should adapt to that contract. Existing
Mac tooling is sufficient.

## P1: provisioning cannot complete with the Mac issuer

`packaging/linux/provision.py:request` creates a clientAuth CSR without a SAN.
`tools/tls_admin.py sign` requires an explicit expected `--name` and rejects that
CSR with `SANs do not exactly match the administrator-selected names`.

Bypassing the Mac helper does not resolve the mismatch: signing that CSR with
mkcert 1.4.4 adds a SAN from its Common Name. The Linux helper's
`import_certificate` extension allowlist excludes Subject Alternative Name and
rejects the issued certificate with `Unexpected extension in client certificate`.
Both failures were reproduced using the actual Linux helper and real mkcert,
with a temporary dedicated CA and matching device key; no CA was installed into
system trust.

Required client changes:

1. Accept an explicit device SAN, for example `linux-desktop.zimbr.invalid`, and
   include it in the clientAuth CSR. The administrator passes that same name to
   the Mac signer. Keep human-readable labels separate from authorization.
2. Allow SAN on import and validate its exact contents against the local CSR,
   retaining CA pin, signature, purpose, dates, extensions, and key-match checks.
3. Exercise a real mkcert issuance round trip. The current client test copies
   CSR extensions using its own signer and therefore misses mkcert's SAN
   behavior. The Mac regression is `tests/cert_management.py`.

The Mac signer will not relax its validation to accept the old no-SAN CSR.

## P1: integration harnesses still require the removed HTTP/token relay

`tests/client_integration.py`, `tests/client_transport.py`,
`tests/client_details.py`, and `tests/performance.py` start `fake-relay` using
`--port` and read a generated `relay/token`. `tests/tls_fixture.py:RelayTLS`
then forwards to it using plaintext HTTP and a bearer token.

The native fake relay now uses the production mandatory TLS transport: pass
`--config` with private server credentials, a CA, an enabled-device allowlist,
and the explicit listen address/port. `setup` no longer creates a token.
Running `tests/client_integration.py` against the merged Mac fake relay fails
immediately with `relay: InvalidArguments`, before any Linux binary is launched.

Required client test changes:

1. Use `tests/relay_fixture.py:Fixture` (or equivalent native relay configuration)
   and start the fake relay with `--config`, as `tests/integration.py` does.
2. Connect the real worker directly to that HTTPS origin for ordinary
   integration, Details, and performance coverage. Enroll its test leaf.
3. Where fault injection needs an intermediary, authenticate its upstream TLS
   connection to the fake relay too. Remove token and plaintext assumptions.
   The standalone `TLSServer` can remain for synthetic HTTP/SSE failure cases.

The independently added server fixture was renamed to `tests/relay_fixture.py`
while retaining the incoming client `tests/tls_fixture.py`; this preserves both
test implementations without treating the old adapter as compatible.

## Acceptance scope

The merged native relay/fake-relay build and Zig unit suite pass, along with all
11 native TLS tests, 3 Mac helper tests, 2 real-mkcert certificate tests, and the
native integration suite. Formatting, changed-test syntax, and diff checks pass.
These are separate from the Linux runtime suites; installed-server verification is
described in [macOS TLS operation](macos-tls.md). Linux must verify its own build,
the corrected provisioning/import flow, direct Mac reachability, worker/GUI
behavior, reconnect, replay, and revocation against the installed pair.

