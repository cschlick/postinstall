#!/usr/bin/env bash
# Bring up a full postmodern stack on podman for a given <suffix> (default: dev):
#   db_accounts_<suffix>, db_chat_<suffix>  — mTLS PostgreSQL (client-cert required)
#   nats_<suffix>                           — mTLS NATS/JetStream (verify:true)
#   accounts_<suffix>, chat_<suffix>        — the two planes, dev mode, over mTLS
# Images are built from your LOCAL source (postmodern-accounts / -server / -api);
# certs come from a local CA (mesh-CA stand-in). No GHCR, no Vultr, no WireGuard.
# Health-gated: exits 0 only when both planes serve /healthz. Then run ./seed.sh.
set -euo pipefail
SUF="${1:-dev}"
cd "$(dirname "$0")"; HARNESS="$PWD"; SOFT="$(cd ../.. && pwd)"
ACC="${PM_ACCOUNTS:-$SOFT/postmodern-accounts}"
SRV="${PM_SERVER:-$SOFT/postmodern-server}"
API="${PM_API:-$SOFT/postmodern-api}"
NET="harness_$SUF"; VOL="pmcerts_$SUF"
log(){ printf '\033[1;36m[harness]\033[0m %s\n' "$*"; }
dsn(){ echo "postgresql://pm@$1:5432/$2?sslmode=verify-full&sslrootcert=/etc/pki/pm/ca.crt&sslcert=/etc/pki/pm/client.crt&sslkey=/etc/pki/pm/client.key"; }
for d in "$ACC" "$SRV" "$API"; do [ -d "$d" ] || { echo "missing source repo: $d (set PM_ACCOUNTS/PM_SERVER/PM_API)"; exit 1; }; done

log "using current shared wire from $API"
cp "$API/wire.py" "$HARNESS/wire.py"

log "building app images from source (accounts, chat, seed) + current wire..."
podman build -q -t h_accounts_base -f "$ACC/Containerfile" "$ACC" >/dev/null
podman build -q -t h_chat_base     -f "$SRV/Containerfile" "$SRV" >/dev/null
podman build -q -t h_seed_base     -f "$SRV/Containerfile.seed" "$SRV" >/dev/null
for a in accounts chat seed; do
  podman build -q --build-arg BASE=h_${a}_base -f Containerfile.wire -t h_$a . >/dev/null
done

log "issuing certs (CA + server certs SAN'd to container names + client cert)..."
./gen-certs.sh "$SUF" >/dev/null
log "building mTLS postgres images (baked certs)..."
podman build -q -f Containerfile.pg --build-arg SRV=db_accounts_$SUF --build-arg DBNAME=account -t h_pg_accounts_$SUF . >/dev/null
podman build -q -f Containerfile.pg --build-arg SRV=db_chat_$SUF     --build-arg DBNAME=chat    -t h_pg_chat_$SUF . >/dev/null

podman network exists "$NET" 2>/dev/null || podman network create "$NET" >/dev/null
podman volume rm -f "$VOL" >/dev/null 2>&1 || true; podman volume create "$VOL" >/dev/null
# client identity owned by the container uid (10001), key 0600 — the mesh_client stand-in
podman run --rm --user 0 -v "$VOL:/pki" -v "$HARNESS/certs:/src:ro" docker.io/library/busybox \
  sh -c 'cp /src/client.crt /src/client.key /src/ca.crt /pki/ && chown -R 10001:10001 /pki && chmod 600 /pki/client.key'

for c in seed_$SUF chat_$SUF accounts_$SUF db_chat_$SUF db_accounts_$SUF nats_$SUF; do podman rm -f "$c" >/dev/null 2>&1 || true; done
log "starting backbone: nats, db_accounts, db_chat..."
podman run -d --name nats_$SUF --network "$NET" \
  -v "$HARNESS/certs/nats_$SUF.crt:/certs/server.crt:ro" -v "$HARNESS/certs/nats_$SUF.key:/certs/server.key:ro" \
  -v "$HARNESS/certs/ca.crt:/certs/ca.crt:ro" -v "$HARNESS/nats/nats-server.conf:/etc/nats/nats-server.conf:ro" \
  docker.io/library/nats:latest -c /etc/nats/nats-server.conf -js >/dev/null
podman run -d --name db_accounts_$SUF --network "$NET" -e POSTGRES_HOST_AUTH_METHOD=trust h_pg_accounts_$SUF >/dev/null
podman run -d --name db_chat_$SUF     --network "$NET" -e POSTGRES_HOST_AUTH_METHOD=trust h_pg_chat_$SUF >/dev/null

for db in db_accounts_$SUF db_chat_$SUF; do
  log "waiting for $db to accept connections..."
  for i in $(seq 1 45); do podman exec "$db" pg_isready -q -U postgres 2>/dev/null && break; sleep 1
    [ "$i" = 45 ] && { echo "$db never became ready"; podman logs "$db" 2>&1 | tail -15; exit 1; }; done
done

log "starting planes: accounts, chat (over mTLS)..."
podman run -d --name accounts_$SUF --network "$NET" -v "$VOL:/etc/pki/pm:ro" \
  -e ACCOUNT_PORT=8766 -e ACCOUNT_DB_URL="$(dsn db_accounts_$SUF account)" h_accounts >/dev/null
podman run -d --name chat_$SUF --network "$NET" -v "$VOL:/etc/pki/pm:ro" \
  -e CHAT_PORT=8765 -e CHAT_DB_URL="$(dsn db_chat_$SUF chat)" \
  -e NATS_URL="tls://nats_$SUF:4222" -e NATS_TLS_CERT=/etc/pki/pm/client.crt \
  -e NATS_TLS_KEY=/etc/pki/pm/client.key -e NATS_TLS_CA=/etc/pki/pm/ca.crt \
  -e CHAT_OBJECT_STORE=nats -e CHAT_BODY_STORE=nats -e CHAT_BOT_CLAIM_SECRET=harness-bot-claim h_chat >/dev/null

for p in accounts_$SUF:8766 chat_$SUF:8765; do
  log "waiting for $p /healthz..."
  ok=0; for i in $(seq 1 45); do
    podman run --rm --network "$NET" docker.io/curlimages/curl:latest -sf "http://$p/healthz" >/dev/null 2>&1 && { ok=1; break; }; sleep 2; done
  [ "$ok" = 1 ] || { echo "ERROR: $p never healthy"; podman logs "${p%%:*}" 2>&1 | tail -20; exit 1; }
done

log "STACK UP (suffix=$SUF) — accounts:8766, chat:8765, both healthy over mTLS."
log "  seed a demo world:   ./seed.sh $SUF"
log "  tear down:           ./down.sh $SUF"
