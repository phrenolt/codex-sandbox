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

set -euo pipefail

MARK_START="# >>> codex-sandbox >>>"
MARK_END="# <<< codex-sandbox <<<"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read -r -d '' BLOCK <<'BLOCK_EOF' || true
# >>> codex-sandbox >>>
# Managed by install.sh — edit the script, not this block (re-run to update).

# Detect container engine: prefer podman, fall back to docker.
_codex_engine() {
  if command -v podman &>/dev/null; then echo podman
  elif command -v docker &>/dev/null; then echo docker
  else echo ""; fi
}

_codex_source_dir() {
  printf '%s\n' "__CODEX_SANDBOX_SOURCE_DIR__"
}

_codex_pin_image() {
  local engine="$1"
  local image_id
  image_id="$($engine image inspect --format '{{.Id}}' localhost/codex-sandbox:latest 2>/dev/null || true)"
  [ -n "$image_id" ] || { echo "Error: could not read rebuilt image ID." >&2; return 1; }
  mkdir -p "$HOME/.config/codex-sandbox"
  printf '%s\n' "$image_id" > "$HOME/.config/codex-sandbox/image-id"
  echo ">> pinned image ID: $image_id"
  echo "   ($HOME/.config/codex-sandbox/image-id)"
}

# Rebuild codex-sandbox from the installed source directory and repin the
# wrapper to the new image ID.
codex-sandbox-update() {
  local engine; engine="$(_codex_engine)"
  [ -n "$engine" ] || { echo "Error: neither podman nor docker found." >&2; return 1; }

  local source_dir; source_dir="$(_codex_source_dir)"
  if [ ! -f "$source_dir/Containerfile" ]; then
    echo "Error: codex-sandbox source not found at $source_dir" >&2
    echo "       Re-run ./install.sh from the codex-sandbox source directory." >&2
    return 1
  fi

  echo ">> rebuilding localhost/codex-sandbox:latest from $source_dir"
  (cd "$source_dir" && $engine build --no-cache -t localhost/codex-sandbox:latest -f Containerfile .) || return
  _codex_pin_image "$engine"
}

