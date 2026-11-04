#!/usr/bin/env bash
# Only for an ephemeral CI Docker daemon. No customer state or credentials.
set -euo pipefail
candidate=june-callback-candidate:verified
receipts=${1:?receipt directory required}
mkdir -p "$receipts"
cid=
cleanup() { if [[ -n "$cid" ]]; then docker rm --force --volumes "$cid" >/dev/null; fi; }
trap cleanup EXIT
# The runtime loader itself must accept the built binary in the inherited OS.
docker run --rm --network none --cpus 4 --memory 8g --pids-limit 512 \
  --entrypoint /convex/convex-local-backend "$candidate" --help > "$receipts/backend-help.txt"
docker run --rm --network none --cpus 1 --memory 1g \
  --entrypoint /bin/sh "$candidate" -ec 'ldd /convex/convex-local-backend; node --version' > "$receipts/abi.txt"
if grep -q 'not found' "$receipts/abi.txt"; then exit 1; fi
# Public disposable test fixture, never a production instance secret.
cid=$(docker run --detach --network none --cpus 4 --memory 8g --pids-limit 512 \
  --tmpfs /convex/data:rw,size=2g --tmpfs /tmp:rw,size=512m \
  -e INSTANCE_NAME=june-callback-acceptance \
  -e INSTANCE_SECRET=0101010101010101010101010101010101010101010101010101010101010101 \
  -e CONVEX_CLOUD_ORIGIN=http://127.0.0.1:3210 \
  -e CONVEX_SITE_ORIGIN=http://127.0.0.1:3211 \
  -e DISABLE_BEACON=1 -e DO_NOT_REQUIRE_SSL=1 \
  -e NODE_ACTION_USER_TIMEOUT_SECS=1800 -e HTTP_SERVER_TIMEOUT_SECONDS=2100 \
  "$candidate")
healthy=false
for attempt in $(seq 1 90); do
  if docker exec "$cid" curl --fail --silent --max-time 2 http://127.0.0.1:3210/version > "$receipts/version.txt"; then healthy=true; break; fi
  test "$(docker inspect --format '{{.State.Running}}' "$cid")" = true
  sleep 2
done
"$healthy"
docker inspect --format '{{json .State}}' "$cid" > "$receipts/startup-state.json"
printf '%s\n' 'PASS: loader/ABI and empty-data startup health. Nested action runtime acceptance remains untested.' > "$receipts/smoke-result.txt"
