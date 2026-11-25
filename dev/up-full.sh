#!/usr/bin/env bash
# Phase 2 full local stack: infra in Docker (NATS with generated accounts, Postgres with every
# service database), every service as a host process built from its sibling checkout.
# Dev only; nothing here is a deployment (ADR-0001 AM12, no images are published).
#
#   dev/up-full.sh [up]     generate keys and NATS accounts, start infra, provision the bus,
#                           build, migrate and start identity, tenancy, billing, orders, catalog, sync, admin
#   dev/up-full.sh infra    only the Docker part (keys, NATS, Postgres, streams and consumers)
#   dev/up-full.sh status   state and health of every service
#   dev/up-full.sh down     stop the services and remove the containers and volumes
#   dev/up-full.sh stop|start|restart <service>   one service process (fault injection in the soak)
#
# Layout: the repositories are siblings of infra (override with HOSTRY_REPOS_DIR). Each service
# repo may carry an uncommitted go.work for unmerged library branches; GOPRIVATE is set here.
# Generated material (keys, NATS accounts and seeds, binaries, logs, pids) lives in dev/.local, gitignored.
#
# Overrides: HOSTRY_REPOS_DIR, HOSTRY_EVENTS_DIR (api-specs events), GO_COMMON_DIR, HOSTRY_LOCAL_DIR,
# HOSTRY_PG_PORT, HOSTRY_NATS_PORT, HOSTRY_<SERVICE>_PORT, HOSTRY_SYNC_DIRECTORY (identity | stub), HOSTRY_LINKS_ENABLED.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repos="${HOSTRY_REPOS_DIR:-$here/../..}"
gocommon="${GO_COMMON_DIR:-$repos/go-common}"
state="${HOSTRY_LOCAL_DIR:-$here/.local}"
keys="$state/keys"
bin="$state/bin"
logs="$state/logs"
run="$state/run"
natsconf="$state/nats"
compose=(docker compose -f "$here/compose.full.yaml")

if [ -n "${HOSTRY_EVENTS_DIR:-}" ]; then
  events="$HOSTRY_EVENTS_DIR"
elif [ -d "$repos/api-specs-p2/events" ]; then
  events="$repos/api-specs-p2/events"
else
  events="$repos/api-specs/events"
fi

pg_port="${HOSTRY_PG_PORT:-5432}"
nats_port="${HOSTRY_NATS_PORT:-4222}"
pgpass="hostry-dev-only" # throwaway dev credential, see dev/postgres/init
nats_url="nats://127.0.0.1:$nats_port"
sync_directory="${HOSTRY_SYNC_DIRECTORY:-identity}"
links_enabled="${HOSTRY_LINKS_ENABLED:-false}"

p_identity="${HOSTRY_IDENTITY_PORT:-8101}"
p_tenancy="${HOSTRY_TENANCY_PORT:-8102}"
p_admin="${HOSTRY_ADMIN_PORT:-8103}"
p_sync="${HOSTRY_SYNC_PORT:-8104}"
p_catalog="${HOSTRY_CATALOG_PORT:-8105}"
p_orders="${HOSTRY_ORDERS_PORT:-8106}"
p_billing="${HOSTRY_BILLING_PORT:-8107}"
services=(identity tenancy billing orders catalog sync admin)
key_services=(identity tenancy admin sync catalog billing orders)

export GOPRIVATE="${GOPRIVATE:-github.com/hostryhq/*}"

