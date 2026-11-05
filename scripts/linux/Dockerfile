# Linux image for building/testing the platform-independent Tagen modules.
# The macOS app itself is built on GitHub-hosted macOS runners (see .github/workflows/ci.yml).
# Optional: place an extra CA certificate as extra.crt in the build context (needed behind TLS-intercepting proxies).
FROM swift:6.2-noble
COPY . /tmp/ctx
RUN if [ -f /tmp/ctx/extra.crt ]; then cp /tmp/ctx/extra.crt /usr/local/share/ca-certificates/extra.crt && update-ca-certificates; fi \
 && (sed -i 's|http://|https://|g' /etc/apt/sources.list.d/*.sources 2>/dev/null || true) \
 && apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev python3 && rm -rf /var/lib/apt/lists/* /tmp/ctx
