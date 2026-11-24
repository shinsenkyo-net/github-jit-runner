#!/usr/bin/env bash
# Poll GitHub and run launch.sh for every queued job that asks for this executor.
#
#   ./dispatch.sh --executors EXECUTORS.yaml --allowlist REPOS.yaml --executor NAME \
#     --app DIR [--template FILE] [--interval 20]
#   ./dispatch.sh token OWNER/NAME   # print a token (launch.sh GH_TOKEN_COMMAND)
#
# DIR holds a GitHub App's credentials: DIR/app-id and DIR/private-key. The App
# needs repository permissions Administration read/write (runner registration)
# and Actions read, and must be installed on the allowlisted repositories. Every
# GitHub call uses a one-hour installation token limited to one repository and
# those two permissions, cached in $TMPDIR until 15 minutes before it expires.
#
# A job is picked up when it is queued with the label <label_prefix>-<run_id>-<attempt>
# in an allowlisted repository; launch.sh then applies every check (private repo,
# same-repo head, allowlisted workflow, SHA). One run at a time. A run/attempt is
# launched at most once: if it fails, re-run it in GitHub (a new attempt).
# Outbound polling only; nothing listens. Needs bash, curl, gh, kubectl, jq, yq, openssl.
set -euo pipefail
umask 077

die() { echo "dispatch: $*" >&2; exit 1; }
log() { echo "$(date -u +%FT%TZ) $*"; }

# --- GitHub App installation tokens ------------------------------------------

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

app_call() { # method path [json-body]; authenticated as the App (JWT)
  local now h p jwt body=()
  now=$(date +%s)
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) \
    "$(<"$GITHUB_APP_DIR/app-id")" | b64url)
  jwt="$h.$p.$(printf '%s.%s' "$h" "$p" |
    openssl dgst -sha256 -binary -sign "$GITHUB_APP_DIR/private-key" | b64url)"
  [[ -z ${3:-} ]] || body=(--data "$3")
  # The JWT reaches curl on stdin, never in argv.
  printf 'Authorization: Bearer %s\n' "$jwt" |
    curl -fsS --max-time 20 -X "$1" -H @- -H 'Accept: application/vnd.github+json' \
      ${body[@]+"${body[@]}"} "https://api.github.com$2"
}

token() { # owner/name: print an installation token for that one repository
  local cache=${TMPDIR:-/tmp}/gh-token-${1//\//_} inst body
  if [[ -s $cache ]] && (($(head -n1 "$cache") > $(date +%s) + 900)); then
    sed -n 2p "$cache"
    return
  fi
  inst=$(app_call GET "/repos/$1/installation" | jq -er .id)
  body=$(jq -cn --arg r "${1#*/}" \
    '{repositories: [$r], permissions: {administration: "write", actions: "read"}}')
  app_call POST "/app/installations/$inst/access_tokens" "$body" |
    jq -er '(.expires_at | fromdateiso8601), .token' >"$cache.tmp"
  mv "$cache.tmp" "$cache"
  sed -n 2p "$cache"
}

if [[ ${1:-} == token ]]; then
  [[ -n ${GITHUB_APP_DIR:-} && ${2:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die "usage: GITHUB_APP_DIR=DIR dispatch.sh token OWNER/NAME"
  token "$2"
  exit
fi

# --- dispatcher ----------------------------------------------------------------

here=$(cd "$(dirname "$0")" && pwd)
EXECUTORS= ALLOWLIST= EXECUTOR= APP= TEMPLATE= INTERVAL=20
while (($#)); do
  case $1 in
    --executors) EXECUTORS=$2 ;; --allowlist) ALLOWLIST=$2 ;; --executor) EXECUTOR=$2 ;;
    --app) APP=$2 ;; --template) TEMPLATE=$2 ;; --interval) INTERVAL=$2 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift 2
done
[[ -n $EXECUTORS && -n $ALLOWLIST && -n $EXECUTOR && -n $APP ]] ||
  die "needs --executors --allowlist --executor --app DIR"
[[ $INTERVAL =~ ^[1-9][0-9]*$ ]] || die "--interval must be positive"
export GITHUB_APP_DIR=$APP
template=()
[[ -z $TEMPLATE ]] || template=(--template "$TEMPLATE")

seen=$(mktemp)         # run/attempt keys already launched, and repos already reported
child=
# As PID 1 bash ignores SIGTERM unless trapped: pass it on so launch.sh cleans up.
trap '[[ -z $child ]] || { kill -TERM "$child" 2>/dev/null; wait "$child" || true; }; exit 143' TERM INT
trap 'rm -f "$seen"' EXIT
once() { grep -qxF "$1" "$seen" && return 1; echo "$1" >>"$seen"; }

# Prints "<run_id> <attempt> <sha>" for runs of $repo with a queued job labelled for us.
queued_runs() { # repo prefix
  local runs id attempt sha
  runs=$(for status in queued in_progress; do
    gh api "repos/$1/actions/runs?status=$status&per_page=50" \
      --jq '.workflow_runs[] | "\(.id) \(.run_attempt) \(.head_sha)"' || exit 1
  done) || return 1
  while read -r id attempt sha; do
    [[ -n $id ]] || continue
    gh api "repos/$1/actions/runs/$id/attempts/$attempt/jobs?per_page=100" \
      --jq "any(.jobs[]; .status == \"queued\" and (.labels | index(\"$2-$id-$attempt\")))" |
      grep -qx true && echo "$id $attempt $sha"
  done <<<"$runs"
  return 0
}

log "dispatching for executor $EXECUTOR every ${INTERVAL}s"
while true; do
  for repo in $(yq -r '.repos | keys | .[]' "$ALLOWLIST"); do
    prefix=$(yq -r ".repos[\"$repo\"].label_prefix // \"jit\"" "$ALLOWLIST")
    if ! GH_TOKEN=$(token "$repo" 2>/dev/null); then
      if once "no-token/$repo"; then log "$repo: no App token (App not installed there, or not ready)"; fi
      continue
    fi
    export GH_TOKEN
    if ! found=$(queued_runs "$repo" "$prefix"); then
      log "$repo: GitHub poll failed"
      continue
    fi
    while read -r id attempt sha; do
      [[ -n $id ]] && once "$repo/$id/$attempt" || continue
      log "$repo run $id/$attempt ($sha): launching"
      GH_TOKEN_COMMAND="$here/dispatch.sh token $repo" \
        "$here/launch.sh" run --executors "$EXECUTORS" --allowlist "$ALLOWLIST" \
          --executor "$EXECUTOR" ${template[@]+"${template[@]}"} \
          --repo "$repo" --run-id "$id" --sha "$sha" </dev/null &
      child=$!
      code=0; wait "$child" || code=$?
      child=
      log "$repo run $id/$attempt: launch exited $code"
    done <<<"$found"
  done
  unset GH_TOKEN
  sleep "$INTERVAL" &
  wait $! || true
done
