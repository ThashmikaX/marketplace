# keycloak-test

Discovers Keycloak test scripts stored as Kubernetes ConfigMaps and runs them
against a selected cluster, displaying a visual pass/fail report.

---

## How it works

1. Lists your available kubectl contexts and asks which cluster to target
2. Fetches all ConfigMaps labeled `app.kubernetes.io/component=test-scripts` from the `iam` namespace
3. Extracts and executes each script (bash) with a 30-second timeout
4. Renders a visual results table with a summary progress bar

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| `kubectl` | Fetch ConfigMaps and cluster info |
| `bash` | Execute test scripts (Git Bash or WSL on Windows) |
| kubeconfig | Must have `get`/`list` on `configmaps` in the `iam` namespace |

---

## Test script format

Test scripts must be stored as ConfigMaps in the `iam` namespace with the label
`app.kubernetes.io/component=test-scripts`. Each key in the ConfigMap `data` field
is treated as a separate script.

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
    KC_URL=$(kubectl get svc keycloak -n iam -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    TOKEN=$(curl -sf -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
      -d "client_id=admin-cli&username=admin&password=admin&grant_type=password" \
      | jq -r '.access_token')
    [ "$TOKEN" != "null" ] && echo "Token acquired" || { echo "Login failed"; exit 1; }
```

**Pass/fail convention:** exit code `0` = PASS, any non-zero = FAIL.

---

## Example output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Keycloak Test Report
  Cluster  : aks-prod-iam
  Namespace: iam
  Ran at   : 2026-05-21T09:15:04Z
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Total: 4  |  ✅ 3 passed  |  ❌ 1 failed
[██████████████████░░░░░░] 75%

| Test                  | Status   | Duration | Output                              |
|-----------------------|----------|----------|-------------------------------------|
| token-introspect      | ❌ FAIL  | 2.1s     | curl: (7) Failed to connect         |
| login-flow-test       | ✅ PASS  | 1.4s     | Token acquired                      |
| realm-exists-check    | ✅ PASS  | 0.3s     | Realm 'master' found                |
| client-credentials    | ✅ PASS  | 0.9s     | Token acquired (expires_in: 300)    |
```
