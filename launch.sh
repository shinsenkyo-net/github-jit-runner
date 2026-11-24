#!/usr/bin/env bash
# Run one explicitly approved GitHub workflow run on a disposable Kubernetes Job.
#
#   ./launch.sh run \
#     --executors EXECUTORS.yaml --allowlist REPOS.yaml --executor NAME \
#     --repo OWNER/NAME --run-id ID --sha FULL_HEAD_SHA \
#     [--kubeconfig KUBECONFIG --context CONTEXT] [--minutes 90] [--runner-image IMG@sha256:...]
#
#   ./launch.sh check --executors EXECUTORS.yaml --executor NAME [--template FILE]
#     Offline: validate a Job template against its executor profile, print the Job.
#
# The operator approves one run (id + full head SHA). The launcher re-validates
# it against the allowlist, creates one Job from a reviewed template, waits for
# the pod on the expected node, then mints a single-job JIT registration with
# `gh` and passes it only through non-TTY stdin: never argv, env, files or logs.
# Without --kubeconfig, kubectl uses its in-cluster service account (dispatch.sh).
# No App key or automatic fallback; cleanup deletes only resources it created
# (by UID). Needs bash, gh, kubectl, jq, yq, openssl.
set -euo pipefail
umask 077

JOB=github-jit-runner
LOCK=github-jit-lock
OWNER_LABEL=github-jit/owner

die() { echo "launch: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing tool: $1"; }

mode=${1:-}; shift || true
[[ $mode == run || $mode == check ]] || die "usage: launch.sh run|check ... (see header)"
EXECUTORS= ALLOWLIST= EXECUTOR= REPO= RUN_ID= SHA= MINUTES=90 KCFG= CONTEXT= IMAGE= TEMPLATE=
while (($#)); do
  case $1 in
    --executors) EXECUTORS=$2 ;; --allowlist) ALLOWLIST=$2 ;; --executor) EXECUTOR=$2 ;;
    --repo) REPO=$2 ;; --run-id) RUN_ID=$2 ;; --sha) SHA=$2 ;; --minutes) MINUTES=$2 ;;
    --kubeconfig) KCFG=$2 ;; --context) CONTEXT=$2 ;; --runner-image) IMAGE=$2 ;;
    --template) TEMPLATE=$2 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift 2
done
for tool in jq yq; do need "$tool"; done
[[ -n $EXECUTORS && -n $EXECUTOR ]] || die "--executors and --executor are required"

# --- executor profile and Job template -------------------------------------

PROFILE=$(yq -o=json ".executors[\"$EXECUTOR\"]" "$EXECUTORS")
[[ $PROFILE != null ]] || die "unknown executor: $EXECUTOR"
for key in node namespace template pod_policy binding_policy tolerations dns_policy limits unprivileged; do
  jq -e --arg k "$key" 'has($k)' <<<"$PROFILE" >/dev/null || die "executor $EXECUTOR: missing $key"
done
NODE=$(jq -r .node <<<"$PROFILE")
NS=$(jq -r .namespace <<<"$PROFILE")
[[ -n $TEMPLATE ]] || TEMPLATE="$(dirname "$EXECUTORS")/$(jq -r .template <<<"$PROFILE")"
TEMPLATE_JSON=$(yq -o=json "$TEMPLATE")
[[ -n $IMAGE ]] || IMAGE=$(jq -r '.spec.template.spec.containers[0].image' <<<"$TEMPLATE_JSON")

