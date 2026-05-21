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
against any kubectl context. Works natively on Windows (Git Bash), macOS, and Linux —
no WSL required.

---

## Prerequisites

- `kubectl` installed and on PATH
- Valid kubeconfig (default: `~/.kube/config`)
- **Git Bash** on Windows (`git-scm.com/download/win`) — or any POSIX `bash` on PATH
- Test scripts at a local path **or** deployed as ConfigMaps in the `iam` namespace

> **Timeout guidance**: Simple ConfigMap scripts → 30 s each. Full local test suites
> (platform-health, keycloak-core, etc.) contain port-forward probes and can take
> 2–5 minutes — use a **300 s** timeout for local scripts.

---

## Step 0 — Detect bash executable

Do this **before** asking the user anything. On Windows, run this PowerShell block:

```powershell
function Find-BashExe {
    # 1. bash on PATH — check if it's Git Bash (preferred) or WSL
    $onPath = Get-Command bash -ErrorAction SilentlyContinue
    if ($onPath) {
        $src = $onPath.Source
        # WSL bash lives in System32 and produces an HCS logon error when
        # launched with RedirectStandardOutput = true.  Prefer Git Bash instead.
        $isWSL = $src -like "*System32*" -or $src -like "*wsl*"
        if (-not $isWSL) { return [PSCustomObject]@{ Path = $src; Type = "gitbash" } }
    }

    # 2. Common Git for Windows install locations
    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "$env:ProgramFiles\Git\usr\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LocalAppData\Programs\Git\bin\bash.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return [PSCustomObject]@{ Path = $p; Type = "gitbash" } }
    }

    # 3. WSL as last resort
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        return [PSCustomObject]@{ Path = "wsl"; Type = "wsl" }
    }
    return $null
}
$bashInfo = Find-BashExe
```

If `$bashInfo` is `$null`, stop and tell the user:
> No bash found. Install **Git for Windows** at https://git-scm.com/download/win
> (it ships with Git Bash). Alternatively enable WSL.
> Re-run the skill after installation.

On **Linux / macOS**, bash is always available at `/usr/bin/bash` or on PATH — skip this step.

---

## Step 1 — List contexts and ask the user

Always start here. Never assume the current context.

```powershell
kubectl config get-contexts
```

Present as a numbered list and ask:

> Which cluster would you like to run Keycloak tests against?

---

## Step 2 — Verify cluster connectivity

```powershell
kubectl get nodes --context <selected-ctx> --request-timeout=10s
```

Stop and report if this times out or returns an error. Do not run tests against
an unreachable cluster.

---

## Step 3 — Discover test scripts

### Mode A — Local directory

```powershell
$scripts = Get-ChildItem -Path $localPath -Filter "*.sh" | Sort-Object Name
if ($scripts.Count -eq 0) {
    Write-Error "No .sh files found in $localPath"; exit 1
}
```

Show a preview before running:

```
Found 4 test scripts in D:\...\test-scripts:
  • test-group1-platform-health.sh  — Platform & Deployment Health
  • test-group2-keycloak-core.sh    — Keycloak Core Health
  • test-group3-db-cache.sh         — Database & Cache
  • test-group4-oidc-discovery.sh   — OIDC Discovery & JWT
```

For the description, read the first comment block in each `.sh` file (the `# Group N — …` line).

### Mode B — ConfigMap discovery

```powershell
kubectl get cm -n iam -l app.kubernetes.io/component=test-scripts -o json --context <ctx>
```

Parse the response:
- `items` — if empty, stop and report no tests found
- For each item: `metadata.name` is the test name, `metadata.annotations.description`
  is the description (may be absent), each key in `data` is a separate script body

Show the same preview format as Mode A before running.

---

## Step 4 — Prepare an isolated kubeconfig

The test scripts look for kubeconfig via:
```bash
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/...kubeconfig}"
```
Setting `KUBECONFIG` externally overrides that default. Create a temporary
single-context kubeconfig so scripts always hit the correct cluster without
modifying the user's global kubeconfig:

```powershell
$tmpKubeconfig = [System.IO.Path]::GetTempFileName() + ".kubeconfig"

# Export only the selected context into a temp file
kubectl config view --minify --context $ctx --raw |
    Out-File -FilePath $tmpKubeconfig -Encoding utf8

# Ensure current-context is set to the selected context
kubectl config use-context $ctx --kubeconfig $tmpKubeconfig | Out-Null
```

Pass `$tmpKubeconfig` as the `KUBECONFIG` env var for every script.
Delete it after all tests complete:
```powershell
Remove-Item $tmpKubeconfig -ErrorAction SilentlyContinue
```

---

## Step 5 — Execute each script

