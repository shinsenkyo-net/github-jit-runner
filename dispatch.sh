#!/usr/bin/env bash
# Poll GitHub and run launch.sh for every queued job that asks for this executor.
#
#   ./dispatch.sh --executors EXECUTORS.yaml --allowlist REPOS.yaml --executor NAME \
#     --app DIR [--template-dir DIR] [--interval 20]
#   ./dispatch.sh token OWNER/NAME   # print a token (launch.sh: GH_TOKEN_COMMAND=dispatch.sh)
#
# DIR holds a GitHub App's credentials: DIR/app-id and DIR/private-key. The App
# needs repository permissions Administration read/write (runner registration),
# Actions read and Contents read (tag-pinned publish rules), and must be installed
# on the allowlisted repositories. Every GitHub call uses a one-hour installation
# token limited to one repository and those permissions, cached in $TMPDIR until
# 15 minutes before it expires. Without Contents on the App, tokens fall back to
# the first two and tag-pinned publish runs are refused.
#
# A job is picked up when it is queued with the label <prefix>-<run_id>-<attempt>
# in an allowlisted repository, where <prefix> is the repository's label_prefix
# (default jit; the executor's template) or one of its `variants` prefixes (that
# image variant's template). --template-dir DIR finds the templates by file name
# in DIR (a mounted ConfigMap). launch.sh then applies every check (private repo,
# same-repo head, allowlisted workflow, SHA). One run at a time. A failed launch is
# retried on later polls while its job is still queued, at most 3 times per
# run/attempt. A lock left by an earlier launch of this dispatcher (crash, kill)
# is cleared at start and after failures, once that launch's Job is gone.
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
  # Explicit returns: callers use $(token ...) in conditions, where set -e is off.
  inst=$(app_call GET "/repos/$1/installation" | jq -er .id) || return 1
  for perms in '{administration: "write", actions: "read", contents: "read"}' \
               '{administration: "write", actions: "read"}'; do
    body=$(jq -cn --arg r "${1#*/}" "{repositories: [\$r], permissions: $perms}") || return 1
    if app_call POST "/app/installations/$inst/access_tokens" "$body" 2>/dev/null |
         jq -er '(.expires_at | fromdateiso8601), .token' >"$cache.tmp"; then
      break
    fi
    [[ $perms == *contents* ]] || return 1
  done
  mv "$cache.tmp" "$cache" || return 1
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
EXECUTORS= ALLOWLIST= EXECUTOR= APP= TEMPLATE_DIR= INTERVAL=20
while (($#)); do
  case $1 in
    --executors) EXECUTORS=$2 ;; --allowlist) ALLOWLIST=$2 ;; --executor) EXECUTOR=$2 ;;
    --app) APP=$2 ;; --template-dir) TEMPLATE_DIR=$2 ;; --interval) INTERVAL=$2 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift 2
done
[[ -n $EXECUTORS && -n $ALLOWLIST && -n $EXECUTOR && -n $APP ]] ||
  die "needs --executors --allowlist --executor --app DIR"
[[ $INTERVAL =~ ^[1-9][0-9]*$ ]] || die "--interval must be positive"
export GITHUB_APP_DIR=$APP
export GITHUB_JIT_HOLDER="dispatcher/${HOSTNAME:-$(hostname)}"
NS=$(yq -r ".executors[\"$EXECUTOR\"].namespace" "$EXECUTORS")
[[ -n $NS && $NS != null ]] || die "executor $EXECUTOR has no namespace"
# kubectl drops its in-cluster config once any flag (launch.sh: --request-timeout)
# is set, so point it at the service account explicitly. The token stays in its file.
sa=/var/run/secrets/kubernetes.io/serviceaccount
if [[ -z ${KUBECONFIG:-} && -n ${KUBERNETES_SERVICE_HOST:-} && -r $sa/token ]]; then
  host=$KUBERNETES_SERVICE_HOST
  [[ $host != *:* ]] || host="[$host]"   # IPv6 needs brackets in a URL
  export KUBECONFIG=${TMPDIR:-/tmp}/kubeconfig
  cat >"$KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters: [{name: in-cluster, cluster: {server: "https://$host:$KUBERNETES_SERVICE_PORT", certificate-authority: $sa/ca.crt}}]
users: [{name: sa, user: {tokenFile: $sa/token}}]
contexts: [{name: in-cluster, context: {cluster: in-cluster, user: sa}}]
current-context: in-cluster
EOF
fi
template=()
[[ -z $TEMPLATE_DIR ]] || template=(--template-dir "$TEMPLATE_DIR")