# Reject any template that could place job code outside the reviewed boundary,
# then fill in the per-run fields. Prints the Job JSON.
prepare_job() { # owner run_id attempt seconds
  jq --argjson p "$PROFILE" --arg image "$IMAGE" --arg owner "$1" \
     --arg run "$2" --arg attempt "$3" --argjson seconds "$4" --arg job "$JOB" \
     --arg owner_label "$OWNER_LABEL" '
    def nonempty: (. // []) | length > 0;
    if $seconds <= 0 then error("time budget exhausted before Job creation") else . end
    | if ($image | test("^[^@\\s]+@sha256:[0-9a-f]{64}$") | not)
        then error("runner image must be an immutable image@sha256:<digest>") else . end
    | if .apiVersion != "batch/v1" or .kind != "Job" or .metadata.namespace != $p.namespace
        then error("expected a batch/v1 Job in \($p.namespace)") else . end
    | .spec.template.spec as $s
    | if ($s.nodeSelector["kubernetes.io/hostname"] != $p.node)
         or ($s.nodeSelector["kubernetes.io/arch"] != "amd64")
         or (($s.nodeName // $p.node) != $p.node)
         or ($s.automountServiceAccountToken != false)
         or ($s.serviceAccountName != "github-jit-runner")
         or ($s.restartPolicy != "Never")
         or (($s.tolerations // []) != ($p.tolerations // []))
         or (($s.dnsPolicy // null) != $p.dns_policy)
         or ($s.initContainers | nonempty)
         or ([$s.hostNetwork, $s.hostPID, $s.hostIPC] | any(. == true))
        then error("Job must be tokenless, non-restarting and \($p.node)-only") else . end
    | if ($s.volumes | nonempty | not)
         or ($s.volumes | any((keys != ["emptyDir", "name"]) or (.emptyDir.sizeLimit == null)))
        then error("only size-limited emptyDir volumes are permitted") else . end
    | if ($s.containers | length) != 1 or $s.containers[0].name != "runner"
        then error("expected exactly one runner container") else . end
    | $s.containers[0] as $c
    | if $c.stdin != true or $c.stdinOnce != true or ($c.tty // false)
         or ($c.command | nonempty) or ($c.args | nonempty)
         or ($c.env | nonempty) or ($c.envFrom | nonempty)
        then error("use the pinned image entrypoint and non-TTY, one-shot stdin") else . end
    | if $p.unprivileged then
        ($c.securityContext // {}) as $sc | ($s.securityContext // {}) as $ps
        | if ($sc.privileged == true) or ($sc.allowPrivilegeEscalation != false)
             or (($sc.capabilities.drop // []) != ["ALL"]) or ($sc.capabilities.add | nonempty)
             or ($sc.readOnlyRootFilesystem != true) or ($ps.runAsNonRoot != true)
            then error("\($p.node) runner must be non-root and unprivileged") else . end
      else . end
    | if ($c.resources.limits // {}) != $p.limits
        then error("runner resource limits differ from the approved \($p.node) budget") else . end
    | .spec.template.spec.containers[0].image = $image
    | .metadata = {name: $job, namespace: $p.namespace, labels: {($owner_label): $owner},
                   annotations: {"github-jit/run-id": $run, "github-jit/attempt": $attempt}}
    | .spec += {suspend: false, parallelism: 1, completions: 1, completionMode: "NonIndexed",
                backoffLimit: 0, ttlSecondsAfterFinished: 600, podReplacementPolicy: "Failed",
                activeDeadlineSeconds: ([5400, ([1, ($seconds | ceil)] | max)] | min)}
    | .spec.template.metadata = {labels: {($owner_label): $owner}}
  ' <<<"$TEMPLATE_JSON"
}

if [[ $mode == check ]]; then
  prepare_job check 1 1 120
  exit 0
fi

# --- run mode ----------------------------------------------------------------

for tool in gh kubectl; do need "$tool"; done
[[ -n $ALLOWLIST && -n $REPO && -n $RUN_ID && -n $SHA ]] || die "run needs --allowlist --repo --run-id --sha"
KARGS=()
[[ -z $KCFG ]] || KARGS+=(--kubeconfig "$KCFG")
[[ -z $CONTEXT ]] || KARGS+=(--context "$CONTEXT")
[[ $RUN_ID =~ ^[0-9]+$ ]] || die "--run-id must be numeric"
[[ $SHA =~ ^[0-9a-f]{40}$ ]] || die "--sha must be the full 40-hex head SHA"
[[ $MINUTES =~ ^[1-9][0-9]*$ ]] || die "--minutes must be positive"
POLICY=$(yq -o=json ".repos[\"$REPO\"]" "$ALLOWLIST")
[[ $POLICY != null ]] || die "$REPO is not in the reviewed allowlist"
PREFIX=$(jq -r '.label_prefix // "jit"' <<<"$POLICY")
[[ $PREFIX =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "label_prefix must be short lowercase [a-z0-9-]"

kc() { kubectl ${KARGS[@]+"${KARGS[@]}"} --request-timeout=20s "$@"; }

# Approval check for the run; repeated while waiting and before registration.
# Prints {run_attempt, status, conclusion}.
approve() {
  local repo run
  repo=$(gh api "repos/$REPO") || return 1
  run=$(gh api "repos/$REPO/actions/runs/$RUN_ID") || return 1
  jq -n --argjson repo "$repo" --argjson run "$run" --argjson policy "$POLICY" \
        --arg name "$REPO" --arg sha "$SHA" '
    if $repo.visibility != "private" and ($policy.public // false) != true
      then error("public repository not approved for self-hosted runs")
    elif $run.head_repository.full_name != $name then error("fork workflow runs are not accepted")
    elif $run.head_sha != $sha then error("run SHA does not match the approved full SHA")
    elif (["pull_request", "push", "workflow_dispatch"] | index($run.event)) == null
      then error("unsupported workflow event")
    else ([($policy.publish // [])[] | select(.path == $run.path)] | first) as $rule
      | if $rule != null then
          if ($rule.branches | index($run.head_branch)) == null or ($rule.events | index($run.event)) == null
            then error("publication run is outside its approved branch/event") else . end
        elif (($policy.workflows // []) | index($run.path)) == null
          then error("workflow is not in the reviewed allowlist")
        else . end
      | $run | {run_attempt, status, conclusion}
    end'
}

# The run must still be the approved, unfinished attempt.
still_approved() {
  local cur
  cur=$(approve) || die "approval check failed"
  [[ $(jq -r .run_attempt <<<"$cur") == "$ATTEMPT" && $(jq -r .status <<<"$cur") != completed ]] ||
    die "run completed or approval changed while waiting for $NODE"
}

runner_ids_with_label() { # label
  gh api --paginate "repos/$REPO/actions/runners?per_page=100" \
    --jq ".runners[] | select(any(.labels[]; .name == \"$1\")) | .id"
}

remove_runner() { # id; JIT normally unregisters itself
  if gh api --paginate "repos/$REPO/actions/runners?per_page=100" --jq ".runners[] | .id" | grep -qx "$1"; then
    gh api --method DELETE "repos/$REPO/actions/runners/$1" >/dev/null
  fi
}

delete_owned() { # resource name uid
  local base=/api/v1
  [[ $1 == jobs ]] && base=/apis/batch/v1
  jq -n --arg uid "$3" '{apiVersion: "v1", kind: "DeleteOptions",
      preconditions: {uid: $uid}, propagationPolicy: "Foreground"}' |
    kc delete --raw "$base/namespaces/$NS/$1/$2" -f - >/dev/null &&
    kc wait --for=delete "$1/$2" -n "$NS" --timeout=90s >/dev/null
}

job_pod() { # prints the owned pod JSON, or nothing
  local pods
  pods=$(kc get pods -n "$NS" -l "$OWNER_LABEL=$OWNER" -o json) || return 1
  [[ $(jq '.items | length' <<<"$pods") -le 1 ]] || die "multiple job pods found; refusing registration"
  jq -c '.items[0] // empty' <<<"$pods"
}

OWNER=$(openssl rand -hex 12)
JOB_UID= RUNNER_ID= LOCK_UID= SAFE_TO_UNLOCK=true

# Delete this attempt's Job (and wait for its pod) and any leftover runner.
cleanup_job() {
  local ok=true pod
  if [[ -n $JOB_UID ]]; then
    delete_owned jobs "$JOB" "$JOB_UID" || ok=false
    # Job deletion can precede a terminating pod disappearing.
    pod=$(job_pod) || ok=false
    if [[ -n ${pod:-} ]]; then
      kc wait --for=delete "pod/$(jq -r .metadata.name <<<"$pod")" -n "$NS" --timeout=90s >/dev/null || ok=false
    fi
  fi
  if [[ -n $RUNNER_ID ]]; then
    remove_runner "$RUNNER_ID" || ok=false
  fi
  if $ok; then JOB_UID= RUNNER_ID= SAFE_TO_UNLOCK=true; fi
  $ok
}

on_exit() {
  local code=$?
  trap - EXIT
  [[ -z $JOB_UID && -z $RUNNER_ID ]] || cleanup_job || true
  if [[ -n $LOCK_UID ]]; then
    if $SAFE_TO_UNLOCK; then
      delete_owned configmaps "$LOCK" "$LOCK_UID" || { echo "launch: lock release failed" >&2; code=1; }
    else
      echo "launch: $NODE cleanup unconfirmed; retaining $LOCK for inspection" >&2
      code=1
    fi
  fi
  exit "$code"
}

execute_job() {
  local job phase pod pod_name= startup reg payload
  job=$(prepare_job "$OWNER" "$RUN_ID" "$ATTEMPT" $((DEADLINE - SECONDS))) || die "Job preparation failed"
  SAFE_TO_UNLOCK=false
  JOB_UID=$(kc create -f - -o jsonpath='{.metadata.uid}' <<<"$job")
  echo "Waiting for one $NODE job: $JOB ($REPO run $RUN_ID/$ATTEMPT)"
  startup=$((SECONDS + 300)); ((startup < DEADLINE)) || startup=$DEADLINE
  while ((SECONDS < startup)); do
    still_approved
    pod=$(job_pod)
    phase=$(jq -r '.status.phase // empty' <<<"${pod:-null}")
    if [[ $phase == Running ]]; then
      [[ $(jq -r .spec.nodeName <<<"$pod") == "$NODE" ]] || die "actual pod placement is not $NODE"
      pod_name=$(jq -r .metadata.name <<<"$pod")
      break
    fi
    [[ $phase != Failed && $phase != Succeeded ]] || die "Job exited before receiving registration"
    sleep 3
  done
  [[ -n $pod_name ]] || die "$NODE pod did not start within 5 min/budget"
  still_approved
  ((SECONDS < DEADLINE)) || die "budget exhausted before registration"

  payload=$(jq -n --arg name "jit-$NODE-$RUN_ID-$ATTEMPT-$OWNER" --arg label "$LABEL" \
    '{name: $name, runner_group_id: 1, labels: ["self-hosted", "Linux", "X64", $label], work_folder: "_work"}')
  # The registration exists only in this variable and the attach stdin pipe.
  reg=$(gh api --method POST "repos/$REPO/actions/runners/generate-jitconfig" --input - <<<"$payload")
  RUNNER_ID=$(printf '%s' "$reg" | jq -r .runner.id)
  # Never retry an interrupted attach with this credential.
  if ! printf '%s\n' "$reg" | jq -r .encoded_jit_config |
      kubectl ${KARGS[@]+"${KARGS[@]}"} --request-timeout=0 \
        attach -i "$pod_name" -n "$NS" -c runner; then
    reg=
    die "$NODE attach failed; inspect cleanup before retrying"
  fi
  reg=
  while ((SECONDS < DEADLINE)); do
    pod=$(job_pod)
    phase=$(jq -r '.status.phase // empty' <<<"${pod:-null}")
    case $phase in
      Succeeded) cleanup_job || die "cleanup unconfirmed"; return 0 ;;
      Failed | "") die "$NODE runner did not exit successfully" ;;
    esac
    sleep 2
  done
  die "$NODE job exceeded its approved budget"
}

# --- preflight -----------------------------------------------------------------

INITIAL=$(approve) || die "run not approved"
[[ $(jq -r .status <<<"$INITIAL") != completed ]] || die "run already completed; rerun it in GitHub first"
ATTEMPT=$(jq -r .run_attempt <<<"$INITIAL")
LABEL="$PREFIX-$RUN_ID-$ATTEMPT"
prepare_job "$OWNER" 1 1 60 >/dev/null || die "template rejected"
kc get node "$NODE" -o json |
  jq -e '(.spec.unschedulable // false) == false and
         any(.status.conditions[]; .type == "Ready" and .status == "True")' >/dev/null ||
  die "$NODE is not available; no automatic fallback"
# Presence is a prerequisite, not proof of enforcement: run a live smoke first.
kc get namespace "$NS" -o name >/dev/null
kc get validatingadmissionpolicybinding \
  "$(jq -r .pod_policy <<<"$PROFILE")" "$(jq -r .binding_policy <<<"$PROFILE")" -o name >/dev/null
kc get networkpolicy/github-jit-egress resourcequota/github-jit-budget -n "$NS" -o name >/dev/null

DEADLINE=$((SECONDS + MINUTES * 60))
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
LOCK_UID=$(kc create configmap "$LOCK" -n "$NS" \
  --from-literal=owner="$OWNER" --from-literal=repo="$REPO" --from-literal=run="$RUN_ID" \
  --from-literal=sha="$SHA" --from-literal=attempt="$ATTEMPT" -o jsonpath='{.metadata.uid}')

# --- supervise -----------------------------------------------------------------

SUPPORTED=$(jq -cn --arg label "$LABEL" '["self-hosted", "Linux", "X64", $label]')
while ((SECONDS < DEADLINE)); do
  cur=$(approve) || die "approval check failed"
  [[ $(jq -r .run_attempt <<<"$cur") == "$ATTEMPT" ]] || die "run attempt changed; approve the new attempt explicitly"
  if [[ $(jq -r .status <<<"$cur") == completed ]]; then
    conclusion=$(jq -r .conclusion <<<"$cur")
    echo "Workflow completed: $conclusion"
    [[ $conclusion == success ]]
    exit
  fi
  verdict=$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" |
    jq -r --arg label "$LABEL" --argjson sup "$SUPPORTED" '
      [.jobs[] | select(.status == "queued")] as $queued
      | ($queued | map(select(.labels | index($label)))) as $mine
      | if ($mine | length) > 0 then
          if ($mine | all((.labels - $sup) | length == 0)) then "run" else "unsupported" end
        elif ($queued | length) > 0 and ($queued | all((.labels | index("self-hosted")) == null))
             and (.jobs | all((.labels | index($label)) == null))
          then "hosted"
        else "wait" end')
  case $verdict in
    run)
      # Stale-runner check, not a cross-machine lock: never run two launchers
      # for the same run/attempt.
      [[ -z $(runner_ids_with_label "$LABEL") ]] || die "a runner already advertises this attempt; inspect it"
      execute_job ;;
    unsupported) die "queued job requires labels this executor cannot supply" ;;
    hosted) die "workflow still targets hosted runners; migrate it first" ;;
    *) sleep 5 ;;
  esac
done
die "workflow time budget exhausted"
