# github-jit-runner

Disposable, one-job GitHub Actions runners on Kubernetes, each job in its own
QEMU/KVM VM, started for a single allowlisted workflow run. No standing runner
pool, no inbound webhook and no privileged pod.

| Path | What |
|---|---|
| `vm/` | Runner image that runs each job in its own QEMU/KVM VM (variants: base, and `macos-sdk` with Apple's macOS SDK). The pod is non-root with no capabilities; Docker is privileged only inside the guest. Needs `/dev/kvm` (e.g. `squat.ai/kvm` from squat/generic-device-plugin). |
| `launch.sh` | Operator-side launcher (bash, `gh`, `kubectl`, `jq`, `yq`): validates the run against an allowlist, creates one Job from a reviewed template, passes a single-job JIT registration over stdin, cleans up by UID. `launch.sh check` validates a template offline. |
| `dispatch.sh` | Polls GitHub and runs `launch.sh` for each queued job that asks for the executor, one at a time. Runs in-cluster as a GitHub App (one-hour tokens, one repository each) with a service account limited to the runner namespace. |
| `Dockerfile` | Dispatcher image: `dispatch.sh`, `launch.sh` and their tools. |
| `test.sh` | Offline launcher checks. |
| `examples/` | Executor profile, repository allowlist and a VM Job template. |

## How a run works

1. `dispatch.sh` sees a queued job with the run's label (or the operator
   picks a run and its full head SHA with `gh run list` and runs `launch.sh`).
2. `launch.sh` checks: repository allowlisted, run from the same repository
   (forks are refused), exact SHA, allowed workflow and event, branch/tag/event
   rules for publishing workflows (a tag-pinned run must be a tag push whose
   commit is on the default branch). It re-checks while waiting.
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

The prefix picks the image. A repository's `label_prefix` (default `jit`) gets
the executor's `template`; its `variants: {PREFIX: NAME}` map other prefixes to
the executor's `variants: {NAME: TEMPLATE}`, each a reviewed template pinning
another image under the same profile (node, namespace, limits). For the macOS
SDK variant, for example:

```yaml
runs-on: [self-hosted, Linux, X64, "jit-macos-sdk-${{ github.run_id }}-${{ github.run_attempt }}"]
```

That job still runs on Linux; the VM has the SDK at `/opt/macos-sdk` and
`SDKROOT` set, for cross-linking macOS binaries (e.g. zig, cargo-zigbuild).
One dispatcher serves every prefix of its executor, one run at a time: a
workflow whose jobs use two prefixes and depend on each other waits for the
first launch to finish before the second starts.

Pair it with cluster-side admission policies pinning the namespace to its node,
a tokenless service account, a one-pod quota and an egress NetworkPolicy.

## Images

`ghcr.io/shinsenkyo-net/github-jit-runner` (VM) and
`ghcr.io/shinsenkyo-net/github-jit-dispatcher`, built and published by
`.github/workflows/publish.yml` on pushes to `main` and `v*` tags, with a
build provenance attestation.

| Image | Tags |
|---|---|
| runner, base | `v1.0.0-runner2.337.0-ubuntu24.04`, `sha-<commit>`, `main` |
| runner, macOS SDK | the same with `-macos-sdk<version>`, e.g. `v1.0.0-runner2.337.0-ubuntu24.04-macos-sdk27.2` |
| dispatcher | `v1.0.0`, `sha-<commit>`, `main` |

The runner and Ubuntu versions come from `vm/Dockerfile`. The SDK variant
(`VARIANT=macos-sdk`) takes the newest Command Line Tools for Xcode from
Apple's public software update catalog at build time, with no Apple ID; its
package is checked against the catalog's digest, and the tag carries the
version read from the unpacked SDK's `SDKSettings.plist`. Apple's SDK license
applies to its use.

Pin by digest. Verify provenance with
`gh attestation verify oci://IMAGE@DIGEST --owner shinsenkyo-net`.

## Security notes

- A self-hosted runner executes whatever the run contains. With the
  dispatcher, anyone who can push to an allowlisted repository can run code
  there: allowlist only repositories whose writers you trust.
- The dispatcher's GitHub App needs Administration read/write (runner
  registration), Actions read and, for tag-pinned publish rules, Contents read
  (tag and default-branch checks): install it only on the allowlisted repositories.
- Fork runs are refused; public repositories are refused unless the allowlist
  says `public: true`.
- Docker inside the job is privileged only within the guest kernel. Escaping
  the job means escaping the guest and then QEMU, which runs as non-root with
  no capabilities in a tokenless pod.
- GPU jobs are out of scope: a VM would need device passthrough.
