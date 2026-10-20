#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# A distinct project owns every resource, including the locally built image.
project="tricklepay-smoke-$(date +%s)-$$"
compose=(docker compose -p "$project" -f docker-compose.smoke.yml --profile test)
export STREAM_CONTRACT_ID="${STREAM_CONTRACT_ID:-CDMB62RVYAXJJNYYH7K442SHSAJIXTZ6K7JANGSMQF2T7MHCTVSK75SW}"
container=""

cleanup() {
  result=$?
  trap - EXIT
  if (( result != 0 )); then
    if [[ -n "$container" ]]; then
      docker inspect --format '{{json .State}}' "$container" >&2 || true
    fi
    "${compose[@]}" logs --no-color >&2 || true
  fi
  if ! "${compose[@]}" down --volumes --rmi local --timeout 10; then
    echo "Smoke check cleanup failed for project $project." >&2
    if (( result == 0 )); then result=1; fi
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"${compose[@]}" build api
"${compose[@]}" up -d --wait --wait-timeout 60 postgres-test
"${compose[@]}" up -d api
container=$("${compose[@]}" ps -a -q api)
if [[ -z "$container" ]]; then
  echo "Smoke check failed: API container was not created." >&2
  exit 1
fi

deadline=$((SECONDS + 120))
while (( SECONDS < deadline )); do
  state=$(docker inspect --format '{{.State.Status}}' "$container")
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container")
  if [[ "$state" == running && "$health" == healthy ]]; then
    echo "Docker smoke check passed: API container is healthy."
    exit 0
  fi
  if [[ "$state" != running || "$health" == unhealthy || "$health" == missing ]]; then
    echo "Smoke check failed: API state=$state health=$health." >&2
    exit 1
  fi
  sleep 2
done

echo "Smoke check failed: API did not become healthy within 120 seconds." >&2
exit 1
