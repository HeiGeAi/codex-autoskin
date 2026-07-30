[CmdletBinding()]
param(
  [int]$Port = 9335,
  [switch]$RestartExisting,
  [string]$ProfilePath,
  [switch]$ForegroundInjector
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'file-io.ps1')
. (Join-Path $PSScriptRoot 'process-ownership.ps1')
$SkillRoot = Split-Path -Parent $PSScriptRoot
$Injector = Join-Path $PSScriptRoot 'injector.mjs'
$node = (Get-Command node -ErrorAction Stop).Source
$runtimeCheck = Join-Path $PSScriptRoot 'runtime-compat.mjs'
& $node $runtimeCheck --quiet
if ($LASTEXITCODE -ne 0) { throw 'Node runtime compatibility check failed; Codex was not restarted.' }
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
$StatePath = Join-Path $StateRoot 'state.json'
$StdoutPath = Join-Path $StateRoot 'injector.log'
$StderrPath = Join-Path $StateRoot 'injector-error.log'
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

if (Test-Path -LiteralPath $StatePath) {
  try {
    $old = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if (-not $old.injectorPid) { throw 'Previous injector state has no injectorPid.' }
    $recordedInjectorPath = Resolve-RecordedScriptPath -State $old -ExpectedLeafName 'injector.mjs' -RelativePathFromSkillRoot 'scripts\injector.mjs' -FallbackPath $Injector
    $recordedNodePath = Resolve-RecordedExecutablePath -State $old -FallbackPath $node
  } catch {
    throw "Could not validate the previous injector state; state was preserved: $($_.Exception.Message)"
  }
  $recordedStartTime = if ($old.processStartTimeUtc) { [string]$old.processStartTimeUtc } else { $null }
  $stopResult = Stop-RecordedProcess -ProcessId ([int]$old.injectorPid) -ExpectedScriptPath $recordedInjectorPath -ExpectedExecutablePath $recordedNodePath -ScriptArgumentMode 'NodeEntryPoint' -ExpectedProcessStartTimeUtc $recordedStartTime -Description 'injector'
  if (-not $stopResult.Success) {
    throw "Could not safely replace the previous injector; state was preserved. $($stopResult.Message)"
  }
  if (-not $stopResult.CanDiscardState) {
    throw 'Previous injector reconciliation did not confirm that its state can be discarded.'
  }
  Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop
}

function Test-CodexDebugPort([int]$CandidatePort) {
  # Chromium may bind DevTools to either loopback stack depending on boot state;
  # accept whichever answers.
  foreach ($loopback in @('127.0.0.1', '[::1]')) {
    try {
      $targets = Invoke-RestMethod "http://$($loopback):$($CandidatePort)/json/list" -TimeoutSec 1
      if ($targets | Where-Object { $_.type -eq 'page' -and $_.url -like 'app://*' }) { return $true }
    } catch {}
  }
  return $false
}

function Stop-CodexCompletely([string]$ExpectedExecutablePath) {
  $visible = @(Get-CodexProcesses -ExpectedExecutablePath $ExpectedExecutablePath | Where-Object { $_.MainWindowHandle -ne 0 })
  foreach ($process in $visible) { [void]$process.CloseMainWindow() }
  Start-Sleep -Seconds 2
  $deadline = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $deadline) {
    $procs = @(Get-CodexProcesses -ExpectedExecutablePath $ExpectedExecutablePath)
    if ($procs.Count -eq 0) { break }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
  }
  # Windows can auto-respawn a force-killed app moments later; give it a beat and swat once more,
  # otherwise the unflagged respawn wins the single-instance lock and the debug flag is silently lost.
  Start-Sleep -Milliseconds 900
  Get-CodexProcesses -ExpectedExecutablePath $ExpectedExecutablePath | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 300
}

$CodexExecutablePath = Resolve-CodexStoreExecutablePath
$debugReady = Test-CodexDebugPort $Port
$mainProcesses = @(Get-CodexProcesses -ExpectedExecutablePath $CodexExecutablePath | Where-Object { $_.MainWindowHandle -ne 0 })