# Launch the OpenAI Codex CLI inside a container.
# The host $HOME is NEVER mounted. Only two paths are exposed:
#   - $HOME/.local/share/codex-sandbox -> /home/codex   (auth + config persistence)
#   - <project dir>                     -> /work        (the code you want codex to see)
#
# Under podman, both mounts are chowned to UID 1000 inside podman's user
# namespace (a host subUID, e.g. ~525287), so a container escape is
# confined to those two dirs and cannot reach your real $HOME. On exit
# the project dir is chowned back to your real UID so you can keep
# editing it normally from the host.
#
# Usage:
#   codex-sandbox                    # prompts for project dir (tab-completes)
#   codex-sandbox <dir>              # use <dir> as project dir
#   codex-sandbox <dir> <codex-args> # ...and pass remaining args to codex
#
# Build the image first:  cd /path/to/codex-sandbox && ./build.sh
_codex_sandbox_base() {
  local entrypoint="$1"
  local container_name="$2"
  shift 2

  local engine; engine="$(_codex_engine)"
  [ -n "$engine" ] || { echo "Error: neither podman nor docker found." >&2; return 1; }

  local project_dir
  if [ $# -gt 0 ] && [ -d "$1" ]; then
    project_dir="$(realpath "$1")"; shift
  else
    read -e -p ">> project dir: " -i "$PWD" project_dir
    project_dir="${project_dir/#\~/$HOME}"
    [ -z "$project_dir" ] && { echo "Cancelled."; return 0; }
    if [ ! -d "$project_dir" ]; then
      echo "Error: '$project_dir' is not a directory." >&2; return 1
    fi
    project_dir="$(realpath "$project_dir")"
  fi

  # Refuse to mount $HOME itself or any ancestor of it — the whole point
  # of this sandbox is that the host home stays invisible to codex.
  case "$HOME/" in
    "$project_dir"/*|"$project_dir"/) ;& # ancestor of $HOME
    "$project_dir") # is $HOME
      echo "Error: refusing to mount '$project_dir' (would expose host \$HOME)." >&2
      return 1 ;;
  esac
  if [ "$project_dir" = "$HOME" ]; then
    echo "Error: refusing to mount \$HOME directly." >&2; return 1
  fi
  echo ">> mounting: $project_dir -> /work"

  local config_dir="$HOME/.local/share/codex-sandbox"
  mkdir -p "$config_dir"

  # Remap ownership into podman's user namespace (subUID 1000) on the way in.
  if [ "$engine" = "podman" ]; then
    podman unshare chown -R 1000:1000 "$config_dir"
    podman unshare chown -R 1000:1000 "$project_dir"
  fi

  # On exit, hand the project dir back to the real host UID so it can be
  # edited from the host without `podman unshare`. The config dir stays
  # under the subUID — that's where the auth token lives.
  _codex_restore() {
    if [ "$engine" = "podman" ]; then
      podman unshare chown -R 0:0 "$project_dir" 2>/dev/null || true
    fi
  }
  trap _codex_restore RETURN

  local replace_flag=()
  if [ "$engine" = "podman" ]; then replace_flag=(--replace)
  else $engine rm -f codex-sandbox 2>/dev/null || true; fi
  # Pin to the image ID we built, not the :latest tag — another image
  # with the same name (registry pull, accidental rebuild of something
  # else) can't be substituted for us.
  local pin_file="$HOME/.config/codex-sandbox/image-id"
  if [ ! -s "$pin_file" ]; then
    echo "Error: no pinned image ID at $pin_file" >&2
    echo "       Run ./install.sh in the codex-sandbox source dir to build + pin." >&2
    return 1
  fi
  local image_id; image_id="$(cat "$pin_file")"
  if ! $engine image inspect "$image_id" &>/dev/null; then
    echo "Error: pinned image $image_id is no longer present in $engine." >&2
    echo "       Run ./install.sh in the codex-sandbox source dir to rebuild + repin." >&2
    return 1
  fi

  local entrypoint_flag=()
  [ -n "$entrypoint" ] && entrypoint_flag=(--entrypoint "$entrypoint")

  $engine run --rm -it --name "$container_name" "${replace_flag[@]}" \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    "${entrypoint_flag[@]}" \
    -e TERM="${TERM:-xterm-256color}" \
    -v "$config_dir":/home/codex:Z \
    -v "$project_dir":/work:Z \
    "$image_id" \
    "$@"
}

codex-sandbox() {
  _codex_sandbox_base "" "codex-sandbox" "$@"
}

codex-sandbox-sh() {
  _codex_sandbox_base "/bin/bash" "codex-sandbox-sh" "$@"
}

codex-sandbox-prompt() {
  local engine; engine="$(_codex_engine)"
  [ -n "$engine" ] || { echo "Error: neither podman nor docker found." >&2; return 1; }
  [ $# -gt 0 ] || { echo "usage: codex-sandbox-prompt [<codex-args> | <prompt>]" >&2; return 1; }
  local config_dir="$HOME/.local/share/codex-sandbox"
  mkdir -p "$config_dir"
  [ "$engine" = "podman" ] && podman unshare chown -R 1000:1000 "$config_dir"
  local pin_file="$HOME/.config/codex-sandbox/image-id"
  [ -s "$pin_file" ] || { echo "Error: no pinned image ID at $pin_file (run ./install.sh)." >&2; return 1; }
  local image_id; image_id="$(cat "$pin_file")"
  $engine image inspect "$image_id" &>/dev/null \
    || { echo "Error: pinned image $image_id no longer present (run ./install.sh)." >&2; return 1; }

  local replace_flag=()
  if [ "$engine" = "podman" ]; then replace_flag=(--replace)
  else $engine rm -f codex-sandbox-prompt 2>/dev/null || true; fi

  local codex_args=()
  case "${1:-}" in
    --)
      shift
      [ $# -gt 0 ] || { echo "usage: codex-sandbox-prompt -- <codex-args>" >&2; return 1; }
      codex_args=("$@")
      ;;
    -*)
      codex_args=("$@")
      ;;
    *)
      # Backwards-compatible shorthand: plain text becomes `codex --prompt "<text>"`.
      codex_args=(--prompt "$*")
      ;;
  esac

  $engine run --rm --name codex-sandbox-prompt "${replace_flag[@]}" \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    -v "$config_dir":/home/codex:Z \
    "$image_id" \
    "${codex_args[@]}"
}
# <<< codex-sandbox <<<
BLOCK_EOF
BLOCK="${BLOCK//__CODEX_SANDBOX_SOURCE_DIR__/$SCRIPT_DIR}"

detect_rc() {
  if [ -n "${1:-}" ]; then echo "$1"; return; fi
  case "${SHELL:-}" in
    *zsh) echo "$HOME/.zshrc" ;;
    *)    echo "$HOME/.bashrc" ;;
  esac
}

strip_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed "/^${MARK_START}$/,/^${MARK_END}$/d" "$file"
}

case "${1:-}" in
  --print)
    printf '%s\n' "$BLOCK"
    exit 0
    ;;
  --uninstall)
    RC="$(detect_rc "${2:-}")"
    [ -f "$RC" ] || { echo "Nothing to remove: $RC not found."; exit 0; }
    cp "$RC" "$RC.bak.$(date +%Y%m%d-%H%M%S)"
    strip_block "$RC" > "$RC.tmp" && mv "$RC.tmp" "$RC"
    echo "Removed codex-sandbox from $RC (backup saved)."
    exit 0
    ;;
esac

RC="$(detect_rc "${1:-}")"
touch "$RC"
cp "$RC" "$RC.bak.$(date +%Y%m%d-%H%M%S)"
{ strip_block "$RC" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba}'; printf '\n%s\n' "$BLOCK"; } > "$RC.tmp"
mv "$RC.tmp" "$RC"

echo "Installed codex-sandbox into $RC"

# Build the image so the shell function works on first call. Skip if it
# already exists (use ./build.sh directly to force a rebuild) or if
# --no-build was passed.
if [ "${2:-${1:-}}" != "--no-build" ] && [ "${1:-}" != "--no-build" ]; then
  if command -v podman &>/dev/null; then build_engine=podman
  elif command -v docker &>/dev/null; then build_engine=docker
  else build_engine=""; fi
  if [ -n "$build_engine" ] && \
     $build_engine image inspect localhost/codex-sandbox:latest &>/dev/null; then
    echo ">> image localhost/codex-sandbox:latest already present — skipping build"
    echo "   (run ./build.sh to rebuild)"
  else
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -x "$script_dir/build.sh" ]; then
      echo
      echo ">> building image..."
      (cd "$script_dir" && ./build.sh)
    fi
  fi

  # Pin the built image by its SHA-256 ID so the shell function isn't
  # vulnerable to another image later claiming the localhost/codex-sandbox
  # name.
  if [ -n "$build_engine" ]; then
    image_id="$($build_engine image inspect --format '{{.Id}}' \
                 localhost/codex-sandbox:latest 2>/dev/null || true)"
    if [ -n "$image_id" ]; then
      mkdir -p "$HOME/.config/codex-sandbox"
      printf '%s\n' "$image_id" > "$HOME/.config/codex-sandbox/image-id"
      echo ">> pinned image ID: $image_id"
      echo "   ($HOME/.config/codex-sandbox/image-id)"
    else
      echo "Warning: could not read image ID — codex-sandbox will fail until rebuilt." >&2
    fi
  fi
fi

echo
echo "Run:  source $RC"
echo "Then: codex-sandbox (or codex-sandbox-sh to enter the container)"