seen=$(mktemp)         # repos already reported as having no token
fails=$(mktemp)        # one line per failed launch: owner/name/run/attempt
child=
# As PID 1 bash ignores SIGTERM unless trapped: pass it on so launch.sh cleans up.
trap '[[ -z $child ]] || { kill -TERM "$child" 2>/dev/null; wait "$child" || true; }; exit 143' TERM INT
trap 'rm -f "$seen" "$fails"' EXIT
once() { grep -qxF "$1" "$seen" && return 1; echo "$1" >>"$seen"; }

kd() { kubectl --request-timeout=20s "$@"; }

# A lock held by this dispatcher (an earlier process, or a launch.sh that could not
# confirm its cleanup): delete that launch's Job and pods, then the lock by UID.
# Called only while no launch is running. Locks of manual launches are left alone.
clear_stale_lock() {
  local lock holder owner uid pods
  lock=$(kd get configmap github-jit-lock -n "$NS" -o json --ignore-not-found) || return 1
  [[ -n $lock ]] || return 0
  holder=$(jq -r '.data.holder // "unknown"' <<<"$lock")
  if [[ $holder != dispatcher/* ]]; then
    log "lock held by $holder; leaving it"
    return 1
  fi
  owner=$(jq -r .data.owner <<<"$lock")
  uid=$(jq -r .metadata.uid <<<"$lock")
  kd delete jobs -n "$NS" -l "github-jit/owner=$owner" --cascade=foreground --wait --timeout=150s >/dev/null || return 1
  pods=$(kd get pods -n "$NS" -l "github-jit/owner=$owner" -o name) || return 1
  [[ -z $pods ]] || kd wait --for=delete $pods -n "$NS" --timeout=150s >/dev/null || return 1
  jq -n --arg uid "$uid" '{apiVersion: "v1", kind: "DeleteOptions", preconditions: {uid: $uid}}' |
    kd delete --raw "/api/v1/namespaces/$NS/configmaps/github-jit-lock" -f - >/dev/null || return 1
  log "cleared a stale lock (run $(jq -r .data.run <<<"$lock"), holder $holder)"
}

# Prints "<run_id> <attempt> <sha> <prefix>" for runs of $repo with a queued job
# labelled with one of the prefixes (one line per prefix found).
queued_runs() { # repo prefix...
  local repo=$1 runs id attempt sha labels
  shift
  runs=$(for status in queued in_progress; do
    gh api --paginate "repos/$repo/actions/runs?status=$status&per_page=100" \
      --jq '.workflow_runs[] | "\(.id) \(.run_attempt) \(.head_sha)"' || exit 1
  done) || return 1
  while read -r id attempt sha; do
    [[ -n $id ]] || continue
    labels=$(gh api "repos/$repo/actions/runs/$id/attempts/$attempt/jobs?per_page=100" \
      --jq '.jobs[] | select(.status == "queued") | .labels[]') || return 1
    for prefix in "$@"; do
      grep -qxF "$prefix-$id-$attempt" <<<"$labels" && echo "$id $attempt $sha $prefix"
    done
  done <<<"$runs"
  return 0
}

log "dispatching for executor $EXECUTOR every ${INTERVAL}s"
clear_stale_lock || true
while true; do
  for repo in $(yq -r '.repos | keys | .[]' "$ALLOWLIST"); do
    prefixes=$(yq -r ".repos[\"$repo\"] | [.label_prefix // \"jit\"] + ((.variants // {}) | keys) | .[]" "$ALLOWLIST")
    if ! GH_TOKEN=$(token "$repo" 2>/dev/null); then
      if once "no-token/$repo"; then log "$repo: no App token (App not installed there, or not ready)"; fi
      continue
    fi
    export GH_TOKEN
    # shellcheck disable=SC2086 # prefixes are [a-z0-9-] (launch.sh checks)
    if ! found=$(queued_runs "$repo" $prefixes); then
      log "$repo: GitHub poll failed"
      continue
    fi
    while read -r id attempt sha prefix; do
      [[ -n $id ]] || continue
      key=$repo/$id/$attempt/$prefix
      tries=$(grep -cxF "$key" "$fails" || true)
      ((tries < 3)) || continue
      log "$repo run $id/$attempt ($sha, $prefix): launching"
      GH_TOKEN_COMMAND=$here/dispatch.sh \
        "$here/launch.sh" run --executors "$EXECUTORS" --allowlist "$ALLOWLIST" \
          --executor "$EXECUTOR" ${template[@]+"${template[@]}"} --label-prefix "$prefix" \
          --repo "$repo" --run-id "$id" --sha "$sha" </dev/null &
      child=$!
      code=0; wait "$child" || code=$?
      child=
      log "$repo run $id/$attempt: launch exited $code"
      if ((code != 0)); then
        echo "$key" >>"$fails"
        clear_stale_lock || true
        ((tries < 2)) || log "$repo run $id/$attempt: gave up after 3 launches; re-run it in GitHub"
      fi
    done <<<"$found"
  done
  unset GH_TOKEN
  sleep "$INTERVAL" &
  wait $! || true
done
