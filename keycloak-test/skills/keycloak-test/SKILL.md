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

Runs Keycloak test scripts from a **local directory** or from **cluster ConfigMaps**,
against any kubectl context. Works natively on Windows (Git Bash), macOS, and Linux.

Helper scripts live alongside this file:
- `scripts/windows/helpers.ps1` — PowerShell helper functions
- `scripts/windows/run-tests.ps1` — Windows execution loop
- `scripts/linux/run-tests.sh` — Linux / macOS execution

> **Timeout guidance**: ConfigMap scripts → 30 s each. Local test suites with
> port-forward probes can take 2–5 minutes — use **300 s** for local scripts.

---

## Step 0 — Detect OS

Before doing anything else, detect the OS:

```powershell
$os = if ($env:OS -eq "Windows_NT") { "windows" } else { "linux" }
```

On Linux/macOS run the equivalent in bash: `os=linux`.

---

## Step 1 — Find bash (Windows only)

Skip this step on Linux/macOS — bash is always available.

On Windows: Read `scripts/windows/helpers.ps1` and execute it to define the helper
functions, then run:

```powershell
$bashInfo = Find-BashExe
```

If `$bashInfo` is `$null`, stop and tell the user:
> No bash found. Install **Git for Windows** at https://git-scm.com/download/win
> (it ships with Git Bash). Alternatively enable WSL. Re-run after installation.

---

## Step 2 — List contexts and ask the user

Always start here. Never assume the current context.

```powershell
kubectl config get-contexts
```

Present as a numbered list and ask:

> Which cluster would you like to run Keycloak tests against?

---

## Step 3 — Verify cluster connectivity

```powershell
kubectl get nodes --context <selected-ctx> --request-timeout=10s
```

Stop and report if this times out or returns an error.

---

## Step 4 — Discover test scripts

### Mode A — Local directory

**Windows:**
```powershell
$scripts = Get-ChildItem -Path $localPath -Filter "*.sh" | Sort-Object Name
if ($scripts.Count -eq 0) { Write-Error "No .sh files found in $localPath"; exit 1 }
```

**Linux/macOS:**
```bash
scripts=($(ls "$local_path"/*.sh 2>/dev/null | sort))
[ ${#scripts[@]} -eq 0 ] && { echo "No .sh files found in $local_path"; exit 1; }
```

Show a preview before running:

```
Found 4 test scripts in <path>:
  • test-group1-platform-health.sh  — Platform & Deployment Health
  • test-group2-keycloak-core.sh    — Keycloak Core Health
  • test-group3-db-cache.sh         — Database & Cache
  • test-group4-oidc-discovery.sh   — OIDC Discovery & JWT
```

Read the first `# Group N — …` comment line from each `.sh` file for the description.

### Mode B — ConfigMap discovery

```powershell
kubectl get cm -n iam -l app.kubernetes.io/component=test-scripts -o json --context <ctx>
```

Parse `items`: if empty, stop and report no tests found. For each item,
`metadata.name` is the test name and each key in `data` is a script body.

Show the same preview format before running.

---

## Step 5 — Prepare an isolated kubeconfig

**Windows:**
```powershell
$tmpKubeconfig = [System.IO.Path]::GetTempFileName() + ".kubeconfig"
kubectl config view --minify --context $ctx --raw | Out-File -FilePath $tmpKubeconfig -Encoding utf8
kubectl config use-context $ctx --kubeconfig $tmpKubeconfig | Out-Null
```

**Linux/macOS:**
```bash
tmp_kubeconfig=$(mktemp /tmp/kubeconfig-XXXXXX.yaml)
kubectl config view --minify --context "$ctx" --raw > "$tmp_kubeconfig"
kubectl config use-context "$ctx" --kubeconfig "$tmp_kubeconfig" > /dev/null
```

---

## Step 6 — Execute scripts

### Windows

Ensure `helpers.ps1` functions are loaded (Step 1), then read
`scripts/windows/run-tests.ps1` and execute it with `$scriptEntries`, `$bashInfo`,
`$tmpKubeconfig`, `$ctx`, and `$sourceMode` set.

