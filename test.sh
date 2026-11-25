#!/usr/bin/env bash
# Offline checks for launch.sh: the example template is accepted, unsafe edits
# and mutable images are rejected. Needs bash, jq, yq. No cluster or GitHub.
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
check() { ./launch.sh check --executors examples/executors.yaml --executor vm-node "$@"; }

check | jq -e '.spec.suspend == false and .spec.activeDeadlineSeconds == 120' >/dev/null
echo "example template accepted"

s='.spec.template.spec'
rejected=0
for edit in \
  "$s.nodeSelector[\"kubernetes.io/hostname\"] = \"other\"" \
  "$s.nodeName = \"other\"" \
  "$s.automountServiceAccountToken = true" \
  "$s.hostNetwork = true" \
  "$s.tolerations = [{\"operator\": \"Exists\"}]" \
  "$s.volumes += [{\"name\": \"h\", \"hostPath\": {\"path\": \"/\"}}]" \
  "$s.containers[0].resources.limits.cpu = \"64\"" \
  "$s.containers[0].securityContext.privileged = true" \
  "$s.containers[0].securityContext.capabilities = {\"add\": [\"SYS_ADMIN\"]}" \
  "$s.securityContext.runAsNonRoot = false" \
  "$s.containers[0].env = [{\"name\": \"X\", \"value\": \"y\"}]" \
  "$s.containers[0].tty = true" \
  "$s.containers[0].image = \"ghcr.io/example/runner:latest\""; do
  yq -o=json examples/job-vm.yaml | jq "$edit" >"$tmp/bad.json"
  if check --template "$tmp/bad.json" >/dev/null 2>&1; then
    echo "unsafe edit accepted: $edit" >&2
    exit 1
  fi
  rejected=$((rejected + 1))
done
echo "$rejected unsafe edits rejected"

# --- image variants ------------------------------------------------------------
yq -o=json examples/executors.yaml |
  jq '.executors["vm-node"].variants = {"macos-sdk": "job-vm.yaml"}' >"$tmp/executors.json"
cp examples/job-vm.yaml "$tmp/job-vm.yaml"
./launch.sh check --executors "$tmp/executors.json" --executor vm-node --variant macos-sdk >/dev/null
if ./launch.sh check --executors "$tmp/executors.json" --executor vm-node --variant other >/dev/null 2>&1; then
  echo "unknown image variant accepted" >&2; exit 1
fi
echo "image variants resolved"

# --- runs-on prefixes (fake gh; kubectl refuses, so an approved run stops at preflight) ---
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case $2 in
  repos/o/r) echo '{"visibility": "private", "default_branch": "main"}' ;;
  repos/o/r/actions/runs/1) cat "$FAKE_RUN" ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
GH
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/kubectl"
chmod +x "$tmp/bin/gh" "$tmp/bin/kubectl"
sha=$(printf '%040d' 1)
cat >"$tmp/repos.yaml" <<'YAML'
repos:
  o/r:
    label_prefix: jit
    variants: {jit-macos-sdk: macos-sdk}
    workflows: [.github/workflows/release.yml]
YAML
jq -n --arg sha "$sha" '{event: "workflow_dispatch", head_branch: "main", path: ".github/workflows/release.yml",
  head_sha: $sha, run_attempt: 1, status: "queued", conclusion: null,
  head_repository: {full_name: "o/r"}}' >"$tmp/run.json"
verdict() { # [label-prefix]: prints approved|refused
  local err
  err=$(FAKE_RUN=$tmp/run.json PATH="$tmp/bin:$PATH" ./launch.sh run --executors "$tmp/executors.json" \
    --executor vm-node --allowlist "$tmp/repos.yaml" --repo o/r --run-id 1 --sha "$sha" \
    ${1:+--label-prefix "$1"} 2>&1 >/dev/null) || true
  case $err in *"is not available"*) echo approved ;; *) echo refused ;; esac
}
expect() { # want got description
  [[ $1 == "$2" ]] || { echo "prefixes: expected $1, got $2: $3" >&2; exit 1; }
}
expect approved "$(verdict)" "repository label_prefix"
expect approved "$(verdict jit-macos-sdk)" "variant prefix"
expect refused "$(verdict jit-other)" "prefix the repository does not map"
echo "runs-on prefixes: label_prefix and mapped variants only"
