#!/usr/bin/env bash
# Push on-disk .livemd edits into open Livebook sessions via /dev endpoints.
#
# Requires: Livebook running with Settings → Dev endpoints enabled.
# Docs: https://hexdocs.pm/livebook/dev_endpoints.html
#
# Usage:
#   ./scripts/livebook_sync.sh                       # sync all notebooks/
#   ./scripts/livebook_sync.sh path/to/book.livemd   # sync one (or more)
#   ./scripts/livebook_sync.sh --open                # open+sync all notebooks/
#   ./scripts/livebook_sync.sh --open book.livemd    # open session if needed, then sync
#   ./scripts/livebook_sync.sh --hook                # afterFileEdit stdin → sync that file
#
# Env:
#   LIVEBOOK_URL   default http://localhost:32123

set -euo pipefail

LIVEBOOK_URL="${LIVEBOOK_URL:-http://localhost:32123}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTEBOOKS_DIR="$(cd "$SCRIPT_DIR/../notebooks" && pwd)"

OPEN=0
HOOK=0
FILES=()

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

abs_path() {
  local p="$1"
  if [[ "$p" != /* ]]; then
    p="$(pwd)/$p"
  fi
  # Prefer realpath when present (macOS 13+ / Homebrew coreutils)
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p"
  else
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p"
  fi
}

post_json() {
  local endpoint="$1"
  local file="$2"
  local body http
  body="$(python3 -c 'import json,sys; print(json.dumps({"file": sys.argv[1]}))' "$file")"
  http="$(
    curl -sS -o /tmp/livebook_sync_body.$$ -w '%{http_code}' \
      -X POST "${LIVEBOOK_URL}${endpoint}" \
      -H 'content-type: application/json' \
      -d "$body" 2>/tmp/livebook_sync_err.$$ || true
  )"
  if [[ -z "$http" || "$http" == "000" ]]; then
    echo "error: cannot reach ${LIVEBOOK_URL} — is Livebook running with Dev endpoints on?" >&2
    if [[ -s /tmp/livebook_sync_err.$$ ]]; then
      cat /tmp/livebook_sync_err.$$ >&2
    fi
    rm -f /tmp/livebook_sync_body.$$ /tmp/livebook_sync_err.$$
    return 2
  fi
  printf '%s\t%s\n' "$http" "$(cat /tmp/livebook_sync_body.$$ 2>/dev/null || true)"
  rm -f /tmp/livebook_sync_body.$$ /tmp/livebook_sync_err.$$
}

sync_one() {
  local file="$1"
  local open_flag="$2"
  local line http body path

  if [[ ! -f "$file" ]]; then
    echo "skip  (missing)  $file"
    return 0
  fi
  if [[ "$file" != *.livemd ]]; then
    echo "skip  (not .livemd)  $file"
    return 0
  fi

  file="$(abs_path "$file")"

  if [[ "$open_flag" -eq 1 ]]; then
    line="$(post_json /dev/open "$file")" || return $?
    http="${line%%$'\t'*}"
    body="${line#*$'\t'}"
    if [[ "$http" != "200" ]]; then
      echo "fail  open HTTP $http  $file"
      echo "      $body"
      return 1
    fi
    path="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("path",""))' "$body" 2>/dev/null || true)"
    if [[ -n "$path" ]]; then
      echo "open  ${LIVEBOOK_URL}${path}"
    fi
  fi

  line="$(post_json /dev/sync "$file")" || return $?
  http="${line%%$'\t'*}"
  body="${line#*$'\t'}"

  case "$http" in
    200)
      echo "ok    sync  $file"
      ;;
    404)
      echo "skip  (no open session)  $file"
      echo "      tip: open it in Livebook, or re-run with --open"
      ;;
    *)
      echo "fail  sync HTTP $http  $file"
      echo "      $body"
      return 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --open)
      OPEN=1
      shift
      ;;
    --all)
      shift
      ;;
    --hook)
      HOOK=1
      shift
      ;;
    --)
      shift
      FILES+=("$@")
      break
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

if [[ "$HOOK" -eq 1 ]]; then
  # Cursor afterFileEdit: {"file_path":"...", ...}
  file_path="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("file_path") or "")')"
  if [[ -z "$file_path" || "$file_path" != *.livemd ]]; then
    exit 0
  fi
  # Fail open: never block the agent if Livebook is down / session closed
  sync_one "$file_path" 0 || true
  exit 0
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  while IFS= read -r -d '' f; do
    FILES+=("$f")
  done < <(find "$NOTEBOOKS_DIR" -maxdepth 1 -name '*.livemd' -print0 | sort -z)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "no .livemd files to sync" >&2
  exit 1
fi

fail=0
for f in "${FILES[@]}"; do
  if ! sync_one "$f" "$OPEN"; then
    fail=1
  fi
done

exit "$fail"
