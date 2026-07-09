#!/usr/bin/env bash
# Local CA for the stack harness: a mesh-CA stand-in. Issues server certs
# (SAN'd to the podman container name so sslmode=verify-full matches) and one
# client cert (the mesh_client stand-in). Every leaf gets serverAuth+clientAuth,
# mirroring greasewood's mesh certs. Regenerate freely — images bake these in.
set -euo pipefail
cd "$(dirname "$0")/certs"
SUFFIX="${1:-dev}"

gen_ca() {
  openssl genpkey -algorithm ED25519 -out ca.key
  openssl req -x509 -new -key ca.key -days 3650 -out ca.crt -subj "/CN=stack-harness-ca" \
    -addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign,cRLSign"
}
leaf() {  # <name> <SAN-dns>
  local name="$1" san="$2"
  openssl genpkey -algorithm ED25519 -out "$name.key"
  openssl req -new -key "$name.key" -out "$name.csr" -subj "/CN=$san"
  openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 \
    -out "$name.crt" -extfile <(printf 'subjectAltName=DNS:%s,DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=digitalSignature,keyEncipherment\n' "$san")
  rm -f "$name.csr"
}
gen_ca
# server certs — SAN = the container name each plane dials (verify-full checks this)
for s in "db_accounts_$SUFFIX" "db_chat_$SUFFIX" "nats_$SUFFIX"; do leaf "$s" "$s"; done
# the mesh_client stand-in (used by accounts/chat/seed as the DB+NATS client identity)
openssl genpkey -algorithm ED25519 -out client.key
openssl req -new -key client.key -out client.csr -subj "/CN=pm"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 \
  -out client.crt -extfile <(printf 'extendedKeyUsage=clientAuth,serverAuth\nkeyUsage=digitalSignature\n')
rm -f client.csr
chmod 644 *.crt; chmod 600 *.key
echo "generated CA + server certs (db_accounts_$SUFFIX, db_chat_$SUFFIX, nats_$SUFFIX) + client cert"
ls -1
