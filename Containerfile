FROM alpine:3
LABEL org.opencontainers.image.title="codex-sandbox"

# codex on Linux is a statically-linked musl Rust binary (x86_64/aarch64
# -unknown-linux-musl) bundled with a static ripgrep and bwrap. No dynamic
# library deps — only the install/runtime tools below.
#
# We deliberately do NOT use the bundled bwrap inside the container: the
# outer podman/docker sandbox already provides isolation, and bwrap needs
# user-ns / SYS_ADMIN that --cap-drop=ALL strips. The entrypoint writes a
# config.toml with sandbox_mode = "danger-full-access" on first run so
# codex skips its own sandbox layer.
RUN apk add --no-cache \
      ca-certificates curl tar bash git tini python3 npm nodejs

# Install codex at build time. CODEX_HOME during install controls *where*
# the standalone release tree lives (packages/standalone/...), and the
# /usr/local/bin/codex symlink is baked with absolute paths into that tree.
# We keep the install tree at /opt/codex so that bind-mounting a user home
# at runtime can't shadow it.
ENV CODEX_INSTALL_DIR=/usr/local/bin \
    CODEX_HOME=/opt/codex
RUN mkdir -p "$CODEX_HOME" \
 && curl -fsSL https://chatgpt.com/codex/install.sh | sh \
 && /usr/local/bin/codex --version

# Dedicated non-root user. Home is mounted from the host at runtime for
# auth-token / config / session persistence.
RUN adduser -D -u 1000 -s /bin/bash codex
USER codex
WORKDIR /work

# At runtime CODEX_HOME points to the user's persisted config dir, not the
# install tree. The codex binary in /usr/local/bin is a symlink into /opt
# so it still resolves regardless of this override.
ENV CODEX_HOME=/home/codex/.codex

COPY --chmod=0755 entrypoint.sh /usr/local/bin/codex-sandbox-entrypoint
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/codex-sandbox-entrypoint"]
