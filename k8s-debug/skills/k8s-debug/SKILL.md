---
name: k8s-debug
description: >
  Use when the user wants to debug, investigate, or troubleshoot Kubernetes
  clusters, pods, deployments, services, nodes, or any k8s resource. Trigger on
  keywords like "pod crashing", "CrashLoopBackOff", "OOMKilled", "ImagePullBackOff",
  "pending pod", "node pressure", "cluster health", "kubectl", "k8s issue",
  "what's wrong with my deployment", "debug namespace", "check logs", "pod not
  starting", "service not reachable", "resource limits", "evicted pods",
  "kubeconfig", "switch cluster", "which context". Also trigger when the user
  asks about Kubernetes events, resource usage, Helm release status, or wants
  to inspect anything running in a cluster. Also trigger when the user provides
  an ArgoCD URL (argocd.*.dipscloudsl.com) for a degraded or unhealthy
  application — extract the cluster name from the URL subdomain and resolve it
  to the correct local kubectl context.
---

# Kubernetes Cluster Debugging

Safe, structured investigation of Kubernetes issues using local kubeconfigs.
Always read before you act: gather full context before suggesting any change.

---

## Prerequisites

- `kubectl` installed and on PATH
- One or more kubeconfig files (default: `~/.kube/config`)
- Optional but recommended: `kubectx`/`kubens`, `stern`, `kubecolor`, `helm`

---

## Cluster and context selection

**Multiple clusters are common. Always confirm the target before running anything.**

```bash
# List all contexts across all kubeconfigs
kubectl config get-contexts

# Show current context
kubectl config current-context

# Switch context (ask user to confirm first)
kubectl config use-context <context-name>

# Or use kubectx for fast switching
kubectx                  # list
kubectx <context-name>   # switch
```

If the user has kubeconfigs in non-default locations:

```bash
# Point to a specific file
kubectl --kubeconfig /path/to/config get nodes

# Merge multiple files for this session
$env:KUBECONFIG = "C:\Users\me\.kube\config-prod;C:\Users\me\.kube\config-staging"
kubectl config get-contexts
```

**Always use `--context` and `--namespace` flags explicitly** in commands you
run for the user — never rely on the ambient default silently targeting the
wrong cluster.

---

## ArgoCD URL → local context resolution

When the user provides an ArgoCD URL, extract the cluster name from the subdomain and match it to a local kubectl context **before running any commands**.

### URL pattern

```
https://argocd.smud.<cluster-name>.dipscloudsl.com/applications/...
                     ^^^^^^^^^^^^
                     extract this segment
```

**Example:**
```
https://argocd.smud.slaks.dipscloudsl.com/applications/argocd/notificationcenter-development-aks-sldev-ak01
                     ^^^^^ → cluster name: slaks
```

### Resolution steps

1. **Run `get-contexts` first** — always do this immediately when an ArgoCD URL is provided, before any other action:
   ```bash
   kubectl config get-contexts
   ```
   This gives you the full list of available local contexts to work with.

2. **Parse the cluster name** from position 3 of the hostname (0-indexed):
   ```
   hostname segments: argocd . smud . slaks . dipscloudsl . com
   index:               0       1       2         3           4
   → cluster name = segment[2]
   ```

3. **Match against the context list** — find a context whose name contains the extracted cluster name as a substring (case-insensitive).

4. **Confirm the match with the user** — show them:
   - Extracted cluster name: `slaks`
   - Matched local context: `<context-name>`
   - If multiple contexts match, list them all and ask which to use.
   - If no context matches, tell the user and ask them to provide the correct context.

5. **Use the matched context** for all subsequent kubectl commands via `--context <matched-context>`.

### Example resolution

```
ArgoCD URL:  https://argocd.smud.slaks.dipscloudsl.com/applications/argocd/notificationcenter-development-aks-sldev-ak01
Cluster:     slaks
Local match: aks-sldev-ak01  (or whichever context contains "slaks")
```

```bash
# Verify the matched context resolves correctly
kubectl get nodes --context <matched-context>
```

> Never assume the context — always show the user the extracted cluster name and the matched context before proceeding.

---

## Investigation order

Work read-only from broad to narrow. Never suggest a fix before completing step 3.

1. **Cluster health** — nodes, resource pressure
2. **Namespace overview** — what's unhealthy?
3. **Resource detail** — describe the specific failing object
4. **Logs** — container stdout/stderr
5. **Events** — cluster-wide timeline of what happened
6. **Hypothesis → fix** — only after the above

---

## Step 1 — Cluster health

```bash
# Node status and conditions
kubectl get nodes -o wide --context <ctx>

# Node resource usage (requires metrics-server)
kubectl top nodes --context <ctx>

# Check for node pressure conditions
kubectl describe nodes --context <ctx> | grep -A5 "Conditions:"

# All pods across all namespaces — spot non-Running at a glance
kubectl get pods -A --context <ctx> | grep -v Running | grep -v Completed
```

---

## Step 2 — Namespace overview

```bash
# List namespaces
kubectl get namespaces --context <ctx>

# Everything in a namespace
kubectl get all -n <ns> --context <ctx>

# Just pods with status
kubectl get pods -n <ns> -o wide --context <ctx>

# Pod resource usage
kubectl top pods -n <ns> --context <ctx>

# Recent events in namespace (sorted by time)
kubectl get events -n <ns> --sort-by='.lastTimestamp' --context <ctx>
```

