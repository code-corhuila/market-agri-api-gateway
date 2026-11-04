# market-agri-api-gateway

The single entry point of the **Marketplace Agrícola Huila** distributed system: declarative NGINX
(Annex F), the only service that publishes a port to the host. Sub-task: HU-PLAT-001.
Governance and documentation: [`market-agri-docs`](https://github.com/code-corhuila/market-agri-docs).

## What it does

| Path | Goes to | Notes |
|---|---|---|
| `GET /health` | the gateway itself | `{"status":"UP"}` (api-contract E-60) |
| `/api/v1/catalog/…` | `catalog-api:8080` | E-10, E-11, E-19, E-20 anonymous; any other route without `Authorization` → `401 UNAUTHORIZED` from the gateway (the service validates the token, ADR-020); `X-User-*` stripped (D-C28) |
| `GET /media/{key}` | `catalog-api:8080` | The photos of the catalog (E-62), anonymous with no credential filter (an `<img>` cannot send a token, D-C30); catalog-api sets `Cache-Control` |
| `/api/…` not claimed by a route | the gateway itself | `404 NOT_FOUND` with the common error body |
| `/internal/…` | the gateway itself | `404 NOT_FOUND`: the internal API is reached inside the platform only (D-C27) |
| `/portals/<name>/…` (`auth`, `catalog`, `transactions`) | `<name>-portal:80`, prefix stripped | The portals in the same origin (ADR-017); `remoteEntry.js` and the manifest answer `Cache-Control: no-store`; any other name under `/portals/` is `404` |
| `/` and every other path | `front:80` (`market-agri-front`) | The web interface, same origin as the API |

Every response carries `X-Correlation-Id` (the client's, if safe; otherwise a generated UUID),
which is also forwarded to the service and written in the JSON access log. A service that does not
answer gives `503 SERVICE_UNAVAILABLE` on its routes only: names are resolved on every request.
Every response also forbids framing (`X-Frame-Options`, CSP `frame-ancestors`).
A body over 6 MB (`client_max_body_size`; a photo is up to 5 MB) is refused with `413
PAYLOAD_TOO_LARGE` and the same error body.

On the API routes (`snippets/api.conf`): CORS only for the container's dev origin
(`http://localhost:5173`; on the platform everything is one origin), with `Idempotency-Key` allowed
and `X-Correlation-Id` and `Location` exposed; and a per-IP ceiling on writes (30 per minute, burst
10) that answers `429 TOO_MANY_REQUESTS` with `Retry-After`. Each domain adds its
`routes/<domain>.conf` and its credential filter in `10-security.conf`. The full
Content-Security-Policy (now `'self'`: one origin) arrives in a later branch.

## Structure (Annex F)

```
nginx/nginx.conf               global settings, JSON log with correlationId, body size
nginx/conf.d/00-resolver.conf  Docker DNS on every request
nginx/conf.d/10-security.conf  X-Correlation-Id, CORS origin, write limit, credential filters
nginx/conf.d/20-server.conf    the server, its own errors with the common body, the routes
nginx/snippets/                headers of every response; what every proxied request carries; API routes
nginx/routes/                  one file per destination
tests/smoke.sh                 the checks of Annex F, run by ci.yml against the built image
deploy/                        Dockerfile and compose.yml (included by market-agri-infra)
```

## Run and test locally

```bash
docker network create platform-dev            # once
docker build -f deploy/Dockerfile -t market-agri-api-gateway:dev .
docker run -d --rm --name api-gateway --network platform-dev -p 8000:8080 market-agri-api-gateway:dev
GATEWAY_URL=http://localhost:8000 FRONT=down bash tests/smoke.sh
```

Inside the platform it is started by `market-agri-infra` (`docker compose --env-file env/dev.env up`).

## Branches

`develop` ← `feat/…`, `fix/…`, `chore/…` · `qa` ← promotion · `main` ← `release/…`, `hotfix/…`.
Rules: `market-agri-docs/00-governance/git-conventions.md`.
