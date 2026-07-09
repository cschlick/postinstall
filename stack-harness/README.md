# stack-harness — the whole postmodern stack on podman, locally

A one-command local bring-up of the full stack — **db_accounts, db_chat, nats,
accounts, chat, seed** — built from your local source, wired over **mutual TLS**
exactly like the mesh deploy, with **no GHCR, no Vultr, no WireGuard**. It's the
fast pre-flight for a real `pmdeploy stack`: every app-level failure we hit on real
boxes (client-key perms, mTLS DSN, DB provisioning, NATS certs, the message
pipeline) surfaces here in seconds instead of per-deploy.

## What it stands up (suffix groups a run; default `dev`)

| container | image | role |
|---|---|---|
| `db_accounts_<suf>` / `db_chat_<suf>` | baked-cert postgres:17 | **mTLS** Postgres (`hostssl clientcert=verify-ca`), one db each |
| `nats_<suf>` | nats:latest | **mTLS** NATS/JetStream (`verify:true`) |
| `accounts_<suf>` | built from `postmodern-accounts` | account plane, `:8766`, dev mode |
| `chat_<suf>` | built from `postmodern-server` | chat plane, `:8765`, backbone = mTLS PG + mTLS NATS + nats object store |
| `seed_<suf>` | built from `postmodern-server` (Containerfile.seed) | one-shot demo-world seeder |

The mTLS is real: a local CA issues server certs SAN'd to the container names and
one **client cert** (the `mesh_client` stand-in) that accounts/chat/seed present to
Postgres and NATS. Dev mode means the cross-plane keys default to matching dev
values, so no key-gen — the certs under test are the real thing.

## Use

```sh
./up.sh            # or ./up.sh <suffix> — build, issue certs, bring up, health-gate
./seed.sh          # populate a demo world (SEED_SMALL=0 ./seed.sh for the big one)
./down.sh          # tear down that suffix
```

Prereqs: `podman`, and the three source repos as siblings of `postinstall/`
(override with `PM_ACCOUNTS` / `PM_SERVER` / `PM_API`).

Log in as the seeded tester by pointing a client at `chat_<suf>:8765` /
`accounts_<suf>:8766` on the `harness_<suf>` network — the seed prints
`/login acct-tester harness-pass-1234` and a tour of what it built.

## The `wire` overlay (and a real bug it exposes)

`up.sh` copies the **current** `postmodern-api/wire.py` into the app images
(`Containerfile.wire`), so the harness tests local HEAD across repos. This matters:
the app images pin `wire` to an **older release tarball** that lacks
`personal_board` / `PERSONAL_BOARD_PREFIX`, which `postmodern-server/server.py`
calls on **every message publish** — so with the pinned wire, every `say()` throws
`AttributeError`, nothing reaches JetStream, and the seed fails at the first
`poll()`. The real fix lives in postmodern-server: bump the `wire` pin in
`requirements.txt` to a `postmodern-api` release that includes those symbols, then
rebuild the chat/seed images. The harness overlay both proves that fix and lets the
stack run green today.

## Not covered (by design)

WireGuard / greasewood enrollment and the anchor CA — the harness swaps those for a
podman network + a local CA. It validates the **application + mTLS wiring**; the
overlay/enrollment layer is validated by the real `pmdeploy` path.
