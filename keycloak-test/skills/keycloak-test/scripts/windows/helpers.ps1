function Find-BashExe {
    $onPath = Get-Command bash -ErrorAction SilentlyContinue
    if ($onPath) {
        $src = $onPath.Source
        $isWSL = $src -like "*System32*" -or $src -like "*wsl*"
        if (-not $isWSL) { return [PSCustomObject]@{ Path = $src; Type = "gitbash" } }
    }
    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "$env:ProgramFiles\Git\usr\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LocalAppData\Programs\Git\bin\bash.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return [PSCustomObject]@{ Path = $p; Type = "gitbash" } }
    }
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        return [PSCustomObject]@{ Path = "wsl"; Type = "wsl" }
    }
    return $null
}

function Remove-AnsiCodes([string]$text) {
    $text -replace '\x1B\[[0-9;]*[mKHF]', '' -replace '\x1B', ''
}

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
    $psi.EnvironmentVariables["KUBECONFIG"]      = $KubeconfigPath
    $psi.EnvironmentVariables["KUBECTL_CONTEXT"] = $KubectlContext
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

function Invoke-WslBash {
    param(
        [string]$ScriptPath,
        [string]$KubeconfigPath,
        [string]$KubectlContext,
        [int]$TimeoutMs = 30000
    )
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $wslScript = (wsl wslpath -u ($ScriptPath    -replace '\\', '/')).Trim()
    $wslKcfg   = (wsl wslpath -u ($KubeconfigPath -replace '\\', '/')).Trim()
    $wslOut    = (wsl wslpath -u ($outFile        -replace '\\', '/')).Trim()
    $wslErr    = (wsl wslpath -u ($errFile        -replace '\\', '/')).Trim()
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