die() { echo "up-full: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

set_env() { export "$1=$2"; }

dsn() { printf 'postgres://%s:%s@127.0.0.1:%s/%s?sslmode=disable' "$1" "$pgpass" "$pg_port" "$2"; }

b64u() { printf '%s' "$1" | xxd -r -p | base64 -w0 | tr '+/' '-_' | tr -d '='; }

genkey() { # path: EC P-256 private key (PKCS#8 PEM) once
  [ -f "$1" ] && return 0
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null
  chmod 600 "$1"
}

genrand() { # path: 32 random bytes, base64
  [ -f "$1" ] && return 0
  (umask 077 && openssl rand -base64 32 >"$1")
}

jwk() { # kid public-key-pem: one JWK object
  local hex
  hex="$(openssl pkey -pubin -in "$2" -outform DER | tail -c 64 | xxd -p -c 128)"
  printf '{"kty":"EC","crv":"P-256","use":"sig","alg":"ES256","kid":"%s","x":"%s","y":"%s"}' \
    "$1" "$(b64u "${hex:0:64}")" "$(b64u "${hex:64:64}")"
}

gen_keys() {
  need openssl
  need xxd
  mkdir -p "$keys/service-pub"
  chmod 700 "$keys"
  local s sep=""
  for s in "${key_services[@]}"; do
    genkey "$keys/$s.key"
    openssl pkey -in "$keys/$s.key" -pubout -out "$keys/service-pub/$s.pub.pem" 2>/dev/null
  done
  {
    printf '{"keys":['
    for s in "${key_services[@]}"; do
      printf '%s' "$sep"
      jwk "$s" "$keys/service-pub/$s.pub.pem"
      sep=","
    done
    printf ']}\n'
  } >"$keys/service-keys.jwks.json"
  # Identity's realm keys are persistent so tokens and JWKS survive a restart.
  for s in tenant vendor pack sync-op; do genkey "$keys/$s.key"; done
  openssl pkey -in "$keys/sync-op.key" -pubout -out "$keys/sync-op.pub.pem" 2>/dev/null
  for s in mac proof totp; do genrand "$keys/$s.b64"; done
}

gen_nats() {
  if [ -f "$natsconf/accounts.conf" ] && [ -z "${HOSTRY_REGEN_NATS:-}" ]; then return 0; fi
  [ -d "$events" ] || die "event schemas not found at $events (set HOSTRY_EVENTS_DIR)"
  [ -d "$gocommon" ] || die "go-common not found at $gocommon (set GO_COMMON_DIR)"
  (cd "$gocommon" && go run ./cmd/busdev -events "$events" -out "$natsconf")
}

start_infra() {
  need docker
  need go
  mkdir -p "$state" "$bin" "$logs" "$run"
  gen_keys
  gen_nats
  HOSTRY_NATS_CONF_DIR="$natsconf" HOSTRY_PG_PORT="$pg_port" HOSTRY_NATS_PORT="$nats_port" \
    "${compose[@]}" up -d --wait
  (cd "$gocommon" && go run ./cmd/busdev -events "$events" -out "$natsconf" -provision "$nats_url")
}

# Environment of each service: one function per service, run in a subshell by launch.
env_identity() {
  export HOSTRY_ENV=dev
  export HOSTRY_IDENTITY_DSN="postgres://hostry:$pgpass@127.0.0.1:$pg_port/identity?sslmode=disable"
  export HOSTRY_IDENTITY_DB_ROLE=identity_app
  export HOSTRY_IDENTITY_LISTEN="127.0.0.1:$p_identity"
  export HOSTRY_IDENTITY_TENANT_KEY_FILE="$keys/tenant.key"
  export HOSTRY_IDENTITY_VENDOR_KEY_FILE="$keys/vendor.key"
  export HOSTRY_IDENTITY_PACK_KEY_FILE="$keys/pack.key"
  export HOSTRY_IDENTITY_MAC_KEY_FILE="$keys/mac.b64"
  export HOSTRY_IDENTITY_PROOF_KEY_FILE="$keys/proof.b64"
  export HOSTRY_IDENTITY_TOTP_KEY_FILE="$keys/totp.b64"
  export HOSTRY_SERVICE_KEYS_DIR="$keys/service-pub"
  export HOSTRY_TENANCY_URL="http://127.0.0.1:$p_tenancy"
  export HOSTRY_SERVICE_SIGNING_KEY_FILE="$keys/identity.key"
  export HOSTRY_OP_SIGNING_PUB_FILE="$keys/sync-op.pub.pem"
  # Test SMS sender and the end-to-end aids (GET /dev/otp/{mobile}); refused outside dev, test and ci.
  export HOSTRY_IDENTITY_SMS=test
  export HOSTRY_IDENTITY_ALLOW_TEST_SMS=1
  export HOSTRY_IDENTITY_DEV_CAPTURE=1
  export HOSTRY_NATS_URL="$nats_url"
  export HOSTRY_NATS_SEED_FILE="$natsconf/seeds/identity.nk"
}

env_tenancy() {
  export TENANCY_ADDR="127.0.0.1:$p_tenancy"
  set_env TENANCY_DB_APP_DSN "$(dsn tenancy_app tenancy)"
  set_env TENANCY_DB_VENDOR_DSN "$(dsn tenancy_vendor tenancy)"
  set_env TENANCY_DB_RELAY_DSN "$(dsn tenancy_relay tenancy)"
  set_env TENANCY_DB_MIGRATE_DSN "$(dsn tenancy_migrator tenancy)"
  export TENANCY_TENANT_JWKS="http://127.0.0.1:$p_identity/v1/jwks"
  export TENANCY_VENDOR_JWKS="http://127.0.0.1:$p_identity/v1/vendor-jwks"
  export TENANCY_SERVICE_KEYS="$keys/service-keys.jwks.json"
  export LINKS_ENABLED="$links_enabled"
  export NATS_URL="$nats_url"
  export NATS_SEED_FILE="$natsconf/seeds/tenancy.nk"
}

env_billing() {
  export BILLING_ADDR="127.0.0.1:$p_billing"
  set_env BILLING_DB_APP_DSN "$(dsn billing_app billing)"
  set_env BILLING_DB_GLOBAL_DSN "$(dsn billing_global billing)"
  set_env BILLING_DB_RELAY_DSN "$(dsn billing_relay billing)"
  set_env BILLING_DB_MIGRATE_DSN "$(dsn billing_migrator billing)"
  export BILLING_TENANT_JWKS="http://127.0.0.1:$p_identity/v1/jwks"
  export BILLING_VENDOR_JWKS="http://127.0.0.1:$p_identity/v1/vendor-jwks"
  export BILLING_SERVICE_KEYS="$keys/service-keys.jwks.json"
  # Approval grants are signed by identity's vendor key; the iss is identity's grant issuer, not the
  # contract example's .invalid host, which is billing's default.
  export BILLING_GRANT_KEYS="http://127.0.0.1:$p_identity/v1/vendor-jwks"
  export BILLING_GRANT_ISSUER=hostry-identity-vendor
  export BILLING_ORDERS_URL="http://127.0.0.1:$p_orders"
  export BILLING_GATEWAY_URL="http://127.0.0.1:$p_sync"
  export BILLING_SERVICE_KEY_FILE="$keys/billing.key"
  export NATS_URL="$nats_url"
  export NATS_SEED_FILE="$natsconf/seeds/billing.nk"
}

env_orders() {
  export ORDERS_LISTEN="127.0.0.1:$p_orders"
  export ORDERS_DB_DSN="postgres://hostry:$pgpass@127.0.0.1:$pg_port/orders?sslmode=disable"
  export ORDERS_DB_ROLE=orders_app
  export ORDERS_MIGRATE=true
  export ORDERS_TENANT_JWKS="http://127.0.0.1:$p_identity/v1/jwks"
  export ORDERS_SERVICE_KEYS="$keys/service-keys.jwks.json"
  set_env ORDERS_PLATFORM_DSN "$(dsn platform_reader platform_meta)"
  export HOSTRY_NATS_URL="$nats_url"
  export HOSTRY_NATS_SEED_FILE="$natsconf/seeds/orders.nk"
}

env_catalog() {
  export CATALOG_ADDR="127.0.0.1:$p_catalog"
  set_env CATALOG_DB_APP_DSN "$(dsn catalog_app catalog)"
  set_env CATALOG_DB_RELAY_DSN "$(dsn catalog_relay catalog)"
  set_env CATALOG_DB_MIGRATE_DSN "$(dsn catalog_migrator catalog)"
  export CATALOG_TENANT_JWKS="http://127.0.0.1:$p_identity/v1/jwks"
  export CATALOG_SERVICE_KEYS="$keys/service-keys.jwks.json"
  export CATALOG_SYNC_URL="http://127.0.0.1:$p_sync"
  export CATALOG_SERVICE_SIGNING_KEY="$keys/catalog.key"
  export NATS_URL="$nats_url"
  export NATS_SEED_FILE="$natsconf/seeds/catalog.nk"
}

env_sync() {
  export SYNC_DB_DSN="postgres://hostry:$pgpass@127.0.0.1:$pg_port/sync?sslmode=disable"
  export SYNC_ADDR="127.0.0.1:$p_sync"
  export SYNC_DIRECTORY="$sync_directory"
  export SYNC_IDENTITY_URL="http://127.0.0.1:$p_identity"
  export SYNC_SERVICE_SIGNING_KEY_FILE="$keys/sync.key"
  export HOSTRY_ENV=dev
  # Outbox relay to NATS with sync's own credential (go-common outbox.Relay).
  export SYNC_NATS_URL="$nats_url"
  export SYNC_NATS_SEED_FILE="$natsconf/seeds/sync.nk"
  if [ "$sync_directory" = stub ]; then
    # The in-process identity stub and its dev registration routes (/dev/v1), only for HOSTRY_SYNC_DIRECTORY=stub.
    export SYNC_DEV_STUB=1
    export SYNC_DEV_REGISTER=1
  else
    # The real directory (ADR-0005 A3.2): identity and tenancy clients, the key that seals the gateway's own ops
    # (public half is in identity's packs, see HOSTRY_OP_SIGNING_PUB_FILE), the service-key registry.
    export SYNC_TENANCY_URL="http://127.0.0.1:$p_tenancy"
    export SYNC_OP_SIGNING_KEY_FILE="$keys/sync-op.key"
    export SYNC_OP_KID=op-1 # the kid identity's packs publish the op-signing public key under
    export SYNC_SERVICE_KEYS="$keys/service-keys.jwks.json"
  fi
}

env_admin() {
  export ADMIN_LISTEN="127.0.0.1:$p_admin"
  export ADMIN_PUBLIC_ORIGIN="http://localhost:$p_admin"
  export ADMIN_IDENTITY_URL="http://127.0.0.1:$p_identity"
  export ADMIN_TENANCY_URL="http://127.0.0.1:$p_tenancy"
  export ADMIN_BILLING_URL="http://127.0.0.1:$p_billing"
  export ADMIN_SERVICE_KEY_FILE="$keys/admin.key"
  if [ -n "${ADMIN_STATIC_DIR:-}" ]; then export ADMIN_STATIC_DIR; fi
}

service_env() {
  case "$1" in
    identity) env_identity ;;
    tenancy) env_tenancy ;;
    billing) env_billing ;;
    orders) env_orders ;;
    catalog) env_catalog ;;
    sync) env_sync ;;
    admin) env_admin ;;
    *) die "unknown service $1" ;;
  esac
}

