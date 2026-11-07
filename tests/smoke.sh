#!/usr/bin/env bash
# Checks the gateway must pass (Annex F, "Cómo se verifica"). Run against a running gateway:
#   GATEWAY_URL=http://localhost:8080 FRONT=down bash tests/smoke.sh   # front, portals, services down
#   GATEWAY_URL=http://localhost:8080 FRONT=up   bash tests/smoke.sh   # front, portals, services up
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

# ADR-017, HU-PLAT-010: /status/<service> → that service's GET /health, GET only, no credential.
for service in auth catalog chat transactions workflow; do
  request "/status/$service" -H 'Authorization: Bearer smoke-token'
  if [ "$FRONT" = up ]; then
    check "/status/$service answers the $service service's /health" \
      '[ "$status" = 200 ] && [ "$(field status)" = UP ]'
    check "/status/$service never forwards the caller's credential" \
      'grep -q "\"authorization\":\"\"" <<< "$body"'
  else
    check "with the $service service down, /status/$service answers 503 with the error body" \
      '[ "$status" = 503 ] && [ "$(field error)" = SERVICE_UNAVAILABLE ]'
  fi
done

request /status/catalog -X POST
check "/status/<service> accepts GET only" '[ "$status" = 405 ]'
request /status/payments
check "a service that does not exist answers 404 with the error body" \
  '[ "$status" = 404 ] && [ "$(field error)" = NOT_FOUND ]'
request /status/catalog/anything
check "/status/<service> reaches /health and nothing else" \
  '[ "$status" = 404 ] && [ "$(field error)" = NOT_FOUND ]'

# E4b (ADR-017, Annex F): /api/v1/catalog/ → catalog-api. The token is validated by the service;
# the gateway only rejects a protected route that arrives without Authorization (cheap filter).
expect_unauthorized() {
  check "$1 answers 401 with the error body" \
    '[ "$status" = 401 ] && [ "$(field error)" = UNAUTHORIZED ] && [ "$(field message)" = "Debe iniciar sesión para continuar." ]'
  check "$1: the 401 carries WWW-Authenticate and its traceId is the X-Correlation-Id" \
    '[ "$(header WWW-Authenticate)" = Bearer ] && [ "$(field traceId)" = "$(header X-Correlation-Id)" ]'
}
request /api/v1/catalog/products/mine
expect_unauthorized "GET /api/v1/catalog/products/mine (E-12) without Authorization"
request /api/v1/catalog/products -X POST -H 'Content-Type: application/json' -d '{}'
expect_unauthorized "POST /api/v1/catalog/products (E-13) without Authorization"
request /api/v1/catalog/products/0000/photo -X DELETE
expect_unauthorized "DELETE on a catalog route without Authorization"

# E4b-2 (ADR-017, Annex F): /api/v1/transactions/ → transactions-api. Every card needs a token except
# the provider's webhook (E-43): its checksum is the authentication, checked by the service (ADR-019).
request /api/v1/transactions/mine
expect_unauthorized "GET /api/v1/transactions/mine (E-42) without Authorization"
request /api/v1/transactions/0000
expect_unauthorized "GET /api/v1/transactions/{id} (E-41) without Authorization"
request /api/v1/transactions/admin/transactions
expect_unauthorized "GET /api/v1/transactions/admin/transactions (E-44) without Authorization"
request /api/v1/transactions/webhooks/payment-gateway
expect_unauthorized "GET on the webhook path (only POST is the anonymous E-43) without Authorization"
request /internal/v1/transactions -X POST -H 'Authorization: Bearer smoke-token'
check "/internal/v1/transactions (I-06) is never routed: 404 with the error body (D-C27)" \
  '[ "$status" = 404 ] && [ "$(field error)" = NOT_FOUND ]'

# F6 (HU-AUTH-002, ADR-017): /api/v1/auth/ → auth-api. Anonymous cards: E-01, E-02, E-03 (POST) and
# E-05 (GET); the rest (E-04, E-06, E-07, E-08) needs Authorization. I-01 is internal: never routed.
request /api/v1/auth/users/0000
expect_unauthorized "GET /api/v1/auth/users/{id} (E-08) without Authorization"
request /api/v1/auth/logout -X POST
expect_unauthorized "POST /api/v1/auth/logout (E-04) without Authorization"
request /api/v1/auth/farm-profile
expect_unauthorized "GET /api/v1/auth/farm-profile (E-06) without Authorization"
request /api/v1/auth/login
expect_unauthorized "GET on the login path (only POST is the anonymous E-02) without Authorization"
request /internal/v1/auth/service-token -X POST -H 'Content-Type: application/json' -d '{}'
check "/internal/v1/auth/service-token (I-01) is never routed: 404 with the error body (D-C27)" \
  '[ "$status" = 404 ] && [ "$(field error)" = NOT_FOUND ]'

