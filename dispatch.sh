#!/usr/bin/env bash
# Poll GitHub and run launch.sh for every queued job that asks for this executor.
#
#   ./dispatch.sh --executors EXECUTORS.yaml --allowlist REPOS.yaml --executor NAME \
#     --tokens DIR [--template FILE] [--interval 20]
#
# DIR holds one file per repository owner (DIR/<owner>), each a fine-grained token
# limited to that owner's allowlisted repositories: Administration read/write
# (runner registration), Actions read, Metadata read.
#
# A job is picked up when it is queued with the label <label_prefix>-<run_id>-<attempt>
# in an allowlisted repository; launch.sh then applies every check (private repo,
# same-repo head, allowlisted workflow, SHA). One run at a time. A run/attempt is
# launched at most once: if it fails, re-run it in GitHub (a new attempt).
# Outbound polling only; nothing listens. Needs bash, gh, kubectl, jq, yq, openssl.
set -euo pipefail

die() { echo "dispatch: $*" >&2; exit 1; }
log() { echo "$(date -u +%FT%TZ) $*"; }

here=$(cd "$(dirname "$0")" && pwd)
EXECUTORS= ALLOWLIST= EXECUTOR= TOKENS= TEMPLATE= INTERVAL=20
while (($#)); do
  case $1 in
    --executors) EXECUTORS=$2 ;; --allowlist) ALLOWLIST=$2 ;; --executor) EXECUTOR=$2 ;;
    --tokens) TOKENS=$2 ;; --template) TEMPLATE=$2 ;; --interval) INTERVAL=$2 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift 2
done
[[ -n $EXECUTORS && -n $ALLOWLIST && -n $EXECUTOR && -d $TOKENS ]] ||
  die "needs --executors --allowlist --executor --tokens DIR"
[[ $INTERVAL =~ ^[1-9][0-9]*$ ]] || die "--interval must be positive"
template=()
[[ -z $TEMPLATE ]] || template=(--template "$TEMPLATE")

seen=$(mktemp)         # run/attempt keys already launched, and owners without a token
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
    owner=${repo%%/*}
    if [[ ! -s $TOKENS/$owner ]]; then
      if once "no-token/$owner"; then log "no token for $owner; skipping its repositories"; fi
      continue
    fi
    prefix=$(yq -r ".repos[\"$repo\"].label_prefix // \"jit\"" "$ALLOWLIST")
    GH_TOKEN=$(<"$TOKENS/$owner")
    export GH_TOKEN
    if ! found=$(queued_runs "$repo" "$prefix"); then
      log "$repo: GitHub poll failed"
      continue
    fi
    while read -r id attempt sha; do
      [[ -n $id ]] && once "$repo/$id/$attempt" || continue
      log "$repo run $id/$attempt ($sha): launching"
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