service_port() {
  case "$1" in
    identity) echo "$p_identity" ;;
    tenancy) echo "$p_tenancy" ;;
    billing) echo "$p_billing" ;;
    orders) echo "$p_orders" ;;
    catalog) echo "$p_catalog" ;;
    sync) echo "$p_sync" ;;
    admin) echo "$p_admin" ;;
    *) die "unknown service $1" ;;
  esac
}

service_pkg() {
  case "$1" in
    identity) echo ./cmd/svc-identity ;;
    orders) echo ./cmd/svc-orders ;;
    sync) echo ./cmd/gateway ;;
    *) echo "./cmd/$1" ;;
  esac
}

service_repo() { echo "$repos/svc-$1"; }

build_service() {
  echo "building $1"
  (cd "$(service_repo "$1")" && go build -o "$bin/$1" "$(service_pkg "$1")")
}

# migrate_service runs `<bin> migrate` for the services that have the subcommand.
migrate_service() {
  echo "migrating $1"
  (service_env "$1" && cd "$(service_repo "$1")" && "$bin/$1" migrate)
}

launch() { # name [args]: start in the background, pid in run/, log in logs/
  local name="$1"
  shift
  (
    service_env "$name"
    cd "$(service_repo "$name")"
    nohup "$bin/$name" "$@" >>"$logs/$name.log" 2>&1 &
    echo $! >"$run/$name.pid"
  )
}

