# Kata Agent Policies

This directory contains the Kata agent policy files used to control what operations the Kata agent allows inside the TDX VM. The policy is selected at build time via `POLICY_MODE` and embedded in the initdata blob.

## Files

- `policy-dev.rego` — Permissive policy for development. All container operations are allowed. **Do not use in production.**
- `policy-locked.rego` — Restrictive policy for production. Only the `model-init` init container and `app` container are allowed, with pinned commands. The `{model_image_repo}` and `{app_image_repo}` placeholders are substituted at build time by `scripts/build-initdata.py`.

## How it works

The Kata agent loads the policy from the initdata on VM boot and enforces it using [Open Policy Agent (OPA)](https://www.openpolicyagent.org/). Every ttrpc API call from the host to the Kata agent is evaluated against the policy before being executed. Calls that do not match any allow rule are denied.

`default <RequestName> := false` means the request is denied unless an explicit rule returns `true`. Multiple rules with the same name act as logical OR — any matching rule allows the request.

Key input fields for `CreateContainerRequest`:

| Field | Description |
|---|---|
| `input.OCI.Annotations["io.kubernetes.cri.container-name"]` | Container name from the pod spec |
| `input.OCI.Annotations["io.kubernetes.cri.image-name"]` | Image reference (may be tag-based `repo:tag` or digest-based `repo@sha256:...`) |
| `input.OCI.Process.Args` | The full command and arguments array |

Note: `ExecProcessRequest` uses `input.process.Args` (lowercase) — a different input schema from `CreateContainerRequest`.

## References

- [How to use the Kata agent policy](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-the-kata-agent-policy.md) — overview of policy enforcement and rule format
- [genpolicy rules.rego](https://github.com/kata-containers/kata-containers/blob/main/src/tools/genpolicy/rules.rego) — the reference rules file used by the genpolicy tool; authoritative source for input field paths
- [Confidential Containers initdata docs](https://confidentialcontainers.org/docs/features/initdata/) — how the policy is delivered via initdata and measured into the TEE
- [genpolicy tool](https://github.com/kata-containers/kata-containers/tree/main/src/tools/genpolicy) — tool for auto-generating policies from Kubernetes YAML; useful for understanding what a fully generated policy looks like
