# Expects these variables already set by the caller (SKILL.md steps):
#   $scriptEntries  — array of [PSCustomObject]@{ Name; Path } (local) or @{ Name; Content } (ConfigMap)
#   $bashInfo       — result of Find-BashExe (from helpers.ps1)
#   $tmpKubeconfig  — path to the temp single-context kubeconfig
#   $ctx            — selected kubectl context name
#   $sourceMode     — "local" | "configmap"
#
# Helper functions (Find-BashExe, Invoke-GitBash, Invoke-WslBash, Remove-AnsiCodes)
# must be dot-sourced before running this script.

$results = @()

foreach ($entry in $scriptEntries) {
    $tmpFile = $null
    if ($entry.PSObject.Properties['Content']) {
        $tmpFile = [System.IO.Path]::GetTempFileName() + ".sh"
        Set-Content -Path $tmpFile -Value $entry.Content -Encoding utf8
        $scriptPath = $tmpFile
    } else {
        $scriptPath = $entry.Path
    }

    Write-Host "  Running $($entry.Name)..."

    $timeoutMs = if ($sourceMode -eq "local") { 300000 } else { 30000 }

    $r = if ($bashInfo.Type -eq "wsl") {
        Invoke-WslBash `
            -ScriptPath      $scriptPath `
            -KubeconfigPath  $tmpKubeconfig `
            -KubectlContext  $ctx `
            -TimeoutMs       $timeoutMs
    } else {
        Invoke-GitBash `
            -BashExe         $bashInfo.Path `
            -ScriptPath      $scriptPath `
            -KubeconfigPath  $tmpKubeconfig `
            -KubectlContext  $ctx `
            -TimeoutMs       $timeoutMs
    }

    if ($tmpFile) { Remove-Item $tmpFile -ErrorAction SilentlyContinue }

    $results += [PSCustomObject]@{
        Name     = $entry.Name
        Pass     = ($r.ExitCode -eq 0)
        ExitCode = $r.ExitCode
        Output   = Remove-AnsiCodes $r.Output
        Duration = $r.Duration
        TimedOut = $r.TimedOut
    }
}

Remove-Item $tmpKubeconfig -ErrorAction SilentlyContinue
