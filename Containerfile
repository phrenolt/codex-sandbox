FROM debian:trixie-slim
LABEL org.opencontainers.image.title="codex-sandbox"

# codex on Linux is a statically-linked musl Rust binary bundled with a static
# ripgrep and bwrap. We deliberately do NOT use the bundled bwrap inside the
# container: the outer podman/docker sandbox already provides isolation, and
# bwrap needs user-ns / SYS_ADMIN that --cap-drop=ALL strips. The entrypoint
# writes config.toml with sandbox_mode = "danger-full-access" on first run so
# codex skips its own sandbox layer.
#
# The dev-package matrix below is shared with agy-sandbox (build.sh /
# common/build-lib.sh drives the INSTALL_* args).
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates tar bubblewrap build-essential \
      python3 git \
 && rm -rf /var/lib/apt/lists/*

# Helper to securely wrap binaries with bwrap while preventing nested bwrap crashes
RUN echo '#!/bin/bash' > /usr/local/bin/wrap-binary && \
    echo 'target="$1"' >> /usr/local/bin/wrap-binary && \
    echo 'if [ ! -f "$target" ]; then exit 0; fi' >> /usr/local/bin/wrap-binary && \
    echo 'mv "$target" "$target.real"' >> /usr/local/bin/wrap-binary && \
    echo 'echo "#!/bin/bash" > "$target"' >> /usr/local/bin/wrap-binary && \
    echo 'echo "if [ \"\$CODEX_SANDBOX_BWRAP\" = \"1\" ]; then" >> "$target"' >> /usr/local/bin/wrap-binary && \
    echo 'echo "  exec \"\$0.real\" \"\$@\"" >> "$target"' >> /usr/local/bin/wrap-binary && \
    echo 'echo "else" >> "$target"' >> /usr/local/bin/wrap-binary && \
    echo 'echo "  export CODEX_SANDBOX_BWRAP=1" >> "$target"' >> /usr/local/bin/wrap-binary && \
    echo 'echo "  exec bwrap --unshare-user --uid 1000 --gid 1000 --bind / / --tmpfs /home/codex/.codex \"\$0.real\" \"\$@\"" >> "$target"' >> /usr/local/bin/wrap-binary && \
    echo 'echo "fi" >> "$target"' >> /usr/local/bin/wrap-binary && \
    echo 'chmod +x "$target"' >> /usr/local/bin/wrap-binary && \
    chmod +x /usr/local/bin/wrap-binary

# Wrap base binaries
RUN wrap-binary /usr/bin/python3

ARG INSTALL_PIP=false
RUN if [ "$INSTALL_PIP" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends python3-venv python3-pip && \
      wrap-binary /usr/bin/pip3 && wrap-binary /usr/bin/pip && \
      rm -rf /var/lib/apt/lists/* ; \
    fi

ARG INSTALL_NODE=false
RUN if [ "$INSTALL_NODE" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends nodejs npm && \
      wrap-binary /usr/bin/node && wrap-binary /usr/bin/npm && \
      rm -rf /var/lib/apt/lists/* ; \
    fi

ARG INSTALL_PNPM=false
RUN if [ "$INSTALL_PNPM" = "true" ]; then \
      if ! command -v npm >/dev/null; then echo "Error: PNPM requires Node (INSTALL_NODE=true)" >&2; exit 1; fi && \
      npm install -g pnpm@9 && \
      wrap-binary /usr/local/bin/pnpm && \
      rm -rf /var/lib/apt/lists/* ; \
    fi

ARG INSTALL_JDK=false
RUN if [ "$INSTALL_JDK" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends default-jdk && \
      wrap-binary /usr/bin/java && \
      rm -rf /var/lib/apt/lists/* ; \
    fi

ARG INSTALL_GRADLE=false
RUN if [ "$INSTALL_GRADLE" = "true" ]; then \
      if ! command -v java >/dev/null; then echo "Error: Gradle requires JDK (INSTALL_JDK=true)" >&2; exit 1; fi && \
      apt-get update && apt-get install -y --no-install-recommends gradle && \
      wrap-binary /usr/bin/gradle && \
      rm -rf /var/lib/apt/lists/* ; \
    fi

ARG INSTALL_GO=false
ENV GOPATH=/home/codex/go
ENV PATH=$PATH:$GOPATH/bin
RUN if [ "$INSTALL_GO" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends golang && \
      wrap-binary /usr/bin/go && \
      rm -rf /var/lib/apt/lists/* ; \
    fi

ARG INSTALL_CARGO=false
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN if [ "$INSTALL_CARGO" = "true" ]; then \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path && \
      chmod -R a+rw /usr/local/cargo /usr/local/rustup && \
      wrap-binary /usr/local/cargo/bin/cargo && \
      curl -LsSf https://github.com/taiki-e/cargo-llvm-cov/releases/download/v0.8.7/cargo-llvm-cov-x86_64-unknown-linux-gnu.tar.gz | tar xzf - -C /usr/local/cargo/bin ; \
    fi

ARG INSTALL_POSTGRES=false
RUN if [ "$INSTALL_POSTGRES" = "true" ]; then \
      apt-get update && apt-get install -y --no-install-recommends gnupg && \
      curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg && \
      echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt trixie-pgdg main" > /etc/apt/sources.list.d/postgresql.list && \
      apt-get update && apt-get install -y --no-install-recommends postgresql-18 && \
      rm -rf /var/lib/apt/lists/* ; \
    fi
ENV PATH=/usr/lib/postgresql/18/bin:$PATH

# Install codex at build time. CODEX_HOME during install controls where the
# standalone release tree lives; the /usr/local/bin/codex symlink is baked with
# absolute paths into that tree. Keep it at /opt/codex so a runtime home mount
# can't shadow it.
ENV CODEX_INSTALL_DIR=/usr/local/bin \
    CODEX_HOME=/opt/codex
RUN mkdir -p "$CODEX_HOME" \
 && curl -fsSL https://chatgpt.com/codex/install.sh | sh \
 && /usr/local/bin/codex --version

# At runtime CODEX_HOME points to the user's persisted config dir, not the
# install tree. The codex binary in /usr/local/bin is a symlink into /opt so it
# still resolves regardless of this override.
ENV CODEX_HOME=/home/codex/.codex

# Shared entrypoint (DB init + routing) from the agents-sandbox-common submodule;
# prestart.sh is codex's agent-specific first-run hook (writes config.toml).
ENV SBX_AGENT=codex \
    SBX_HOME=/home/codex
COPY --chmod=0755 common/container/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 prestart.sh /usr/local/bin/sbx-prestart

# dedicated non-root user
RUN useradd -m -u 1000 -s /bin/bash codex
USER codex

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
