---
name: keycloak-test
description: >
  Use when the user wants to run Keycloak tests, execute test scripts against a cluster,
  validate Keycloak configuration, test Keycloak connectivity, run Keycloak health checks,
  or check IAM test results. Trigger on: "run keycloak tests", "test keycloak",
  "keycloak test results", "run tests against cluster", "keycloak health check",
  "check keycloak", "test iam", "keycloak scripts", "run iam tests", "validate keycloak".
---

# Keycloak Test Runner

Discovers test scripts stored as ConfigMaps in the `iam` namespace and runs them
against the selected cluster. Always asks the user to confirm the target cluster
before executing anything.

---

## Prerequisites

- `kubectl` installed and on PATH
- Valid kubeconfig with access to the target cluster
- `bash` available (Git Bash or WSL on Windows)
- Test scripts deployed as ConfigMaps labeled `app.kubernetes.io/component=test-scripts`

---

## Step 1 — List contexts and ask the user

Always start here. Never assume the current context.

```bash
kubectl config get-contexts
```

Present the available contexts as a numbered list and ask:

> Which cluster would you like to run Keycloak tests against?

Wait for the user's answer before proceeding.

---

## Step 2 — Verify cluster connectivity

```bash
kubectl get nodes --context <selected-ctx> --request-timeout=10s
```

If this times out or returns an error, stop and report the connectivity issue.
Do not proceed to run tests against an unreachable cluster.

---

## Step 3 — Discover test script ConfigMaps

```bash
kubectl get cm -n iam -l app.kubernetes.io/component=test-scripts -o json --context <selected-ctx>
```

Parse the JSON response:
- `items` — array of ConfigMaps; if empty, stop and report no tests found
- For each item:
  - `metadata.name` — the test name
  - `metadata.annotations.description` — human-readable description (may be absent)
  - `data` — map of `filename → script content`; each key is a separate script to run

Show the user a preview of what was found before running:

```
Found 4 test scripts in iam/[context]:
  • login-flow-test        — Verify Keycloak login returns a valid token
  • realm-exists-check     — Confirm master realm is present
  • client-credentials     — Test client credential grant flow
  • token-introspect       — Validate token introspection endpoint
```

---

## Step 4 — Execute each script

For each ConfigMap and each key in its `data` field, execute the script and record results.

### On Windows (PowerShell + bash)

```powershell
$json  = kubectl get cm -n iam -l app.kubernetes.io/component=test-scripts -o json --context <ctx>
$cms   = $json | ConvertFrom-Json
$results = @()

foreach ($cm in $cms.items) {
    $testName = $cm.metadata.name

    foreach ($prop in $cm.data.PSObject.Properties) {
        $tmpFile = [System.IO.Path]::GetTempFileName() + ".sh"
        Set-Content -Path $tmpFile -Value $prop.Value -Encoding utf8

        $sw     = [System.Diagnostics.Stopwatch]::StartNew()
        $output = bash $tmpFile 2>&1
        $sw.Stop()
        $exitCode = $LASTEXITCODE

        Remove-Item $tmpFile -ErrorAction SilentlyContinue

        $results += [PSCustomObject]@{
            Name     = if ($cms.items.Count -eq 1 -or $prop.Name -ne "script.sh") { "$testName/$($prop.Name)" } else { $testName }
            Pass     = ($exitCode -eq 0)
            Output   = ($output -join "`n").Trim()
            Duration = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
    }
}
```

### On Linux / macOS (bash)

```bash
results=()
while IFS= read -r cm_name; do
  while IFS= read -r key; do
    content=$(kubectl get cm "$cm_name" -n iam -o jsonpath="{.data.$key}" --context <ctx>)
    tmp=$(mktemp /tmp/kc_test_XXXX.sh)
    echo "$content" > "$tmp"
    chmod +x "$tmp"

    start_ms=$(date +%s%3N)
    output=$(bash "$tmp" 2>&1)
    exit_code=$?
    end_ms=$(date +%s%3N)
    duration_s=$(echo "scale=1; ($end_ms - $start_ms) / 1000" | bc)

    rm -f "$tmp"
    results+=("$cm_name|$key|$exit_code|$duration_s|$output")
  done < <(kubectl get cm "$cm_name" -n iam -o json --context <ctx> | jq -r '.data | keys[]')
done < <(kubectl get cm -n iam -l app.kubernetes.io/component=test-scripts -o jsonpath='{.items[*].metadata.name}' --context <ctx> | tr ' ' '\n')
```

### Timeout rule

Enforce a **30-second timeout** per script. If a script exceeds 30 s, kill it, record
exit code `124`, and mark it as `TIMEOUT`.

---

## Step 5 — Render the visual report

After all scripts finish, produce the following report in your response.

### Header

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Keycloak Test Report
  Cluster  : <context-name>
  Namespace: iam
  Ran at   : <ISO timestamp>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Summary bar

Use a single line with counts and a visual progress bar built from blocks:

```
Total: 5  |  ✅ 4 passed  |  ❌ 1 failed
[████████████████████░░░░] 80%
```

Bar rules:
- 24 characters wide
- `█` for passing fraction, `░` for failing fraction
- Percentage = passed / total × 100 (rounded to nearest integer)
- If all pass: show full green bar `[████████████████████████] 100%`
- If all fail: show full empty bar `[░░░░░░░░░░░░░░░░░░░░░░░░]  0%`

### Results table

Sort order: **failures first**, then passes.

| Test | Status | Duration | Output |
|---|---|---|---|
| login-flow-test | ❌ FAIL | 2.1s | `curl: (7) Failed to connect to 10.0.1.5` |
| realm-exists-check | ✅ PASS | 0.3s | Realm 'master' found |
| client-credentials | ✅ PASS | 1.4s | Token acquired (expires_in: 300) |
| token-introspect | ✅ PASS | 0.9s | active: true |

Column rules:
- **Test** — ConfigMap name (and key if the ConfigMap holds multiple scripts)
- **Status** — `✅ PASS` (exit code 0) or `❌ FAIL` (non-zero) or `⏱ TIMEOUT`
- **Duration** — seconds with one decimal, e.g. `1.4s`
- **Output** — first line of stdout/stderr; truncate at 80 chars with `…`; wrap in backticks if it looks like a command or error

### Failed test details

For every failed test, show the full output in a fenced block:

```
#### ❌ login-flow-test
Exit code: 1
Duration : 2.1s

curl: (7) Failed to connect to 10.0.1.5 port 443: Connection refused
```

---

## Running a single named test

If the user asks to run only one test by name:

```bash
kubectl get cm <test-name> -n iam -o json --context <ctx>
```

Extract and run only that ConfigMap's scripts, then render a single-row report.

---

## Re-running failed tests only

If the user says "re-run failed tests" or "retry failures", run only the ConfigMaps
that failed in the previous run. Use the same cluster context unless the user changes it.

---

## Safety rules

- **Always ask for cluster confirmation** before running anything — never assume the current context.
- **Never modify** ConfigMaps or any cluster resource — read + execute only.
- **Always pass `--context` explicitly** to every kubectl command.
- **30-second hard timeout** per script — kill and mark `TIMEOUT` if exceeded.
- Scripts run under the user's local kubeconfig RBAC — warn if a script attempts
  mutating operations (`kubectl apply`, `kubectl delete`, etc.) and ask the user to confirm.
- Do not run scripts that contain `rm -rf`, `kubectl delete namespace`, or other
  destructive commands without explicit user confirmation.

---

## Works well with

- `k8s-debug:k8s-debug` — investigate cluster issues uncovered by failed tests
