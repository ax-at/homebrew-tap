#!/usr/bin/env bash
# scripts/autobump.sh — keep versioned-hybrid casks in this tap current.
#
# Subcommands:
#   detect                    Emit a JSON array of casks that are due AND changed
#                             to $GITHUB_OUTPUT as `changed=[...]`.
#   bump <token> <url> <gen>  Mount the dmg, read the real CFBundleShortVersionString,
#                             rewrite the cask's `version`/`# autobump-md5:` lines,
#                             then commit & push.
#
# detect runs on ubuntu (header-only, no download); bump runs on macOS (needs hdiutil).
# Config is casks.json; per-cask cadence/enable come from repo Variables (VARS_JSON).
# See DECISIONS.md for the full design and rationale.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/casks.json"

# token -> repo-Variable suffix (uppercase; non-alphanumerics -> underscore).
# e.g. "pencil-dev" -> "PENCIL_DEV" (used for CADENCE_* / ENABLED_*).
var_suffix() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_' | sed 's/_*$//'
}

# get_var NAME DEFAULT — read a repo Variable out of VARS_JSON (${{ toJSON(vars) }}).
get_var() {
  local name="$1" default="$2" json val
  json="${VARS_JSON:-}"
  [ -n "$json" ] || json='{}'
  val="$(printf '%s' "$json" | jq -r --arg k "$name" '.[$k] // empty' 2>/dev/null || true)"
  if [ -z "$val" ]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# head_identity URL — echo "<md5-base64> <generation>" from a redirect-followed HEAD.
# Header names are matched case-insensitively; values are preserved verbatim.
head_identity() {
  local url="$1" headers md5 gen
  headers="$(curl -sIL --max-time 60 "$url" | tr -d '\r')"
  md5="$(printf '%s\n' "$headers" \
    | awk 'tolower($1)=="x-goog-hash:" && $2 ~ /^md5=/ {sub(/^md5=/,"",$2); print $2}' \
    | tail -1)"
  gen="$(printf '%s\n' "$headers" \
    | awk 'tolower($1)=="x-goog-generation:" {print $2}' \
    | tail -1)"
  printf '%s %s' "$md5" "$gen"
}

# stored_md5 CASK_RB — the byte-identity currently recorded in the cask file.
stored_md5() {
  sed -n 's/^[[:space:]]*# autobump-md5:[[:space:]]*//p' "$1" | head -1
}

cmd_detect() {
  local now changed count i
  now="$(date +%s)"
  changed='[]'

  if [ "$(get_var AUTOBUMP_ENABLED true)" = "false" ]; then
    echo "AUTOBUMP_ENABLED=false — nothing to do"
    echo "changed=[]" >>"$GITHUB_OUTPUT"
    return 0
  fi

  count="$(jq '.casks | length' "$CONFIG")"
  for ((i = 0; i < count; i++)); do
    local cask token type suffix enabled rb forced
    cask="$(jq -c ".casks[$i]" "$CONFIG")"
    token="$(printf '%s' "$cask" | jq -r '.token')"
    type="$(printf '%s' "$cask" | jq -r '.type')"
    rb="$REPO_ROOT/Casks/$token.rb"

    if [ "$type" != "autobump-header" ]; then
      echo "skip $token: type=$type not implemented (see DECISIONS.md)"
      continue
    fi

    # A specific forced cask (workflow_dispatch input) short-circuits the others.
    forced=false
    if [ -n "${FORCE_CASK:-}" ]; then
      if [ "$FORCE_CASK" = "$token" ]; then
        forced=true
      else
        echo "skip $token: not the forced cask ($FORCE_CASK)"
        continue
      fi
    fi

    suffix="$(var_suffix "$token")"
    enabled="$(get_var "ENABLED_$suffix" true)"
    if [ "$enabled" = "false" ] && [ "$forced" != true ]; then
      echo "skip $token: ENABLED_$suffix=false"
      continue
    fi

    # Cadence due-check (git commit timestamp of the cask file); bypassed when forced.
    if [ "$forced" != true ]; then
      local default_cad cadence_days last age
      default_cad="$(printf '%s' "$cask" | jq -r '.default_cadence_days // 7')"
      cadence_days="$(get_var "CADENCE_$suffix" "$default_cad")"
      last="$(git -C "$REPO_ROOT" log -1 --format=%ct -- "Casks/$token.rb" 2>/dev/null || echo 0)"
      [ -n "$last" ] || last=0
      age=$((now - last))
      if [ "$age" -lt $((cadence_days * 86400)) ]; then
        echo "skip $token: not due (age ${age}s < cadence ${cadence_days}d)"
        continue
      fi
    fi

    # Change detection: live content md5 vs the md5 stored in the cask.
    local url ident live_md5 gen prev entry
    url="$(printf '%s' "$cask" | jq -r '.urls.arm')"
    ident="$(head_identity "$url")"
    live_md5="${ident%% *}"
    gen="${ident##* }"
    if [ -z "$live_md5" ] || [ -z "$gen" ]; then
      echo "WARN $token: could not read live identity from $url; skipping"
      continue
    fi
    prev="$(stored_md5 "$rb")"
    if [ "$live_md5" = "$prev" ] && [ "$forced" != true ]; then
      echo "skip $token: unchanged (md5 $live_md5)"
      continue
    fi

    echo "CHANGED $token: stored='$prev' live='$live_md5' gen=$gen forced=$forced"
    entry="$(jq -nc \
      --arg t "$token" \
      --arg a "$url" \
      --arg i "$(printf '%s' "$cask" | jq -r '.urls.intel')" \
      --arg g "$gen" \
      '{token:$t, arm_url:$a, intel_url:$i, generation:$g}')"
    changed="$(printf '%s' "$changed" | jq -c --argjson e "$entry" '. + [$e]')"
  done

  echo "changed=$changed" >>"$GITHUB_OUTPUT"
  echo "== detect result: $changed"
}

cmd_bump() {
  local token="$1" url="$2" gen="$3"
  local rb="$REPO_ROOT/Casks/$token.rb"
  local dmg="${TMPDIR:-/tmp}/${token}.dmg"
  local mnt="${TMPDIR:-/tmp}/${token}-mnt"

  echo "== $token: downloading $url"
  curl -fsSL --retry 3 -o "$dmg" "$url"

  rm -rf "$mnt"
  mkdir -p "$mnt"
  hdiutil attach "$dmg" -nobrowse -noverify -noautoopen -mountpoint "$mnt" >/dev/null

  local app ver
  app="$(/bin/ls -d "$mnt"/*.app 2>/dev/null | head -1 || true)"
  if [ -z "$app" ]; then
    hdiutil detach "$mnt" >/dev/null 2>&1 || true
    echo "ERROR $token: no .app bundle found inside dmg" >&2
    exit 1
  fi
  ver="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
  hdiutil detach "$mnt" >/dev/null 2>&1 || true

  # Freshest content md5 to record as the new byte-identity.
  local ident md5 new_version
  ident="$(head_identity "$url")"
  md5="${ident%% *}"
  new_version="${ver},${gen}"
  echo "== $token: version -> $new_version (md5 $md5)"

  # Targeted, format-preserving rewrites. The `e` flag inserts the env value
  # literally, so md5 base64 ('/','+','=') needs no delimiter escaping.
  NEW_VERSION="$new_version" perl -0pi \
    -e 's{^(\s*version\s+)"[^"]*"}{$1 . "\"" . $ENV{NEW_VERSION} . "\""}me' "$rb"
  MD5="$md5" perl -0pi \
    -e 's{^(\s*# autobump-md5:).*}{$1 . " " . $ENV{MD5}}me' "$rb"

  if git -C "$REPO_ROOT" diff --quiet -- "Casks/$token.rb"; then
    echo "== $token: no change to commit"
    return 0
  fi

  git -C "$REPO_ROOT" config user.name "github-actions[bot]"
  git -C "$REPO_ROOT" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git -C "$REPO_ROOT" commit -m "chore($token): bump to $ver (gen $gen) [autobump]" -- "Casks/$token.rb"
  # Rebase onto any concurrent autobump commit before pushing (matrix jobs check
  # out the same base SHA independently), then push.
  git -C "$REPO_ROOT" pull --rebase --no-edit || true
  git -C "$REPO_ROOT" push
}

main() {
  case "${1:-}" in
    detect)
      cmd_detect
      ;;
    bump)
      shift
      if [ "$#" -ne 3 ]; then
        echo "usage: autobump.sh bump <token> <arm_url> <generation>" >&2
        exit 2
      fi
      cmd_bump "$@"
      ;;
    *)
      echo "usage: autobump.sh {detect|bump <token> <arm_url> <generation>}" >&2
      exit 2
      ;;
  esac
}

main "$@"
