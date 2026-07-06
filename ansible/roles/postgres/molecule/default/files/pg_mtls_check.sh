#!/usr/bin/env bash
# mTLS verification for the postgres role.
#
# Usage: pg_mtls_check.sh <host> <port> <ca> <client_cert> <client_key>
#
# Proves three things against a live postgres:
#   1. a PLAINTEXT connection is rejected (no non-TLS pg_hba path exists)
#   2. a TLS connection WITHOUT a client certificate is rejected
#   3. a client with a cert signed by the CA completes SELECT 1
set -u
host=$1 port=$2 ca=$3 crt=$4 key=$5
base="host=$host port=$port dbname=postgres user=postgres connect_timeout=10"

if psql "$base sslmode=disable" -tAc 'SELECT 1' 2>/dev/null | grep -q 1; then
  echo "FAIL: plaintext connection accepted"; exit 1
fi
if psql "$base sslmode=verify-ca sslrootcert=$ca" -tAc 'SELECT 1' 2>/dev/null | grep -q 1; then
  echo "FAIL: certless TLS connection accepted"; exit 1
fi
out=$(psql "$base sslmode=verify-ca sslrootcert=$ca sslcert=$crt sslkey=$key" -tAc 'SELECT 1') \
  || { echo "FAIL: mTLS connection failed"; exit 1; }
[ "$out" = "1" ] || { echo "FAIL: unexpected result: $out"; exit 1; }
echo "OK: plaintext rejected; certless rejected; mTLS SELECT 1"