if (-not $debugReady -and -not $ProfilePath -and $mainProcesses.Count -gt 0) {
  if (-not $RestartExisting) {
    throw "Codex is already running without dream-skin debugging on port $Port. Close Codex or rerun with -RestartExisting."
  }
  Stop-CodexCompletely -ExpectedExecutablePath $CodexExecutablePath
}

function Start-CodexWithDebugPort {
  $arguments = @("--remote-debugging-port=$Port")
  if ($ProfilePath) {
    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    $arguments += "--user-data-dir=$ProfilePath"
  }
  Start-Process -FilePath $CodexExecutablePath -ArgumentList $arguments
}

function Wait-CodexDebugPort([int]$Seconds) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while (-not (Test-CodexDebugPort $Port)) {
    if ((Get-Date) -ge $deadline) { return $false }
    Start-Sleep -Milliseconds 400
  }
  return $true
}

$maxLaunchAttempts = if ($ProfilePath) { 1 } else { 2 }
$attempt = 0
while (-not (Test-CodexDebugPort $Port)) {
  if ($attempt -ge $maxLaunchAttempts) {
    throw "Codex did not expose CDP on 127.0.0.1/[::1]:$Port after $attempt launch attempt(s)."
  }
  $attempt++
  Start-CodexWithDebugPort
  if (Wait-CodexDebugPort 30) { break }
  if ($ProfilePath) { throw "Codex did not expose CDP on 127.0.0.1/[::1]:$Port within 30 seconds." }
  # Likely lost the single-instance race to an unflagged auto-respawn; clear everything and retry once.
  Stop-CodexCompletely -ExpectedExecutablePath $CodexExecutablePath
}

if ($ForegroundInjector) {
  & $node $Injector --watch --port $Port
  exit $LASTEXITCODE
}

$injectorArgs = @("`"$Injector`"", '--watch', '--port', "$Port")
$daemon = $null
try {
  $daemon = Start-Process -FilePath $node -ArgumentList $injectorArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
  $stateJson = @{
    schemaVersion = 2
    component = 'injector'
    port = $Port
    injectorPid = $daemon.Id
    processStartTimeUtc = $daemon.StartTime.ToUniversalTime().ToString('o')
    startedAt = (Get-Date).ToString('o')
    skillRoot = $SkillRoot
    scriptPath = $Injector
    executablePath = $node
    profilePath = $ProfilePath
  } | ConvertTo-Json
  Write-AtomicUtf8File -LiteralPath $StatePath -Content $stateJson

  $verified = $false
  for ($attempt = 0; $attempt -lt 45; $attempt++) {
    Start-Sleep -Milliseconds 700
    & $node $Injector --verify --port $Port *> $null
    if ($LASTEXITCODE -eq 0) { $verified = $true; break }
  }
  if (-not $verified) { throw 'Dream skin launched but verification failed. See injector logs.' }
} catch {
  $launchError = $_.Exception
  $stateCanBeRemoved = $null -eq $daemon
  if ($daemon) {
    $daemonStartTime = $null
    try { $daemonStartTime = $daemon.StartTime.ToUniversalTime().ToString('o') } catch {}
    $stopResult = Stop-RecordedProcess -ProcessId ([int]$daemon.Id) -ExpectedScriptPath $Injector -ExpectedExecutablePath $node -ScriptArgumentMode 'NodeEntryPoint' -ExpectedProcessStartTimeUtc $daemonStartTime -Description 'injector'
    $stateCanBeRemoved = $stopResult.CanDiscardState
    if (-not $stopResult.Success) {
      try {
        if (-not $daemon.HasExited) {
          $daemon.Kill()
          $stateCanBeRemoved = $daemon.WaitForExit(5000)
        } else {
          $stateCanBeRemoved = $true
        }
      } catch {
        $stateCanBeRemoved = $false
      }
    }
  }
  if ($stateCanBeRemoved) {
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    throw $launchError
  }
  throw "$($launchError.Message) Injector cleanup could not confirm process exit; state was preserved."
}
Write-Host "Codex Dream Skin is active on port $Port."
