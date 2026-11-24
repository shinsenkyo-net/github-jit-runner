# github-jit-runner

Disposable, one-job GitHub Actions runners on Kubernetes, each job in its own
QEMU/KVM VM, started for a single allowlisted workflow run. No standing runner
pool, no inbound webhook and no privileged pod.

| Path | What |
|---|---|
| `vm/` | Runner image that runs each job in its own QEMU/KVM VM. The pod is non-root with no capabilities; Docker is privileged only inside the guest. Needs `/dev/kvm` (e.g. `squat.ai/kvm` from squat/generic-device-plugin). |
| `launch.sh` | Operator-side launcher (bash, `gh`, `kubectl`, `jq`, `yq`): validates the run against an allowlist, creates one Job from a reviewed template, passes a single-job JIT registration over stdin, cleans up by UID. `launch.sh check` validates a template offline. |
| `dispatch.sh` | Polls GitHub and runs `launch.sh` for each queued job that asks for the executor, one at a time. Runs in-cluster as a GitHub App (one-hour tokens, one repository each) with a service account limited to the runner namespace. |
| `Dockerfile` | Dispatcher image: `dispatch.sh`, `launch.sh` and their tools. |
| `test.sh` | Offline launcher checks. |
| `examples/` | Executor profile, repository allowlist and a VM Job template. |

## How a run works

1. `dispatch.sh` sees a queued job with the run's label (or the operator
   picks a run and its full head SHA with `gh run list` and runs `launch.sh`).
2. `launch.sh` checks: repository allowlisted, run from the same repository
   (forks are refused), exact SHA, allowed workflow and event, branch/event
   rules for publishing workflows. It re-checks while waiting.
3. It creates the Job from a template that must match the executor profile
   (node, namespace, no token, bounded `emptyDir` only, exact limits,
   non-root and unprivileged).
4. Once the pod runs on the expected node, it mints a JIT registration with
   `gh` and writes it to the pod's stdin. The pod hands it to the guest over
   virtio-serial; it never appears in the pod spec, argv, env or files.
5. The runner takes exactly one job, the guest reports the result through
   `isa-debug-exit`, and the launcher deletes what it created.

The workflow job must request the per-run label:

```yaml
runs-on: [self-hosted, Linux, X64, "jit-${{ github.run_id }}-${{ github.run_attempt }}"]
```

Pair it with cluster-side admission policies pinning the namespace to its node,
a tokenless service account, a one-pod quota and an egress NetworkPolicy.

## Images

`ghcr.io/shinsenkyo-net/github-jit-runner` (VM) and
`ghcr.io/shinsenkyo-net/github-jit-dispatcher`, built and published by
`.github/workflows/publish.yml` on pushes to `main` and `v*` tags, with a
build provenance attestation.

Pin by digest. Verify provenance with
`gh attestation verify oci://IMAGE@DIGEST --owner shinsenkyo-net`.

## Security notes

- A self-hosted runner executes whatever the run contains. With the
  dispatcher, anyone who can push to an allowlisted repository can run code
  there: allowlist only repositories whose writers you trust.
- The dispatcher's GitHub App needs Administration read/write (runner
  registration) and Actions read: install it only on the allowlisted repositories.
- Fork runs are refused; public repositories are refused unless the allowlist
  says `public: true`.
- Docker inside the job is privileged only within the guest kernel. Escaping
  the job means escaping the guest and then QEMU, which runs as non-root with
  no capabilities in a tokenless pod.
- GPU jobs are out of scope: a VM would need device passthrough.