---

## Step 3 — Describe the failing resource

`describe` is the single most useful command — always run it before checking logs.

```bash
# Pod detail: conditions, events, resource requests, image, mounts
kubectl describe pod <pod-name> -n <ns> --context <ctx>

# Deployment rollout status
kubectl describe deployment <name> -n <ns> --context <ctx>

# Service endpoints (is it selecting any pods?)
kubectl describe service <name> -n <ns> --context <ctx>

# PVC binding state
kubectl describe pvc <name> -n <ns> --context <ctx>
```

---

## Step 4 — Logs

```bash
# Current container logs
kubectl logs <pod> -n <ns> --context <ctx>

# Previous container (after a crash)
kubectl logs <pod> -n <ns> --previous --context <ctx>

# Specific container in a multi-container pod
kubectl logs <pod> -c <container> -n <ns> --context <ctx>

# Tail + follow
kubectl logs <pod> -n <ns> --tail=100 -f --context <ctx>

# All pods matching a label (requires stern)
stern -n <ns> --context <ctx> <label-selector>
```

---

## Step 5 — Events

```bash
# All events in namespace, newest last
kubectl get events -n <ns> --sort-by='.lastTimestamp' --context <ctx>

# Filter to a specific pod
kubectl get events -n <ns> --field-selector involvedObject.name=<pod-name> --context <ctx>

# Warning events only
kubectl get events -n <ns> --field-selector type=Warning --context <ctx>
```

---

## Common failure patterns

### CrashLoopBackOff

```bash
kubectl describe pod <pod> -n <ns> --context <ctx>   # check Exit Code and Last State
kubectl logs <pod> -n <ns> --previous --context <ctx>  # logs from crashed container
```

Exit codes to know:
- `1` — application error (check app logs)
- `137` — OOMKilled or SIGKILL (check memory limits)
- `139` — segfault
- `143` — SIGTERM (graceful shutdown, usually harmless)

### OOMKilled

```bash
# Confirm OOMKilled in describe output
kubectl describe pod <pod> -n <ns> --context <ctx> | grep -A3 "Last State"

# Check current memory usage vs limits
kubectl top pod <pod> -n <ns> --context <ctx>

# Check what limits are set
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.containers[*].resources}' --context <ctx>
```

### ImagePullBackOff / ErrImagePull

```bash
kubectl describe pod <pod> -n <ns> --context <ctx>  # look at Events section
# Common causes: wrong image name/tag, missing imagePullSecret, registry unreachable
```

### Pending pod

```bash
kubectl describe pod <pod> -n <ns> --context <ctx>
# Look for: Insufficient cpu/memory, no nodes match affinity, PVC not bound, taint/toleration mismatch
kubectl get events -n <ns> --field-selector involvedObject.name=<pod-name> --context <ctx>
```

### Service not reachable

```bash
# Check endpoints — if empty, selector doesn't match any pods
kubectl get endpoints <svc> -n <ns> --context <ctx>
kubectl describe service <svc> -n <ns> --context <ctx>

# Check pod labels match service selector
kubectl get pods -n <ns> --show-labels --context <ctx>
```

### Node pressure / evictions

```bash
kubectl describe nodes --context <ctx> | grep -E "Pressure|Evict|Condition"
kubectl get pods -A --field-selector status.phase=Failed --context <ctx>
kubectl get events -A --field-selector reason=Evicted --context <ctx>
```

---

## Helm releases

```bash
# List all releases
helm list -A --kube-context <ctx>

# Release status and last deployed
helm status <release> -n <ns> --kube-context <ctx>

# Values currently in use
helm get values <release> -n <ns> --kube-context <ctx>

# Rendered manifests
helm get manifest <release> -n <ns> --kube-context <ctx>

# History of rollouts
helm history <release> -n <ns> --kube-context <ctx>
```

---

## Quick health snapshot (run as a first pass)

```bash
# Paste these 4 commands to get a full picture fast
kubectl get nodes -o wide --context <ctx>
kubectl get pods -A --context <ctx> | grep -v -E "Running|Completed"
kubectl get events -A --sort-by='.lastTimestamp' --context <ctx> | tail -30
kubectl top nodes --context <ctx>
```

---

## Safety rules

- **Never run mutating commands** (`kubectl delete`, `kubectl apply`, `kubectl rollout restart`, `helm upgrade`, `helm rollback`) without explicit user confirmation and stating exactly what will change.
- **Always include `--context` explicitly** — never rely on the current-context ambient default when the user has multiple clusters.
- **Always include `--namespace`** (`-n`) — never assume `default`.
- When suggesting a fix, state: which cluster, which namespace, what the command does, and what the rollback looks like.
- Prefer `--dry-run=client` when available to preview changes before applying.
- For destructive operations (delete, force-delete), **stop and confirm** even if the user said "just fix it".

---

## Useful aliases to suggest

```bash
# Add to shell profile
alias kctx='kubectl config use-context'
alias kns='kubectl config set-context --current --namespace'
alias kgp='kubectl get pods -o wide'
alias kge='kubectl get events --sort-by=.lastTimestamp'
alias kdp='kubectl describe pod'
```

---

## Works well with

- `argocd` skill — for GitOps sync/rollback after diagnosing
- `helm-qa` skill — for validating charts before re-deployment
- `dips-core:spector` skill — for checking what version is deployed per environment