request /internal/v1/catalog/products/0000
check "/internal/ is never routed: 404 with the error body (D-C27)" \
  '[ "$status" = 404 ] && [ "$(field error)" = NOT_FOUND ]'

request /api/v1/catalog/products -X OPTIONS -H 'Origin: http://localhost:5173' \
  -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization,idempotency-key'
check "the preflight from the container's dev origin answers 204 (no credential needed)" '[ "$status" = 204 ]'
check "the preflight allows that origin" '[ "$(header Access-Control-Allow-Origin)" = http://localhost:5173 ]'
check "the preflight allows Idempotency-Key and Authorization" \
  'grep -qi "Idempotency-Key" <<< "$(header Access-Control-Allow-Headers)" && grep -qi "Authorization" <<< "$(header Access-Control-Allow-Headers)"'
request /api/v1/catalog/products -X OPTIONS -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: POST'
check "an unknown origin gets no Access-Control-Allow-Origin" '[ -z "$(header Access-Control-Allow-Origin)" ]'

if [ "$FRONT" = up ]; then
  request /api/v1/catalog/products -H 'Origin: http://localhost:5173' -H 'X-Correlation-Id: smoke-catalog-1'
  check "GET /api/v1/catalog/products (E-10) is anonymous and reaches catalog-api" \
    '[ "$status" = 200 ] && [ "$(field path)" = /api/v1/catalog/products ]'
  check "catalog-api receives the same X-Correlation-Id" '[ "$(field correlationId)" = smoke-catalog-1 ]'
  check "the response exposes X-Correlation-Id and Location to the container's origin" \
    'grep -qi "X-Correlation-Id" <<< "$(header Access-Control-Expose-Headers)" && grep -qi "Location" <<< "$(header Access-Control-Expose-Headers)"'
  request /api/v1/catalog/products/0000
  check "GET /api/v1/catalog/products/{id} (E-11) is anonymous" '[ "$status" = 200 ]'
  request /api/v1/catalog/categories
  check "GET /api/v1/catalog/categories (E-19) is anonymous" '[ "$status" = 200 ]'
  request /api/v1/catalog/units
  check "GET /api/v1/catalog/units (E-20) is anonymous" '[ "$status" = 200 ]'
  # E-62 (D-C30): /media/ → catalog-api, anonymous (an <img> sends no token), its cache kept.
  request /media/0123456789abcdef0123456789abcdef.png
  check "GET /media/{key} (E-62) is anonymous and reaches catalog-api, not the front" \
    '[ "$status" = 200 ] && grep -q "^photo of [^:]*: /media/0123456789abcdef0123456789abcdef.png" <<< "$body"'
  check "the photo keeps the Cache-Control of catalog-api" '[ "$(header Cache-Control)" = "public, max-age=86400" ]'
  check "the photo keeps the headers of every response" '[ "$(header X-Frame-Options)" = DENY ]'

  # D-C30: a photo is up to 5 MB (catalog-api answers 413 above it); past the gateway's 6 MB the
  # gateway itself refuses it, with the same body. The file goes through stdin: no path for curl.
  big="$(mktemp)"
  head -c $((7 * 1024 * 1024)) /dev/zero > "$big"
  request /api/v1/catalog/products/0000/photo -X POST -H 'Authorization: Bearer smoke-token' \
    -H 'Content-Type: application/octet-stream' --data-binary @- < "$big"
  rm -f "$big"
  check "a body over 6 MB answers 413 with the error body" \
    '[ "$status" = 413 ] && [ "$(field error)" = PAYLOAD_TOO_LARGE ] && [ "$(field message)" = "La imagen supera el máximo de 5 MB." ]'
  check "the 413 traceId is the X-Correlation-Id" '[ "$(field traceId)" = "$(header X-Correlation-Id)" ]'

  request /api/v1/catalog/products -X POST -H 'Authorization: Bearer smoke-token' -H 'X-User-Id: someone-else'
  check "a write with Authorization reaches catalog-api with the credential" \
    '[ "$status" = 200 ] && [ "$(field authorization)" = "Bearer smoke-token" ]'
  check "X-User-* never reaches a service (D-C28)" '[ -z "$(field xUserId)" ] && grep -q "\"xUserId\":\"\"" <<< "$body"'

  request /api/v1/transactions/webhooks/payment-gateway -X POST -H 'Content-Type: application/json' \
    -d '{"event":"transaction.updated"}'
  check "POST /api/v1/transactions/webhooks/payment-gateway (E-43) is anonymous and reaches transactions-api" \
    '[ "$status" = 200 ] && [ "$(field path)" = /api/v1/transactions/webhooks/payment-gateway ]'
  request /api/v1/transactions/mine -H 'Authorization: Bearer smoke-token' -H 'X-User-Id: someone-else' \
    -H 'X-Correlation-Id: smoke-transactions-1'
  check "GET /api/v1/transactions/mine with Authorization reaches transactions-api with the credential" \
    '[ "$status" = 200 ] && [ "$(field path)" = /api/v1/transactions/mine ] && [ "$(field authorization)" = "Bearer smoke-token" ]'
  check "transactions-api receives the same X-Correlation-Id and no X-User-*" \
    '[ "$(field correlationId)" = smoke-transactions-1 ] && grep -q "\"xUserId\":\"\"" <<< "$body"'

  # (method path card) in variables: inside check, $1 and $2 are check's own arguments.
  for card in "POST /api/v1/auth/login E-02" "POST /api/v1/auth/register E-01" "GET /api/v1/auth/jwks E-05"; do
    read -r method path name <<< "$card"
    if [ "$method" = GET ]; then request "$path"; else request "$path" -X POST -H 'Content-Type: application/json' -d '{}'; fi
    check "$method $path ($name) is anonymous and reaches auth-api without a credential" \
      '[ "$status" = 200 ] && [ "$(field path)" = "$path" ] && grep -q "\"authorization\":\"\"" <<< "$body"'
  done
  request /api/v1/auth/users/0000 -H 'Authorization: Bearer smoke-token' -H 'X-User-Role: ADMIN'
  check "GET /api/v1/auth/users/{id} with Authorization reaches auth-api with the credential and no X-User-*" \
    '[ "$status" = 200 ] && [ "$(field path)" = /api/v1/auth/users/0000 ] && [ "$(field authorization)" = "Bearer smoke-token" ] && grep -q "\"xUserId\":\"\"" <<< "$body"'

  # Last: it uses up this client's write allowance (a general per-IP ceiling on writes, cross-cutting §9).
  limited=""
  for _ in $(seq 1 40); do
    request /api/v1/catalog/products -X POST -H 'Authorization: Bearer smoke-token'
    [ "$status" = 429 ] && { limited=yes; break; }
  done
  check "past the write limit, a write answers 429" '[ "$limited" = yes ]'
  check "the 429 carries the error body and Retry-After" \
    '[ "$(field error)" = TOO_MANY_REQUESTS ] && [ "$(field message)" = "Demasiadas solicitudes. Intente de nuevo más tarde." ] && [ -n "$(header Retry-After)" ]'
  request /api/v1/catalog/products
  check "reads are not limited by the write ceiling" '[ "$status" = 200 ]'
