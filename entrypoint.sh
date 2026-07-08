#!/bin/sh
# Codex's bundled bwrap can't run inside an unprivileged container
# (--cap-drop=ALL strips the capabilities user-namespace setup needs).
# The outer container *is* the sandbox, so tell codex to skip its own.
#
# Written on first run only — user edits to config.toml are preserved.
set -eu

mkdir -p "$CODEX_HOME"
if [ ! -f "$CODEX_HOME/config.toml" ]; then
  cat >"$CODEX_HOME/config.toml" <<'EOF'
# Managed by codex-sandbox entrypoint on first run.
# The outer container provides isolation; codex's internal bwrap
# sandbox can't initialise under --cap-drop=ALL, so disable it here.
sandbox_mode = "danger-full-access"
EOF
fi

exec codex "$@"