alive() { [ -f "$run/$1.pid" ] && kill -0 "$(cat "$run/$1.pid")" 2>/dev/null; }

wait_healthy() { # name: true when /healthz answers within 60 s
  local i port
  port="$(service_port "$1")"
  for i in $(seq 1 60); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null; then return 0; fi
    alive "$1" || return 1
    sleep 1
  done
  return 1
}

start_services() {
  local s failed=()
  for s in "${services[@]}"; do build_service "$s"; done
  for s in identity tenancy catalog billing; do migrate_service "$s"; done
  # orders migrates at start (ORDERS_MIGRATE=true); sync opens its own store; admin has no database.
  for s in "${services[@]}"; do
    case "$s" in
      identity | tenancy | catalog | billing | orders) launch "$s" serve ;;
      *) launch "$s" ;;
    esac
    # identity first: every other service loads its JWKS at start.
    if wait_healthy "$s"; then
      echo "$s: up on 127.0.0.1:$(service_port "$s")"
    else
      echo "$s: FAILED, last log lines:" >&2
      tail -n 8 "$logs/$s.log" >&2 || true
      failed+=("$s")
    fi
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    die "not running: ${failed[*]} (logs in $logs)"
  fi
}

# svc_ctl stop, start or restart one service process (fault injection in the soak); the binary and logs are the ones `up` made.
svc_ctl() {
  local verb="$1" name="$2"
  case " ${services[*]} " in *" $name "*) ;; *) die "unknown service $name" ;; esac
  if [ "$verb" = stop ] || [ "$verb" = restart ]; then
    if alive "$name"; then kill "$(cat "$run/$name.pid")" 2>/dev/null || true; fi
    for _ in $(seq 1 50); do alive "$name" || break; sleep 0.1; done
    rm -f "$run/$name.pid"
  fi
  if [ "$verb" = start ] || [ "$verb" = restart ]; then
    case "$name" in
      identity | tenancy | catalog | billing | orders) launch "$name" serve ;;
      *) launch "$name" ;;
    esac
    wait_healthy "$name" || die "$name did not become healthy"
  fi
}

status() {
  local s port
  for s in "${services[@]}"; do
    port="$(service_port "$s")"
    if alive "$s"; then
      if curl -fsS -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null; then
        echo "$s: healthy (:$port)"
      else
        echo "$s: running, /healthz not answering (:$port)"
      fi
    else
      echo "$s: stopped"
    fi
  done
  "${compose[@]}" ps --format '{{.Service}}: {{.State}} ({{.Health}})' 2>/dev/null || true
}

stop_all() {
  local s
  for s in "${services[@]}"; do
    if alive "$s"; then kill "$(cat "$run/$s.pid")" 2>/dev/null || true; fi
    rm -f "$run/$s.pid"
  done
  HOSTRY_NATS_CONF_DIR="$natsconf" "${compose[@]}" down -v
}

case "${1:-up}" in
  up)
    start_infra
    start_services
    echo "stack is up; seeds and keys are in $state (gitignored); logs in $logs"
    ;;
  infra) start_infra ;;
  status) status ;;
  down) stop_all ;;
  stop | start | restart) svc_ctl "$1" "${2:?service name}" ;;
  *) die "usage: up-full.sh [up|infra|status|down|stop|start|restart <service>]" ;;
esac
