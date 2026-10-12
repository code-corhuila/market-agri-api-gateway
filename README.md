# market-agri-api-gateway

The single entry point of the **Marketplace Agrícola Huila** distributed system: declarative NGINX
(Annex F), the only service that publishes a port to the host. Sub-task: HU-PLAT-001.
Governance and documentation: [`market-agri-docs`](https://github.com/code-corhuila/market-agri-docs).

## What it does

| Path | Goes to | Notes |
|---|---|---|
| `GET /health` | the gateway itself | `{"status":"UP"}` (api-contract E-60) |
| `/api/…` not claimed by a route | the gateway itself | `404 NOT_FOUND` with the common error body |
| `/` and every other path | `front:80` (`market-agri-front`) | The web interface, same origin as the API |

Every response carries `X-Correlation-Id` (the client's, if safe; otherwise a generated UUID),
which is also forwarded to the service and written in the JSON access log. A service that does not
answer gives `503 SERVICE_UNAVAILABLE` on its routes only: names are resolved on every request.
API routes, the credential filter, CORS and rate limits arrive in the next branches.

## Structure (Annex F)

```
nginx/nginx.conf               global settings, JSON log with correlationId, body size
nginx/conf.d/00-resolver.conf  Docker DNS on every request
nginx/conf.d/10-security.conf  X-Correlation-Id
nginx/conf.d/20-server.conf    the server, its own errors with the common body, the routes
nginx/snippets/                headers of every response; what every proxied request carries
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
