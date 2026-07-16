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
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
$StatePath = Join-Path $StateRoot 'state.json'
$StdoutPath = Join-Path $StateRoot 'injector.log'
$StderrPath = Join-Path $StateRoot 'injector-error.log'
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

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

function Stop-CodexCompletely {
  $visible = @(Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
  foreach ($process in $visible) { [void]$process.CloseMainWindow() }
  Start-Sleep -Seconds 2
  $deadline = (Get-Date).AddSeconds(12)
  while ((Get-Date) -lt $deadline) {
    $procs = @(Get-Process ChatGPT -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { break }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
  }
  # Windows can auto-respawn a force-killed app moments later; give it a beat and swat once more,
  # otherwise the unflagged respawn wins the single-instance lock and the debug flag is silently lost.
  Start-Sleep -Milliseconds 900
  Get-Process ChatGPT -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 300
}

$node = (Get-Command node -ErrorAction Stop).Source
$debugReady = Test-CodexDebugPort $Port
$mainProcesses = @(Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })

if (-not $debugReady -and -not $ProfilePath -and $mainProcesses.Count -gt 0) {
  if (-not $RestartExisting) {
    throw "Codex is already running without dream-skin debugging on port $Port. Close Codex or rerun with -RestartExisting."
  }
  Stop-CodexCompletely
}

function Start-CodexWithDebugPort {
  $package = Get-AppxPackage OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
  if (-not $package) { throw 'The OpenAI.Codex Store package is not installed.' }
  $exe = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
  if (-not (Test-Path -LiteralPath $exe)) { throw "Codex executable not found: $exe" }
  $arguments = @("--remote-debugging-port=$Port")
  if ($ProfilePath) {
    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    $arguments += "--user-data-dir=$ProfilePath"
  }
  Start-Process -FilePath $exe -ArgumentList $arguments
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
  Stop-CodexCompletely
}

if (Test-Path -LiteralPath $StatePath) {
  $recordedInjectorPid = $null
  try {
    $old = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($old.injectorPid) { $recordedInjectorPid = [int]$old.injectorPid }
  } catch {
    Write-Warning "Could not read the previous injector state: $($_.Exception.Message)"
  }
  if ($recordedInjectorPid) {
    [void](Stop-RecordedProcess -ProcessId $recordedInjectorPid -ExpectedScriptPath $Injector -Description 'injector')
  }
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
    port = $Port
    injectorPid = $daemon.Id
    startedAt = (Get-Date).ToString('o')
    skillRoot = $SkillRoot
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
  if ($daemon) {
    $stopped = Stop-RecordedProcess -ProcessId ([int]$daemon.Id) -ExpectedScriptPath $Injector -Description 'injector'
    if (-not $stopped) {
      try { if (-not $daemon.HasExited) { $daemon.Kill() } } catch {}
    }
  }
  Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
  throw
}
Write-Host "Codex Dream Skin is active on port $Port."
