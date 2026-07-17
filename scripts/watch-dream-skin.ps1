[CmdletBinding()]
param(
  [int]$Port = 9335,
  [int]$PollSeconds = 2,
  [int]$LaunchGraceSeconds = 15,
  [int]$MaxConsecutiveFailures = 3,
  [int]$CooldownMinutes = 30,
  [int]$ProbeFailuresBeforeRecovery = 3,
  [int]$MaxRestartsPerWindow = 2,
  [int]$RestartWindowMinutes = 10
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'file-io.ps1')
. (Join-Path $PSScriptRoot 'process-ownership.ps1')
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
$StatePath = Join-Path $StateRoot 'state.json'
$WatcherStatePath = Join-Path $StateRoot 'watcher-state.json'
$LogPath = Join-Path $StateRoot 'watcher.log'
$StartScript = Join-Path $PSScriptRoot 'start-dream-skin.ps1'
$Injector = Join-Path $PSScriptRoot 'injector.mjs'
$Node = (Get-Command node -ErrorAction SilentlyContinue).Source
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\CodexDreamSkinWatcher-$Port", [ref]$createdNew)
if (-not $createdNew) { exit 0 }

function Write-WatcherLog([string]$Message) {
  try {
    Add-Content -LiteralPath $LogPath -Encoding utf8 -Value "[$(Get-Date -Format o)] $Message"
  } catch {}
}

function Test-DreamDebugPort {
  # Chromium may bind DevTools to either loopback stack depending on boot state;
  # accept whichever answers.
  foreach ($loopback in @('127.0.0.1', '[::1]')) {
    try {
      $targets = Invoke-RestMethod "http://$($loopback):$($Port)/json/list" -TimeoutSec 3
      if ($targets | Where-Object { $_.type -eq 'page' -and $_.url -like 'app://*' }) { return $true }
    } catch {}
  }
  return $false
}

function New-InjectorHealthResult([string]$Status, [string]$Message) {
  return [pscustomobject]@{ Status = $Status; Message = $Message }
}

function Get-InjectorHealth {
  if (-not (Test-Path -LiteralPath $StatePath)) {
    return New-InjectorHealthResult -Status 'missing' -Message 'Injector state is absent.'
  }
  try {
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if (-not $state.injectorPid) { throw 'Injector state has no injectorPid.' }
    if (-not $Node -and -not $state.executablePath) { throw 'Node executable is unavailable and injector state has no executablePath.' }
    $expectedInjectorPath = Resolve-RecordedScriptPath -State $state -ExpectedLeafName 'injector.mjs' -RelativePathFromSkillRoot 'scripts\injector.mjs' -FallbackPath $Injector
    $nodeFallback = if ($Node) { $Node } else { [string]$state.executablePath }
    $expectedNodePath = Resolve-RecordedExecutablePath -State $state -FallbackPath $nodeFallback
    $recordedStartTime = if ($state.processStartTimeUtc) { [string]$state.processStartTimeUtc } else { $null }
  } catch {
    return New-InjectorHealthResult -Status 'ownership-failed' -Message "Injector state cannot be trusted: $($_.Exception.Message)"
  }

  $ownership = Get-RecordedProcessOwnership -ProcessId ([int]$state.injectorPid) -ExpectedScriptPath $expectedInjectorPath -ExpectedExecutablePath $expectedNodePath -ScriptArgumentMode 'NodeEntryPoint' -ExpectedProcessStartTimeUtc $recordedStartTime
  if ($ownership.Status -eq 'owned') {
    return New-InjectorHealthResult -Status 'healthy' -Message $ownership.Message
  }
  if ($ownership.Status -eq 'not-running') {
    return New-InjectorHealthResult -Status 'missing' -Message $ownership.Message
  }
  return New-InjectorHealthResult -Status $ownership.Status -Message $ownership.Message
}

$watcherProcess = Get-Process -Id $PID -ErrorAction Stop
$watcherStateJson = @{
  schemaVersion = 2
  component = 'watcher'
  watcherPid = $PID
  port = $Port
  processStartTimeUtc = $watcherProcess.StartTime.ToUniversalTime().ToString('o')
  startedAt = (Get-Date).ToString('o')
  scriptPath = $PSCommandPath
  executablePath = $watcherProcess.Path
  skillRoot = (Split-Path -Parent $PSScriptRoot)
} | ConvertTo-Json
Write-AtomicUtf8File -LiteralPath $WatcherStatePath -Content $watcherStateJson
Write-WatcherLog "Watcher started (PID $PID, port $Port)."

$consecutiveFailures = 0
$suspendedUntil = $null
$missedProbes = 0
$restartTimes = New-Object System.Collections.Generic.List[datetime]

