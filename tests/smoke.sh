#!/usr/bin/env bash
# Checks the gateway must pass (Annex F, "Cómo se verifica"). Run against a running gateway:
#   GATEWAY_URL=http://localhost:8080 FRONT=down bash tests/smoke.sh   # front and portals not running
#   GATEWAY_URL=http://localhost:8080 FRONT=up   bash tests/smoke.sh   # front and portals running
set -uo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
FRONT="${FRONT:-up}"
UUID='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
failures=0

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# request <path> [curl args…]: fills $status, $body and $headers.
request() {
  local path="$1"; shift
  headers_file="$(mktemp)"
  body="$(curl -s -o - -D "$headers_file" -w '\n%{http_code}' "$@" "$GATEWAY_URL$path")"
  status="${body##*$'\n'}"
  body="${body%$'\n'*}"
  headers="$(tr -d '\r' < "$headers_file")"
  rm -f "$headers_file"
}
header() { grep -i "^$1:" <<< "$headers" | head -1 | cut -d' ' -f2-; }
# field <name>: a top-level string field of the last JSON body, e.g. field error. Plain sed, so the
# test needs only bash and curl (Git Bash on Windows has no python3).
field() { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' <<< "$body"; }

request /health
check "/health answers 200" '[ "$status" = 200 ]'
check "/health body is {\"status\":\"UP\"}" '[ "$(field status)" = UP ]'

check "every response forbids framing (X-Frame-Options)" '[ "$(header X-Frame-Options)" = DENY ]'
check "every response forbids framing (CSP frame-ancestors)" \
  '[ "$(header Content-Security-Policy)" = "frame-ancestors '"'"'none'"'"'" ]'

request /api/v1/no-such-domain/things
check "an unknown API route answers 404" '[ "$status" = 404 ]'
check "the 404 carries the common error body" '[ "$(field error)" = NOT_FOUND ]'
check "the 404 message is the contract one" '[ "$(field message)" = "El recurso solicitado no existe." ]'
check "the 404 traceId equals the X-Correlation-Id header" '[ "$(field traceId)" = "$(header X-Correlation-Id)" ]'

request /health
check "without X-Correlation-Id the gateway generates a UUID and returns it" '[[ "$(header X-Correlation-Id)" =~ $UUID ]]'

request /health -H 'X-Correlation-Id: smoke-0001-kept'
check "a valid X-Correlation-Id from the client is kept" '[ "$(header X-Correlation-Id)" = smoke-0001-kept ]'

request /health -H 'X-Correlation-Id: bad value with spaces'
check "an unsafe X-Correlation-Id is replaced by a generated one" '[[ "$(header X-Correlation-Id)" =~ $UUID ]]'

request /
if [ "$FRONT" = up ]; then
  check "/ is served by the front container" '[ "$status" = 200 ] && grep -q "market-agri-front" <<< "$body"'
  request /any/client/route
  check "any other path is proxied to the front, not answered by the gateway" \
    '! grep -q NOT_FOUND <<< "$body"'
else
  check "with the front down, / answers 503" '[ "$status" = 503 ]'
  check "the 503 carries the common error body" '[ "$(field error)" = SERVICE_UNAVAILABLE ]'
  request /health
  check "with the front down, the gateway stays healthy" '[ "$status" = 200 ]'
fi

# ADR-017: each portal under /portals/<name>/, prefix stripped, remoteEntry.js never cached.
for name in auth catalog transactions; do
  request "/portals/$name/remoteEntry.js"
  if [ "$FRONT" = up ]; then
    check "/portals/$name/remoteEntry.js is the $name portal's, without the prefix" \
      '[ "$status" = 200 ] && grep -q "$name-portal remoteEntry" <<< "$body"'
    check "/portals/$name/remoteEntry.js is never cached" '[ "$(header Cache-Control)" = no-store ]'
    check "/portals/$name/remoteEntry.js keeps the headers of every response" \
      '[ "$(header X-Frame-Options)" = DENY ] && [ -n "$(header X-Correlation-Id)" ]'
    request "/portals/$name/assets/chunk.js"
    check "/portals/$name/assets/ reaches the $name portal and may be cached" \
      '[ "$status" = 200 ] && grep -q "$name-portal chunk" <<< "$body" && [ "$(header Cache-Control)" != no-store ]'
  else
    check "with the $name portal down, /portals/$name/ answers 503 with the error body" \
      '[ "$status" = 503 ] && [ "$(field error)" = SERVICE_UNAVAILABLE ]'
  fi
done

request /portals/unknown/remoteEntry.js
check "a portal that does not exist answers 404 with the error body" \
  '[ "$status" = 404 ] && [ "$(field error)" = NOT_FOUND ]'

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
