# syntax=docker/dockerfile:1
# Olares web image: the trunk build of apps/deckcraft-web served by nginx on :8080.
# Build from the repository root: docker build -f packaging/olares/web.Dockerfile .
# The toolchain follows the `web` job of storytold/craft-common-actions' release workflow
# (latest stable Rust, trunk 0.21.14); keep RUST_VERSION >= the workspace `rust-version`.
ARG RUST_VERSION=1.99
ARG NGINX_VERSION=1.28-alpine

# The wasm output is architecture-independent, so multi-arch builds compile it once natively.
FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-slim-bookworm AS builder
ARG TRUNK_VERSION=0.21.14
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && rustup target add wasm32-unknown-unknown
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) arch=x86_64 ;; \
        aarch64) arch=aarch64 ;; \
        *) echo 'The web builder supports amd64 and arm64' >&2; exit 1 ;; \
    esac; \
    asset="trunk-${arch}-unknown-linux-musl.tar.gz"; \
    url="https://github.com/trunk-rs/trunk/releases/download/v${TRUNK_VERSION}"; \
    cd /tmp; \
    curl -fsSL --retry 3 -A DeckCraft-olares "$url/$asset" -o "$asset"; \
    curl -fsSL --retry 3 -A DeckCraft-olares "$url/$asset.sha256" -o "$asset.sha256"; \
    printf '%s  %s\n' "$(cat "$asset.sha256")" "$asset" | sha256sum -c -; \
    tar -xzf "$asset" -C /usr/local/bin trunk; \
    rm "$asset" "$asset.sha256"; \
    trunk --version

WORKDIR /src
COPY . .
WORKDIR /src/apps/deckcraft-web
ARG CARGO_BUILD_JOBS=4
# Shown in About; .git is not in the build context, so CI passes them in.
ARG DECKCRAFT_BUILD_SHA=
ARG DECKCRAFT_BUILD_DATE=
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/src/target \
    --mount=type=cache,target=/root/.cache/trunk \
    trunk build --release --locked \
    && test -s /src/dist/web/index.html \
    && if grep -Eq '(src|href)="/[^/]' /src/dist/web/index.html; then echo 'index.html has root-absolute URLs' >&2; exit 1; fi \
    && gzip -9 -k /src/dist/web/*.wasm /src/dist/web/*.js /src/dist/web/index.html

FROM nginx:${NGINX_VERSION} AS runtime
COPY packaging/olares/nginx.conf /etc/nginx/nginx.conf
COPY --from=builder /src/dist/web/ /usr/share/nginx/html/
COPY LICENSE-MIT LICENSE-APACHE NOTICE ATTRIBUTION.md /usr/share/nginx/html/
USER nginx
EXPOSE 8080
ENTRYPOINT []
CMD ["nginx", "-g", "daemon off;"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
