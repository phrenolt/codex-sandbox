#!/usr/bin/env bash
#
# codex-sandbox specific tests. Reuses the shared assert helpers from the
# agents-sandbox-common submodule. Pure shell — no container, no network.
#
# Covers the codex-specific wiring AND the parity contract (same dev matrix +
# shared entrypoint the other sandbox must also satisfy).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO/common/tests/asserts.sh"

# --- rendered install block: codex-specific runtime wiring -------------------
block="$(mktemp)"; trap 'rm -f "$block"' EXIT
"$REPO/install.sh" --print > "$block"
# shellcheck disable=SC1090
source "$block"

assert_eq "$SBX_TOOL" "codex" "block sets SBX_TOOL=codex"
assert_eq "${SBX_PROJECT_LABEL:-}" "" "codex keeps the private :Z project label (default)"
for fn in codex-sandbox codex-sandbox-sh codex-sandbox-update codex-sandbox-prompt _sbx_sandbox_base; do
  if declare -F "$fn" >/dev/null; then _t_pass "fn $fn"; else _t_fail "missing fn $fn"; fi
done
# codex has no auto-updater hook
assert_eq "${SBX_UPDATE_HOOK:-}" "" "codex registers no update hook"

# --- Containerfile: codex specifics + parity contract ------------------------
cf="$(cat "$REPO/Containerfile")"
assert_contains "$cf" "FROM debian:trixie-slim"        "base = debian:trixie-slim"
assert_contains "$cf" "SBX_AGENT=codex"                "sets SBX_AGENT=codex"
assert_contains "$cf" "common/container/entrypoint.sh" "uses shared entrypoint"
assert_contains "$cf" "prestart.sh"                    "installs codex prestart hook"
for arg in INSTALL_CARGO INSTALL_PIP INSTALL_NODE INSTALL_PNPM \
           INSTALL_JDK INSTALL_GRADLE INSTALL_GO INSTALL_POSTGRES; do
  assert_contains "$cf" "ARG $arg" "declares $arg"
done

# --- prestart writes the sandbox-disabling config on first run ---------------
assert_contains "$(cat "$REPO/prestart.sh")" "sandbox_mode" "prestart writes config.toml sandbox_mode"

# --- build.sh delegates to the shared lib ------------------------------------
assert_contains "$(cat "$REPO/build.sh")" "common/build-lib.sh" "build.sh sources shared build-lib"

echo
echo "== codex-sandbox: $((TESTS_RUN - TESTS_FAIL))/$TESTS_RUN passed, $TESTS_FAIL failed =="
[ "$TESTS_FAIL" -eq 0 ]
