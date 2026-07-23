#!/bin/bash
# codex-sandbox pre-start hook, run by the shared entrypoint before Postgres /
# routing. Disables codex's internal bwrap sandbox on first run: it can't
# initialise under --cap-drop=ALL, and the outer container already isolates us.
# User edits to config.toml are preserved.
set -eu

mkdir -p "$CODEX_HOME"
if [ ! -f "$CODEX_HOME/config.toml" ]; then
  cat >"$CODEX_HOME/config.toml" <<'EOF'
# Managed by codex-sandbox prestart on first run.
# The outer container provides isolation; codex's internal bwrap
# sandbox can't initialise under --cap-drop=ALL, so disable it here.
sandbox_mode = "danger-full-access"
EOF
fi
