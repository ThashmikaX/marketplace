# k8s-debug

Kubernetes cluster debugging skill for Claude Code. Guides safe, structured investigation of pod failures, resource pressure, network issues, and cluster health using local kubeconfigs.

## Skill

### `k8s-debug:k8s-debug`

Triggered automatically when you describe a Kubernetes problem — crashing pods, OOMKilled containers, pending resources, unreachable services, node pressure, or anything kubectl-related.

**Trigger examples:**
- "why is my pod in CrashLoopBackOff?"
- "debug the staging namespace"
- "pod not starting in production"
- "check cluster health"
- "service not reachable"

## Prerequisites

- `kubectl` installed and on PATH
- One or more kubeconfig files (default: `~/.kube/config`)
- Optional: `kubectx`/`kubens`, `stern`, `helm`

## Investigation approach

The skill follows a read-first methodology: cluster health → namespace overview → resource describe → logs → events → hypothesis. It never suggests a mutating command before completing the read phase, and always requires explicit `--context` and `--namespace` flags to avoid silent mis-targeting.

## Works well with

- `argocd` — GitOps sync and rollback after diagnosis
- `dips-core:spector` — check what version is deployed per environment
- `dips-core:helm-qa` — validate charts before re-deployment