Build `$scriptEntries` from the discovered scripts:
```powershell
# Local mode
$scriptEntries = $scripts | ForEach-Object {
    [PSCustomObject]@{ Name = $_.BaseName; Path = $_.FullName }
}

# ConfigMap mode — write each data key to a temp .sh file
$scriptEntries = $cmData.Keys | Sort-Object | ForEach-Object {
    $tmpFile = [System.IO.Path]::GetTempFileName() + ".sh"
    Set-Content -Path $tmpFile -Value $cmData[$_] -Encoding utf8
    [PSCustomObject]@{ Name = $_; Path = $tmpFile }
}
```

### Linux/macOS

Read `scripts/linux/run-tests.sh`, save it to a temp file, make it executable,
then run:

```bash
# Local mode
chmod +x /tmp/run-tests.sh
KUBECONFIG="$tmp_kubeconfig" \
KUBECTL_CONTEXT="$ctx" \
TIMEOUT_SEC=$([ "$source_mode" = "local" ] && echo 300 || echo 30) \
bash /tmp/run-tests.sh "${scripts[@]}"

# ConfigMap mode — kubectl outputs JSON; extract each script body to a temp file first,
# then pass the temp files as arguments to run-tests.sh
```

Collect the pipe-delimited output lines — each is `name|exit_code|duration|last_line`.

---

## Step 7 — Render the visual report

After all scripts finish, produce this report.

### Header

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Keycloak Test Report
  Cluster  : <context-name>
  Source   : local (<path>) | ConfigMaps (iam namespace)
  Ran at   : <ISO-8601 timestamp>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Summary bar

```
Total: 5  |  ✅ 4 passed  |  ❌ 1 failed
[████████████████████░░░░] 80%
```

Bar rules: 24 chars wide, `█` = passing fraction, `░` = failing fraction,
percentage = passed / total × 100 (rounded).

### Results table

Sort: **failures first**, then passes.

| Test | Status | Duration | Output |
|---|---|---|---|
| login-flow-test | ❌ FAIL | 2.1s | `curl: (7) Failed to connect to 10.0.1.5` |
| realm-exists-check | ✅ PASS | 0.3s | Realm 'master' found |

Column rules:
- **Status** — `✅ PASS` (exit 0), `❌ FAIL` (non-zero), `⏱ TIMEOUT` (exit 124)
- **Output** — last meaningful non-empty line; truncate at 80 chars with `…`

### Failed test details

For every failed or timed-out test, show full output in a fenced block:

```
#### ❌ test-group2-keycloak-core
Exit code: 1
Duration : 4.3s

[FAIL] Health endpoint /health/ready returned HTTP 503
  Response: {"status":"DOWN","checks":[...]}
```

---

## Running a single named test

**Local:**
```powershell
# Windows
$scripts = Get-ChildItem -Path $localPath -Filter "$name*.sh"
```
```bash
# Linux/macOS
scripts=("$local_path/$name"*.sh)
```

**ConfigMap:**
```powershell
kubectl get cm <test-name> -n iam -o json --context <ctx>
```

Run only that script, render a single-row report.

---

## Re-running failed tests only

If the user says "re-run failed tests" or "retry failures":
- Run only the scripts that failed in the previous run.
- Use the same cluster context and source mode unless changed.

---

## Safety rules

- **Always ask for cluster confirmation** — never assume the current context.
- **Never modify** ConfigMaps or any cluster resource — read + execute only.
- **Always pass `--context` explicitly** to every `kubectl` command.
- **Hard timeout** per script (30 s ConfigMap, 300 s local) — kill and mark `TIMEOUT`.
- **Warn before destructive flags**: if a script is called with `--run-pg-restart`,
  `--run-redis-restart`, `--run-cred-rotation`, or similar, ask the user to confirm.
- Do not run scripts containing `rm -rf`, `kubectl delete namespace`, or
  `kubectl delete` without explicit user confirmation.

---

## Works well with

- `k8s-debug:k8s-debug` — investigate cluster issues uncovered by failed tests
