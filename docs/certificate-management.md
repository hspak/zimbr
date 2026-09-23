# Certificate management contract

The Mac administrator owns the Zimbr CA, issuance policy, and device allowlist.
This document and `tools/tls_admin.py` define the certificate contract for all
clients. Client provisioning must follow it. The relay does not accept online
enrollment requests; signing and enrollment are separate administrative actions.

## Issuance profile

Generate each private key on the device that will use it. The standard profile
is ECDSA P-256, an unencrypted PKCS#8 PEM key, and a PEM PKCS#10 CSR signed with
SHA-256. The signer also accepts EC keys of at least 256 bits and RSA keys of at
least 2048 bits. Verify the CSR signature before issuance.

| Extension | Client CSR | Server CSR |
| --- | --- | --- |
| Basic Constraints | Critical, `CA:FALSE`, no path length | Same |
| Key Usage | Critical, `digitalSignature` | Same |
| Extended Key Usage | Exactly `clientAuth` | Exactly `serverAuth` |
| Subject Alternative Name | Explicit administrator-selected DNS label, for example `linux-desktop.zimbr.invalid` | Exact DNS names/IP addresses clients use to reach the relay |

EKU and SAN are noncritical in generated CSRs. No other CSR extensions are
accepted. The signer forbids certificate/CRL signing, key agreement, data
encipherment, and content commitment usages; `keyEncipherment` is tolerated but
is not requested by our generators. Issued leaves may additionally contain
Subject Key Identifier and Authority Key Identifier. Unknown extensions fail
validation.

Use precise ASCII DNS names without wildcards. The signer compares the entire
SAN set with the administrator's explicit `--name` arguments; no missing or extra
names are allowed. For clients, use one stable device label under `zimbr.invalid`.
It need not resolve. Client subjects and SANs are descriptive metadata:
**authorization uses SHA-256 over the entire leaf certificate's DER**, not the
Common Name, SAN, public key hash, or certificate serial number. Renewal produces
a new fingerprint that must be enrolled.

Explicit client SANs are required at issuance because mkcert 1.4.4 otherwise
invents a SAN from the CSR's Common Name. Clients must request the selected SAN
and accept that same SAN in the returned certificate, checking it against their
locally retained CSR. Do not silently discard a SAN or accept an arbitrary new
one during import.

## CSR exchange and Mac administration

The client sends only `client.csr` and the requested device label through the
existing authenticated administrative channel. Keep its private key on the
client. Put the received CSR in a private directory, with mode 0600, and confirm
the intended SAN independently of the untrusted CSR contents. On the Mac:

```sh
python3 tools/tls_admin.py sign --role client \
  --caroot "$HOME/.config/zimbr-ca-admin" \
  --csr /private/import/linux-desktop/client.csr \
  --cert /private/import/linux-desktop/client.pem \
  --name linux-desktop.zimbr.invalid --mkcert /path/to/mkcert
python3 tools/tls_admin.py enroll \
  --cert /private/import/linux-desktop/client.pem --label 'Linux desktop'
```

Replace the example paths and label. `sign` validates the request, invokes
mkcert with `-csr` using isolated staging files, and verifies the issued leaf's
CA, purpose, validity, SANs, and public key before publishing it. Never combine
`-csr` and `-client`. Its JSON output reports the leaf's `sha256` and `expires`.
Only `enroll` grants access: it validates and atomically updates the allowlist,
restarts the installed LaunchAgent, and verifies old-process exit and the new
listener. Signing a certificate alone does not grant access.

Return the issued `client.pem`, the **public** `rootCA.pem`, and the expected
endpoint, for example `https://relay.example:8731` (a placeholder). Authenticate
the CA's entire-DER SHA-256 fingerprint through trusted SSH or an independent
channel before import:

```sh
openssl x509 -in "$HOME/.config/zimbr-ca-admin/rootCA.pem" \
  -noout -fingerprint -sha256
```

The client must verify the authenticated CA fingerprint, signatures and validity,
non-CA leaf constraints, exact clientAuth EKU, allowed extensions and usages,
expected SANs, and match to its local private key before replacing runtime
certificates. Store runtime credentials and configuration in owned 0700
directories with 0600 files; reject symlinks, hardlinks, and unsafe ancestors.
Use the explicit CA exclusively for TLS, verify the server's endpoint SAN, and
present the device leaf on every TLS 1.3 HTTP/1.1 connection, including SSE.

The dedicated signing `CAROOT` stays outside the repository, app bundle, and
runtime directories. Its `rootCA-key.pem` remains on the administrator's Mac.
Never run `mkcert -install` or reuse a broadly trusted development CA. Existing
Python/cryptography, mkcert 1.4.4, and OpenSSL tooling is sufficient; no new
service or dependency is required for this workflow. Setup commands are documented in [macOS TLS operation](macos-tls.md).

## Renewal and revocation

Generate a fresh key/CSR in a new directory on the client. Sign and import it
under the same rules, enroll the new fingerprint, reconnect using the new
credential, then revoke the old fingerprint:

```sh
python3 tools/tls_admin.py revoke --sha256 OLD_LEAF_DER_SHA256
```

Enrollment/revocation restarts the relay and closes existing HTTP and SSE
connections. Reconnect must reload client credentials and use fresh TLS state.
`--stage` only writes policy; it does not complete enrollment or revocation.
Preserve journal/cache/drafts/outbox state and original send request IDs through
renewal. Read the actual certificate expiry; do not assume a fixed lifetime.
CA replacement requires a coordinated explicit trust update on every device.

## Client handoff

The Linux helper implements this profile with `request --name DEVICE.zimbr.invalid`.
Its import verifies the returned SAN against its locally retained, signed CSR and
checks both against the local private key. See [Linux setup](linux-mtls.md) for
commands. Real-mkcert round trips run in `tests/cert_management.py`; native relay
worker coverage runs in `tests/client_native_tls.py` and the converted client
integration/fault/Details/performance suites. The original handoff findings and
resolution are recorded in [the integration review](linux-mtls-review.md).