Use **`Start-Process`-style execution** (not `Start-Job`) to avoid the HCS logon error
(`0x80070569`) that occurs when WSL bash is spawned from a restricted job context.

### Helper: Git Bash (preferred on Windows)

Git Bash is a native Windows executable — redirected I/O works without restriction.

```powershell
function Invoke-GitBash {
    param(
        [string]$BashExe,
        [string]$ScriptPath,
        [string]$KubeconfigPath,
        [string]$KubectlContext,
        [int]$TimeoutMs = 30000
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $BashExe
    $psi.Arguments              = "`"$($ScriptPath.Replace('\','/'))`""
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.WorkingDirectory       = Split-Path $ScriptPath -Parent

    # Override kubeconfig so scripts use the temp single-context file
    $psi.EnvironmentVariables["KUBECONFIG"]      = $KubeconfigPath
    $psi.EnvironmentVariables["KUBECTL_CONTEXT"] = $KubectlContext
    # Strip ANSI colour codes — they render as garbage in the report
    $psi.EnvironmentVariables["NO_COLOR"]        = "1"
    $psi.EnvironmentVariables["TERM"]            = "dumb"

    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $finished   = $proc.WaitForExit($TimeoutMs)
    $sw.Stop()

    if (-not $finished) { try { $proc.Kill() } catch {} }
    [void]$stdoutTask; [void]$stderrTask

    return [PSCustomObject]@{
        ExitCode = if ($finished) { $proc.ExitCode } else { 124 }
        Output   = ($stdoutTask.Result + "`n" + $stderrTask.Result).Trim()
        Duration = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        TimedOut = (-not $finished)
    }
}
```

### Helper: WSL bash (fallback — file-based I/O)

WSL cannot be launched with `UseShellExecute = false` + redirected I/O from a
restricted context (HCS/0x80070569). Route I/O through temp files instead:

```powershell
function Invoke-WslBash {
    param(
        [string]$ScriptPath,
        [string]$KubeconfigPath,
        [string]$KubectlContext,
        [int]$TimeoutMs = 30000
    )

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()

    # Convert Windows paths to WSL paths
    $wslScript = (wsl wslpath -u ($ScriptPath -replace '\\', '/')).Trim()
    $wslKcfg   = (wsl wslpath -u ($KubeconfigPath -replace '\\', '/')).Trim()
    $wslOut    = (wsl wslpath -u ($outFile -replace '\\', '/')).Trim()
    $wslErr    = (wsl wslpath -u ($errFile -replace '\\', '/')).Trim()

    $cmd = "wsl env KUBECONFIG=`"$wslKcfg`" NO_COLOR=1 TERM=dumb " +
           "bash `"$wslScript`" > `"$wslOut`" 2>`"$wslErr`""

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = "cmd.exe"
    $psi.Arguments       = "/c $cmd"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    $finished = $proc.WaitForExit($TimeoutMs)
    $sw.Stop()

    if (-not $finished) { try { $proc.Kill() } catch {} }

    $out = ((Get-Content $outFile -Raw -Encoding utf8 -ErrorAction SilentlyContinue) + "`n" +
            (Get-Content $errFile -Raw -Encoding utf8 -ErrorAction SilentlyContinue)).Trim()
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        ExitCode = if ($finished) { $proc.ExitCode } else { 124 }
        Output   = $out
        Duration = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        TimedOut = (-not $finished)
    }
}
```

### Main execution loop (Windows)

```powershell
$results = @()

foreach ($entry in $scriptEntries) {
    # $entry: [PSCustomObject]@{ Name = "..."; Path = "..." (local) or Content = "..." (ConfigMap) }

    # For ConfigMap mode: write content to a temp .sh file
    $tmpFile = $null
    if ($entry.PSObject.Properties['Content']) {
        $tmpFile = [System.IO.Path]::GetTempFileName() + ".sh"
        Set-Content -Path $tmpFile -Value $entry.Content -Encoding utf8
        $scriptPath = $tmpFile
    } else {
        $scriptPath = $entry.Path
    }

    Write-Host "  Running $($entry.Name)..."

    # Local scripts run full port-forward suites — allow up to 5 minutes.
    # ConfigMap scripts are typically lightweight — keep 30 s.
    $timeoutMs = if ($sourceMode -eq "local") { 300000 } else { 30000 }

    $r = if ($bashInfo.Type -eq "wsl") {
        Invoke-WslBash -ScriptPath $scriptPath -KubeconfigPath $tmpKubeconfig -KubectlContext $ctx -TimeoutMs $timeoutMs
    } else {
        Invoke-GitBash -BashExe $bashInfo.Path -ScriptPath $scriptPath -KubeconfigPath $tmpKubeconfig -KubectlContext $ctx -TimeoutMs $timeoutMs
    }

    if ($tmpFile) { Remove-Item $tmpFile -ErrorAction SilentlyContinue }

    $results += [PSCustomObject]@{
        Name     = $entry.Name
        Pass     = ($r.ExitCode -eq 0)
        ExitCode = $r.ExitCode
        Output   = $r.Output
        Duration = $r.Duration
        TimedOut = $r.TimedOut
    }
}

