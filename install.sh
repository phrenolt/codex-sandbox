#!/usr/bin/env bash
#
# install.sh — install the codex-sandbox shell function
#
# Adds codex-sandbox to ~/.bashrc (or ~/.zshrc), idempotent.
# Re-running replaces the existing block rather than duplicating it.
#
# Usage:
#   ./install.sh            # auto-detects ~/.bashrc or ~/.zshrc
#   ./install.sh --print    # print the block without installing
#   ./install.sh --uninstall
#
# Shared install/build/launcher logic lives in common/ (the sandbox-common
# submodule); only the codex-specific block below is repo-local.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SBX_TOOL=codex
SBX_SCRIPT_DIR="$SCRIPT_DIR"
SBX_BUILD_ARGS="--auto"
SBX_RUN_HINT="codex-sandbox (or codex-sandbox-sh to enter the container)"

read -r -d '' SBX_BLOCK <<'BLOCK_EOF' || true
# >>> codex-sandbox >>>
# Managed by install.sh — edit the script / common lib, not this block (re-run to update).
source "__SBX_COMMON_DIR__/lib.sh"
SBX_TOOL=codex
SBX_SOURCE_DIR="__SBX_SOURCE_DIR__"

codex-sandbox()        { _sbx_sandbox_base "" "codex-sandbox" "$@"; }
codex-sandbox-sh()     { _sbx_sandbox_base "/bin/bash" "codex-sandbox-sh" "$@"; }
codex-sandbox-update() { _sbx_update; }

# Non-interactive codex wrapper (plain text becomes `codex --prompt "<text>"`).
codex-sandbox-prompt() { _sbx_prompt --prompt "$@"; }
# <<< codex-sandbox <<<
BLOCK_EOF

SBX_BLOCK="${SBX_BLOCK//__SBX_COMMON_DIR__/$SCRIPT_DIR/common}"
SBX_BLOCK="${SBX_BLOCK//__SBX_SOURCE_DIR__/$SCRIPT_DIR}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/common/install-lib.sh"
sbx_install_main "$@"
