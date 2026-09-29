#ifndef ZIMBR_TLS_POLICY_H
#define ZIMBR_TLS_POLICY_H

/* One shared policy for the relay and every client transport lane. */
// Pin both endpoints to the same authenticated TLS 1.3 suite to avoid negotiation drift.
#define ZIMBR_TLS13_CIPHER "TLS_AES_256_GCM_SHA384"

#endif
