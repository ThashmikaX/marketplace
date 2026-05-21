# keycloak-test

Runs Keycloak test scripts against a selected Kubernetes cluster and displays a
visual pass/fail report. Scripts can be loaded from a **local directory** or from
**Kubernetes ConfigMaps** — no WSL required on Windows.

---

## How it works

1. Detects a usable bash (Git Bash preferred on Windows, then WSL, then system bash)
2. Lists your kubectl contexts and asks which cluster to target
3. Asks whether to load scripts from a local path or from cluster ConfigMaps
4. Creates an isolated temp kubeconfig so scripts hit the correct cluster without
   touching your global `~/.kube/config` current-context
5. Executes each script with a 30-second timeout, capturing stdout + stderr
6. Renders a visual results table with a summary progress bar

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| `kubectl` | Cluster access and ConfigMap discovery |
| **Git Bash** (Windows) | Run bash scripts natively — `git-scm.com/download/win` |
| `bash` (Linux/macOS) | Already on PATH |
| kubeconfig | Must have access to the target cluster |

> **Windows note:** Git Bash is strongly preferred over WSL because WSL bash cannot
> be launched with redirected I/O from certain process contexts (HCS error 0x80070569).
> Git Bash ships with Git for Windows and works without any extra configuration.

---

## Script sources

### Local directory (recommended)

Point the skill at a directory of `.sh` files on disk:

```
D:\DIPS\Repos\SMUD-IAM\keycloak-service\helm\test-scripts\
  test-group1-platform-health.sh
  test-group2-keycloak-core.sh
  test-group3-db-cache.sh
  test-group4-oidc-discovery.sh
```

The scripts use `${KUBECONFIG:-${SCRIPT_DIR}/...kubeconfig}`. The skill sets
`KUBECONFIG` to a temporary single-context kubeconfig before each run, so the
scripts automatically use the right cluster regardless of their default path.

### ConfigMap discovery

Alternatively, discover scripts from the cluster itself:

```bash
kubectl get cm -n iam -l app.kubernetes.io/component=test-scripts
```

Each key in the ConfigMap `data` field is treated as a separate script.
Exit code `0` = PASS, any non-zero = FAIL.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-login-flow
  namespace: iam
  labels:
    app.kubernetes.io/component: test-scripts
  annotations:
    description: "Verify Keycloak login returns a valid token"
data:
  script.sh: |
    #!/usr/bin/env bash
    set -euo pipefail
    TOKEN=$(kubectl exec ... -- curl -sf .../token | jq -r '.access_token')
    [ "$TOKEN" != "null" ] && echo "Token acquired" || { echo "Login failed"; exit 1; }
```

---

## Example output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Keycloak Test Report
  Cluster  : slintest-admin@slintest
  Source   : local (D:\DIPS\Repos\...\test-scripts)
  Ran at   : 2026-05-21T09:15:04Z
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Total: 4  |  ✅ 3 passed  |  ❌ 1 failed
[██████████████████░░░░░░] 75%

| Test                          | Status  | Duration | Output                              |
|-------------------------------|---------|----------|-------------------------------------|
| test-group3-db-cache          | ❌ FAIL | 4.3s     | Health endpoint returned HTTP 503   |
| test-group1-platform-health   | ✅ PASS | 12.1s    | All 18 checks passed                |
| test-group2-keycloak-core     | ✅ PASS | 8.7s     | Realm dips-admin accessible         |
| test-group4-oidc-discovery    | ✅ PASS | 3.2s     | JWKS endpoint valid, 2 signing keys |
```
