#!/usr/bin/env bash
# Generate dev nkeys + permissions from the api-specs event schemas, then start the stack.
# Usage: dev/up.sh [path-to-api-specs/events] ; env GO_COMMON_DIR points at the go-common clone.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${1:-}" ]; then
  events="$1"
elif [ -d "$here/../../api-specs-p2/events" ]; then
  events="$here/../../api-specs-p2/events" # the Phase 2 specs checkout, as in up-full.sh
else
  events="$here/../../api-specs/events"
fi
gocommon="${GO_COMMON_DIR:-$here/../../go-common}"
conf="${HOSTRY_NATS_CONF_DIR:-$here/.nats}"
(cd "$gocommon" && go run ./cmd/busdev -events "$events" -out "$conf")
HOSTRY_NATS_CONF_DIR="$conf" docker compose -f "$here/compose.yaml" up -d --wait
echo "NATS on 127.0.0.1:${HOSTRY_NATS_PORT:-4222}; seeds in $conf/seeds (gitignored)"