else
  request /api/v1/catalog/products
  check "with catalog-api down, /api/v1/catalog/ answers 503 with the error body" \
    '[ "$status" = 503 ] && [ "$(field error)" = SERVICE_UNAVAILABLE ]'
  request /media/0123456789abcdef0123456789abcdef.png
  check "with catalog-api down, /media/ answers 503 with the error body" \
    '[ "$status" = 503 ] && [ "$(field error)" = SERVICE_UNAVAILABLE ]'
  request /api/v1/transactions/mine -H 'Authorization: Bearer smoke-token'
  check "with transactions-api down, /api/v1/transactions/ answers 503 with the error body" \
    '[ "$status" = 503 ] && [ "$(field error)" = SERVICE_UNAVAILABLE ]'
  request /api/v1/transactions/webhooks/payment-gateway -X POST -d '{}'
  check "with transactions-api down, the webhook answers 503 (the provider retries)" \
    '[ "$status" = 503 ] && [ "$(field error)" = SERVICE_UNAVAILABLE ]'
  request /api/v1/auth/login -X POST -H 'Content-Type: application/json' -d '{}'
  check "with auth-api down, the login answers 503 with the error body" \
    '[ "$status" = 503 ] && [ "$(field error)" = SERVICE_UNAVAILABLE ]'
fi

request /portals/unknown/remoteEntry.js
check "a portal that does not exist answers 404 with the error body" \
  '[ "$status" = 404 ] && [ "$(field error)" = NOT_FOUND ]'

echo
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