try {
  while ($true) {
    $debugReady = Test-DreamDebugPort
    if ($debugReady) { $missedProbes = 0 }
    $injectorHealth = Get-InjectorHealth

    if ($injectorHealth.Status -eq 'ownership-failed') {
      $consecutiveFailures++
      Write-WatcherLog "Injector ownership verification failed; watcher will not touch Codex: $($injectorHealth.Message)"
      if ($consecutiveFailures -ge $MaxConsecutiveFailures) {
        $suspendedUntil = (Get-Date).AddMinutes($CooldownMinutes)
        Write-WatcherLog "Auto-recovery suspended until $($suspendedUntil.ToString('yyyy-MM-dd HH:mm:ss')) because injector ownership could not be verified."
      }
      Start-Sleep -Seconds ([Math]::Max(5, $PollSeconds))
      continue
    }
    if ($injectorHealth.Status -eq 'inspection-failed' -or $injectorHealth.Status -eq 'invalid-state') {
      $consecutiveFailures++
      Write-WatcherLog "Injector inspection failed; watcher will not touch Codex: $($injectorHealth.Message)"
      Start-Sleep -Seconds ([Math]::Max(5, $PollSeconds))
      continue
    }

    if ($debugReady -and $injectorHealth.Status -eq 'healthy') {
      if ($consecutiveFailures -gt 0 -or $null -ne $suspendedUntil) {
        Write-WatcherLog 'Dream Skin is healthy again; resuming normal watch.'
      }
      $consecutiveFailures = 0
      $suspendedUntil = $null
      Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
      continue
    }

    # Circuit breaker: after repeated recovery failures, stop touching Codex for a
    # cooldown period instead of kill-looping it. Codex keeps running unskinned.
    if ($null -ne $suspendedUntil) {
      if ((Get-Date) -ge $suspendedUntil) {
        Write-WatcherLog 'Cooldown ended; auto-recovery re-armed.'
        $suspendedUntil = $null
        $consecutiveFailures = 0
      } else {
        Start-Sleep -Seconds ([Math]::Max(5, $PollSeconds))
        continue
      }
    }

    $failed = $false
    $failureReason = ''

    if ($debugReady) {
      Write-WatcherLog 'Debug port is available but injector is missing; restarting injector.'
      try { & $StartScript -Port $Port | Out-Null } catch { $failed = $true; $failureReason = $_.Exception.Message }
    } else {
      $mainProcesses = @(Get-Process ChatGPT -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
      if ($mainProcesses.Count -eq 0) {
        $missedProbes = 0
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
        continue
      }
      $now = Get-Date
      $oldEnough = @($mainProcesses | Where-Object {
        try { ($now - $_.StartTime).TotalSeconds -ge $LaunchGraceSeconds } catch { $true }
      })
      if ($oldEnough.Count -eq 0) {
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
        continue
      }

      # Debounce: /json/list can transiently miss the app:// page (or time out) while
      # Codex is busy booting. Only treat the skin as lost after several consecutive misses.
      $missedProbes++
      if ($missedProbes -lt $ProbeFailuresBeforeRecovery) {
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
        continue
      }
      $missedProbes = 0

      # Rate limit: even "successful" recoveries must not loop. If we already restarted
      # Codex $MaxRestartsPerWindow times inside the window, something is systemically
      # wrong — suspend instead of restarting again.
      while ($restartTimes.Count -gt 0 -and $restartTimes[0] -lt (Get-Date).AddMinutes(-$RestartWindowMinutes)) {
        $restartTimes.RemoveAt(0)
      }
      if ($restartTimes.Count -ge $MaxRestartsPerWindow) {
        $suspendedUntil = (Get-Date).AddMinutes($CooldownMinutes)
        Write-WatcherLog "Restart rate limit hit ($($restartTimes.Count) restarts within $RestartWindowMinutes minutes); auto-recovery suspended until $($suspendedUntil.ToString('yyyy-MM-dd HH:mm:ss')). Codex keeps running; run start-dream-skin.ps1 manually if the skin is missing."
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
        continue
      }

      Write-WatcherLog 'Detected Codex launched without Dream Skin; restarting it through the skin launcher.'
      $restartTimes.Add((Get-Date))
      try {
        & $StartScript -Port $Port -RestartExisting | Out-Null
        if (Test-DreamDebugPort) {
          Write-WatcherLog 'Codex restarted with Dream Skin.'
        } else {
          $failed = $true
          $failureReason = 'the launcher finished but CDP is still unreachable on both loopbacks'
        }
      } catch {
        $failed = $true
        $failureReason = $_.Exception.Message
      }
    }

    if ($failed) {
      $consecutiveFailures++
      Write-WatcherLog "Recovery failed ($consecutiveFailures/$MaxConsecutiveFailures): $failureReason"
      if ($consecutiveFailures -ge $MaxConsecutiveFailures) {
        $suspendedUntil = (Get-Date).AddMinutes($CooldownMinutes)
        Write-WatcherLog "Auto-recovery suspended until $($suspendedUntil.ToString('yyyy-MM-dd HH:mm:ss')) after $consecutiveFailures consecutive failures. Codex keeps running WITHOUT the skin; run start-dream-skin.ps1 manually to retry sooner."
      } else {
        Start-Sleep -Seconds (10 * $consecutiveFailures)
      }
    } else {
      $consecutiveFailures = 0
    }

    Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
  }
} finally {
  try {
    if (Test-Path -LiteralPath $WatcherStatePath) {
      $state = Get-Content -LiteralPath $WatcherStatePath -Raw | ConvertFrom-Json
      if ([int]$state.watcherPid -eq $PID) { Remove-Item -LiteralPath $WatcherStatePath -Force }
    }
  } catch {}
  Write-WatcherLog "Watcher stopped (PID $PID)."
  try { $mutex.ReleaseMutex() } catch {}
  $mutex.Dispose()
}
