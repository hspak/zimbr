**Direct HTTPS with mandatory mTLS — migration design**

Proposed on 2026-09-23 against the HTTP-through-SSH release. The macOS relay and
Linux client implementations are both present. See [macOS operation](macos-tls.md),
[Linux setup](linux-mtls.md), and the [integration review](linux-mtls-review.md).
The Mac is authoritative for [certificate management](certificate-management.md);
client provisioning must follow that issuance and enrollment contract.
Linux provisioning now matches the Mac contract, and synthetic worker suites
exercise the native relay directly. Installed two-host acceptance remains a
separate deployment check.
There is no compatibility listener or automatic downgrade. The HTTP v1 payloads, durable cursors, send request IDs,
relay journal, client cache, and drafts retain their current semantics.

The target connection is:

```text
Linux GUI / libcurl ── HTTPS + client certificate ── Mac relay / OpenSSL
                                                    │
                                              Messages integration
```

Use TLS 1.3 and HTTP/1.1, including the existing SSE stream. Terminate TLS inside
the relay through a small C wrapper around OpenSSL 3.5 LTS. This fits the existing
C transport boundary and lets the Linux fake relay exercise the same server
implementation. It also leaves one Mac service to install and restart. OpenSSL
3.5 has upstream support through April 2030; package current patches within that
series. [OpenSSL release policy](https://openssl-library.org/policies/releasestrat/)

Ensure the client can reach the relay over a private network. Configure a stable DNS name and an explicit LAN or private-network listening
address. This design does not require opening a router port. An SSH config alias
is not necessarily a DNS name; choose the actual reachable hostname before
issuing the server certificate and verify direct TCP reachability. If SSH
currently depends on a jump host, arrange a private route first. Bind failures
are errors, with no wildcard fallback. Examples below use `relay.example` as a
placeholder.

Shared certificate and authorization decisions:

- Use mkcert as a setup-time issuer with a dedicated Zimbr `CAROOT`. Trust its
  public CA certificate explicitly in each application; do not run
  `mkcert -install` or reuse a broadly trusted development CA. mkcert is intended
  for development and supplies neither our authorization policy nor automated
  certificate lifecycle. Its limited role here is a deliberate choice for this
  private, manually administered installation.
- Generate the Mac and Linux private keys on their respective machines. Use
  mkcert's CSR signing support from a protected administrator directory. The
  Linux CSR requests `clientAuth`; the Mac CSR requests `serverAuth` and the
  precise DNS/IP subject alternative names used by clients. Verify the issued
  certificates' purposes and SANs before installation. `-csr` cannot be combined
  with `-client`, so encode the client purpose in the CSR itself.
- Only CSRs, issued certificates, and the public `rootCA.pem` move between
  machines. Authenticate the initial CA transfer using the existing trusted SSH
  connection or a verified fingerprint. Keep `rootCA-key.pem` out of runtime
  directories, installers, source control, and client distributions; retain it
  in protected administrative storage for renewal.

These issuance and isolation mechanisms are supported by
[mkcert's documentation](https://github.com/FiloSottile/mkcert#advanced-topics).
Its [CSR implementation](https://github.com/FiloSottile/mkcert/blob/master/cert.go)
copies requested certificate extensions, including EKU. Signing tooling must
require a non-CA leaf, the intended purpose and SANs, and reject unexpected
extensions rather than blindly signing arbitrary CSRs.

Each device has its own leaf certificate. The relay requires both a valid chain
to the dedicated CA and an enabled entry matching the SHA-256 fingerprint of the
entire leaf certificate's DER encoding. Labels and certificate subject names are
display metadata, not authorization. All enabled devices access the same single
Messages account. This replaces the bearer token entirely; a second shared
secret would add another provisioning and rotation path without device identity.

Store private keys and security configuration in owner-only files inside 0700
directories. Reject unsafe file ownership, permissions, symlinks, missing keys,
and certificate/key mismatches. The leaf keys can be unencrypted on disk under
these protections so GUI startup and launchd restart do not require a prompt.
Do not put key contents in arguments, logs, or diagnostics.

**Linux client steps**

1. **Replace the connection configuration.** In `src/client/Config.zig`, replace
   `port` and `token_file` with `relay_url`, `ca_file`, `client_cert_file`, and
   `client_key_file`, with matching CLI overrides. Require an HTTPS origin with
   a hostname and optional port; reject userinfo, query strings, fragments, and
   non-root paths. Report old transport fields as obsolete instead of silently
   using localhost. Preserve appearance, data directory, and editor settings.

   Example configuration, using absolute paths in the actual file:

   ```json
   {
     "relay_url": "https://relay.example:8731",
     "ca_file": "/home/USER/.config/zimbr/tls/ca.pem",
     "client_cert_file": "/home/USER/.config/zimbr/tls/client.pem",
     "client_key_file": "/home/USER/.config/zimbr/tls/client-key.pem"
   }
   ```

2. **Configure libcurl for every request and stream.** Change
   `src/client/bridge.c` and `bridge.h` to accept the HTTPS origin and certificate
   configuration instead of a token and port. Set the CA, client certificate,
   and private key; require peer and hostname verification, TLS 1.3, HTTPS-only
   protocols, and HTTP/1.1. Disable redirects and proxies as today. Ensure the
   selected libcurl TLS backend trusts only the supplied CA, including disabling
   any native/default CA-directory fallback; prove this with a negative test.
   Check every TLS option result and fail setup on an unsupported backend.
   Reuse connections within one credential configuration, then destroy the
   connection pool when credentials are reloaded. libcurl already supplies
   [client certificate](https://curl.se/libcurl/c/CURLOPT_SSLCERT.html) and
   [CA file](https://curl.se/libcurl/c/CURLOPT_CAINFO.html) options.

3. **Make connection failures diagnosable.** Preserve `CURLcode`, verification
   results, and a bounded diagnostic message across the C/Zig boundary. Today
   `zc_net_poll` largely collapses failures to HTTP status zero. Update
   `src/client/Worker.zig` and `SharedSnapshot.zig` to distinguish DNS/network
   failures, server trust/hostname failures, local credential problems, explicit
   client-certificate rejection, and relay HTTP errors. Explicit certificate or
   configuration failures wait for corrected credentials and Reconnect;
   transient network failures retain bounded backoff. An ambiguous TLS error
   must not be presented as a proven certificate rejection. Reconnect reloads
   the credential files and clears stale TLS connections.

4. **Retain recovery and update the interface.** Keep saved SSE cursors,
   heartbeats, offline drafts, and recovery by the original send request ID. A
   failed connection after submitting a send must still resolve that request's
   outcome before any new submission. Replace SSH/token wording in
   `src/client_main.zig` with endpoint, mTLS status, certificate fingerprint and
   expiry, and actionable failure details. Warn 30 days before expiry. Treat
   credential renewal as a connection change, never a cache reset.

5. **Convert all client consumers.** Update `client-probe`, client integration,
   transport-fault, Details, and performance harnesses to use temporary CA and
   device certificates. Fault servers must themselves speak authenticated TLS
   when testing HTTP/SSE behavior. Update Linux installation/setup instructions
   and provide a provisioning helper for local key/CSR creation and importing
   the verified CA/certificate. No test-only plaintext mode belongs in the
   production client.

Linux is complete when the real worker connects directly, rejects incorrect
server identity, presents its certificate on API and SSE connections, recovers
from network interruptions, and uses the existing cache and outbox unchanged.

**macOS server steps**

1. **Add explicit TLS configuration and packaging.** Extend `src/main.zig` with
   a relay configuration containing the listen address/port, server certificate,
   server key, client CA, and device allowlist. `setup` continues initializing
   private state and the journal but stops creating a token. `serve` validates
   all TLS material and the allowlist before opening its listener. An empty
   allowlist admits nobody; malformed or unreadable configuration prevents
   startup. Extend `doctor` with certificate/key matching, trust/purpose checks,
   validity, enabled-device count, and expiry warnings.

   Add a relay-only TLS C module and update `build.zig` to link OpenSSL 3.5.
   For the Mac app, statically link the library into the relay so the installed
   app does not depend on a Homebrew path. Support an explicit target OpenSSL
   prefix for native and cross builds. Rebuild and re-sign when shipping OpenSSL
   security updates. The Linux fake relay uses the same TLS wrapper and policy.

2. **Authenticate before parsing HTTP.** In `src/relay/Server.zig`, cap accepted
   connections before performing a TLS handshake, then require a valid client
   chain, client-authentication purpose, validity dates, and enabled leaf
   fingerprint. Reject unauthorized peers before calling the HTTP parser. Use
   OpenSSL's standard verification with
   `SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT`; custom allowlist checks
   may only add rejection, never override a chain-verification failure.
   [OpenSSL verification behavior](https://docs.openssl.org/3.5/man3/SSL_CTX_set_verify/)

   Keep the current connection, stream, request-size, and send limits. Add a
   small separate handshake concurrency limit and a five-second handshake
   deadline so incomplete handshakes cannot occupy every application slot.
   All routes, including status and events, require mTLS. Local tools use a
   separately enrolled administrative client certificate when calling the API;
   direct local `doctor` checks do not require network access.

3. **Replace raw socket I/O beneath the existing parser.** Adapt
   `src/relay/Transport.zig` to use a TLS connection object. The C wrapper owns
   handshake, reads, writes, buffered TLS data, peer identity, and bounded
   shutdown. Use nonblocking sockets and monotonic deadlines; handle both
   `WANT_READ` and `WANT_WRITE` for each operation. Preserve the existing
   ten-second request/write deadlines. Replace raw socket peeking in the SSE
   loop with TLS-aware closure/error handling and heartbeat writes. Do not
   read application bytes directly from the socket after TLS starts: OpenSSL
   maintains its own buffering and read/write readiness requirements.
   [OpenSSL read semantics](https://docs.openssl.org/3.5/man3/SSL_read/)

4. **Replace token rotation with device lifecycle.** Remove token generation,
   `rotate-token`, bearer-header validation, and token checks in SSE heartbeats.
   Keep the authenticated peer identity on the connection. Check certificate
   validity before accepting each HTTP request and at least every heartbeat
   interval on SSE; close expired sessions.

   Device enrollment, renewal, and revocation are local administrative actions.
   Write the allowlist atomically, validate it, then restart the LaunchAgent to
   apply it. Revocation is complete only after the old process has exited and
   the new configuration is active, closing existing API connections and SSE
   streams. The helper must report a failed restart, not claim success. Already
   accepted durable sends retain their normal recovery semantics.

   Initially disable TLS session resumption and early data. Every connection
   must reauthenticate; this avoids tickets preserving access after a policy
   change and avoids early-data replay concerns for sends. For TLS 1.3 set the
   ticket count to zero and disable the session cache; `SSL_OP_NO_TICKET` alone
   is insufficient. [OpenSSL ticket controls](https://docs.openssl.org/3.5/man3/SSL_CTX_set_num_tickets/)

5. **Update installation and Mac tools.** Change `packaging/macos/install.py` to
   install the TLS configuration and public trust material, retain private
   state, and start the configured HTTPS listener. Keep the existing bundle ID,
   app location, and LaunchAgent identity. Update `tools/read_only_smoke.py`,
   `tools/mac_acceptance.py`, and their tests to use verified HTTPS and a client
   certificate. Neither tool gets a localhost authentication bypass. Revalidate
   Full Disk Access and Automation under the installed identity because this
   repository's Mac acceptance record shows ad-hoc rebuilds can require grants
   to be refreshed.

macOS is complete when the signed installed relay serves only authenticated TLS,
starts after user login, rejects unenrolled devices before HTTP, and revocation
closes both new and already established access.

Certificate maintenance remains deliberately small. Renewal issues a new leaf
from a locally generated key/CSR, stages and validates the replacement, and
updates the enabled fingerprint for a client certificate. A brief overlap of old
and new client fingerprints is permitted for renewal; remove the old one after
the new credential succeeds. Server renewal keeps the chosen hostname and CA.
Restart the relay and reconnect the client to apply replacements. Read actual
certificate expiry dates rather than assuming a lifetime from mkcert. CA
replacement is another coordinated trust update on both machines. No online CA,
enrollment endpoint, CRL service, or OCSP service is needed for this deployment.

**Implementation and cutover order**

1. Add certificate-fixture/provisioning support and the relay TLS wrapper; prove
   the fake relay's authenticated transport on Linux and a native Mac build.
2. Implement server authentication/configuration and client HTTPS/error handling
   against the agreed contract. Convert the existing harnesses and remove the
   old transport/token code in the same change. Intermediate commits need not
   support mixed old/new installations.
3. Run the acceptance checks below using synthetic data. Prepare both release
   artifacts and actual certificates before touching the running installation.
4. Quit the client and stop the relay briefly; take consistent backups of its
   journal and the client state. Install both new builds/configurations, start
   the relay on the chosen address and port, then launch Linux against its DNS
   name. Preserve the existing journal epoch, cursor, outbox, and request IDs.
5. Confirm status, history, and SSE recovery with the installed identities;
   perform any real-message send only with an explicitly selected/authorized
   recipient. Exercise a network interruption and relay restart, then check
   missed-event replay and send recovery.
6. Stop/remove the Zimbr tunnel and its startup entry, if present. Delete the
   obsolete Zimbr token files and transport configuration. Rewrite the active
   README/DESIGN instructions; label historical validation records appropriately.
   Removing Zimbr's tunnel does not require disabling SSH used for administration.

The expected downtime is one coordinated restart. No database migration or new
server epoch is required. If deployment fails, keep the service stopped while
repairing configuration; any emergency restoration uses a matched previous
client/server pair and preserved state, not a plaintext fallback in the new code.

Acceptance criteria for the migration:

| Area | Required evidence |
| --- | --- |
| Authentication | Missing certificate, unrelated CA, expired/not-yet-valid leaf, wrong EKU, valid-but-unlisted leaf, revoked leaf, and bearer-only access are rejected before an API handler runs |
| Server identity | Linux rejects an unrelated CA, incorrect DNS/IP SAN, expired server certificate, HTTP URL, and an attempted redirect; explicit CA trust does not also accept system roots |
| Configuration | Missing/mismatched/unsafe key material and obsolete client transport fields produce actionable errors, with no weaker fallback |
| Resource handling | Stalled handshakes, partial TLS records, slow reads/writes, abrupt EOF, and clean TLS closure respect concurrency/deadline bounds; slots are released and handshake work cannot occupy every application slot |
| Live recovery | SSE resumes from the durable cursor after relay/network failure; accepted sends resolve using their original IDs without duplicate dispatch |
| Device lifecycle | Renewal works; revocation plus completed restart ends an existing SSE stream and pooled HTTP connection and rejects reconnect/resumption attempts |
| Persistence | Journal epoch, cached history, drafts, and pending/uncertain sends survive the cutover |
| Packaging | Linux worker/fault suites and native signed macOS LaunchAgent checks pass with the production TLS path; installed Mac permissions are confirmed |

Run the existing Zig unit suites and converted Python integration/transport
suites, plus targeted TLS negative tests. Temporary test CAs stay within each
test directory and are never installed in system trust stores. Preserve the
existing synthetic-source protections and real-send authorization boundaries.