# Clean up temp kubeconfig
Remove-Item $tmpKubeconfig -ErrorAction SilentlyContinue
```

### Linux / macOS

```bash
kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
results=()

for script_path in "$local_path"/*.sh; do
    name=$(basename "$script_path" .sh)
    start_ms=$(date +%s%3N)
    output=$(export KUBECONFIG="$kubeconfig" NO_COLOR=1 TERM=dumb
             timeout 30 bash "$script_path" 2>&1)
    exit_code=$?
    end_ms=$(date +%s%3N)
    duration=$(echo "scale=1; ($end_ms - $start_ms) / 1000" | bc)
    [ $exit_code -eq 124 ] && output="TIMEOUT after 30s"
    results+=("$name|$exit_code|$duration|$output")
done
```

---

## Step 5b — Strip ANSI escape codes from output

Test scripts use hardcoded ANSI colour codes (e.g. `\033[0;32m`). Strip them before
rendering the report so results display cleanly in Claude's output:

```powershell
function Remove-AnsiCodes([string]$text) {
    # Matches ESC[ ... m sequences and bare ESC characters
    $text -replace '\x1B\[[0-9;]*[mKHF]', '' -replace '\x1B', ''
}

# Apply after collecting each result:
$r.Output = Remove-AnsiCodes $r.Output
```

---

## Step 6 — Render the visual report

After all scripts finish, produce the following report in your response.

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

Bar rules:
- 24 characters wide
- `█` for passing fraction, `░` for failing fraction
- Percentage = passed / total × 100 (rounded to nearest integer)
- All pass → `[████████████████████████] 100%`
- All fail → `[░░░░░░░░░░░░░░░░░░░░░░░░]   0%`

### Results table

Sort order: **failures first**, then passes.

| Test | Status | Duration | Output |
|---|---|---|---|
| login-flow-test | ❌ FAIL | 2.1s | `curl: (7) Failed to connect to 10.0.1.5` |
| realm-exists-check | ✅ PASS | 0.3s | Realm 'master' found |
| client-credentials | ✅ PASS | 1.4s | Token acquired (expires_in: 300) |
| token-introspect | ✅ PASS | 0.9s | active: true |

Column rules:
- **Test** — script filename without `.sh` (or ConfigMap name / key)
- **Status** — `✅ PASS` (exit 0), `❌ FAIL` (non-zero), `⏱ TIMEOUT` (exit 124)
- **Duration** — seconds with one decimal
- **Output** — last meaningful non-empty line of stdout/stderr; truncate at 80 chars
  with `…`; wrap in backticks if it looks like a command or error message

### Failed test details

For every failed or timed-out test, show the full output in a fenced block:

```
#### ❌ test-group2-keycloak-core
Exit code: 1
Duration : 4.3s

[FAIL] Health endpoint /health/ready returned HTTP 503
  Response: {"status":"DOWN","checks":[{"name":"Keycloak database connection","status":"DOWN"}]}
```

---

## Running a single named test

If the user asks to run only one test by name, in local mode:

```powershell
$scripts = Get-ChildItem -Path $localPath -Filter "$name*.sh"
```

In ConfigMap mode:

```powershell
kubectl get cm <test-name> -n iam -o json --context <ctx>
```

Run only that script, render a single-row report.

---

## Re-running failed tests only

If the user says "re-run failed tests" or "retry failures":
- Run only the scripts/ConfigMaps that failed in the previous run
- Use the same cluster context and source mode unless the user changes them

---

## Safety rules

- **Always ask for cluster confirmation** — never assume the current context.
- **Never modify** ConfigMaps or any cluster resource — read + execute only.
- **Always pass `--context` explicitly** to every `kubectl` command.
- **30-second hard timeout** per script — kill and mark `TIMEOUT` if exceeded.
- **Warn before running destructive flags**: if a script is about to be called with
  `--run-pg-restart`, `--run-redis-restart`, `--run-cred-rotation`, or similar
  opt-in destructive flags, ask the user to confirm first.
- Do not run scripts containing `rm -rf`, `kubectl delete namespace`, or
  `kubectl delete` without explicit user confirmation.

---

## Works well with

- `k8s-debug:k8s-debug` — investigate cluster issues uncovered by failed tests
