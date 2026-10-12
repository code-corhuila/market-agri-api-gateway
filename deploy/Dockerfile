# The gateway is configuration on top of the official NGINX image (Annex F).
FROM nginx:1.27-alpine
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/conf.d/ /etc/nginx/conf.d/
COPY nginx/snippets/ /etc/nginx/snippets/
COPY nginx/routes/ /etc/nginx/routes/
EXPOSE 8080
# The image checks itself, wherever it runs (infra's compose, CI, a plain docker run).
HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD wget -qO- http://127.0.0.1:8080/health || exit 1
