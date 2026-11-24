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
