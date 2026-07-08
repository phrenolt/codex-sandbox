#!/usr/bin/env bash
# Build the codex-sandbox image. Re-run to update to the latest codex release.
set -euo pipefail

if command -v podman &>/dev/null; then
  engine=podman
elif command -v docker &>/dev/null; then
  engine=docker
else
  echo "Error: neither podman nor docker found." >&2; exit 1
fi
echo ">> using: $engine"

$engine build -t localhost/codex-sandbox:latest -f Containerfile .
echo ">> built: localhost/codex-sandbox:latest"
echo ">> run:   codex-sandbox"
