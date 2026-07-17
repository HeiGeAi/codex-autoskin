[CmdletBinding()]
param(
  [int]$Port = 9335,
  [switch]$Uninstall,
  [switch]$RestoreBaseTheme
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'file-io.ps1')
. (Join-Path $PSScriptRoot 'process-ownership.ps1')
$SkillRoot = Split-Path -Parent $PSScriptRoot
$injector = Join-Path $PSScriptRoot 'injector.mjs'
$watchScript = Join-Path $PSScriptRoot 'watch-dream-skin.ps1'
$runtimeCheck = Join-Path $PSScriptRoot 'runtime-compat.mjs'
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
$StatePath = Join-Path $StateRoot 'state.json'
$WatcherStatePath = Join-Path $StateRoot 'watcher-state.json'
$EffectivePort = $Port
$failures = New-Object System.Collections.Generic.List[object]

function Add-PhaseFailure {
  param(
    [Parameter(Mandatory)][string]$Phase,
    [Parameter(Mandatory)][string]$Message
  )
  $failures.Add([pscustomobject]@{ Phase = $Phase; Message = $Message })
  Write-Warning "${Phase}: $Message"
}

$hostExecutable = $null
try { $hostExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path } catch {}

# Phase: watcher state read
$watcherState = $null
$watcherStateValid = $false
if (Test-Path -LiteralPath $WatcherStatePath) {
  try {
    $watcherState = Get-Content -LiteralPath $WatcherStatePath -Raw | ConvertFrom-Json
    if (-not $watcherState.watcherPid) { throw 'Watcher state has no watcherPid.' }
    if (-not $hostExecutable -and -not $watcherState.executablePath) {
      throw 'The watcher executable cannot be resolved from either state or the current PowerShell host.'
    }
    $recordedWatcherPath = Resolve-RecordedScriptPath -State $watcherState -ExpectedLeafName 'watch-dream-skin.ps1' -RelativePathFromSkillRoot 'scripts\watch-dream-skin.ps1' -FallbackPath $watchScript
    $hostFallback = if ($hostExecutable) { $hostExecutable } else { [string]$watcherState.executablePath }
    $recordedPowerShellPath = Resolve-RecordedExecutablePath -State $watcherState -FallbackPath $hostFallback
    $watcherStartTime = if ($watcherState.processStartTimeUtc) { [string]$watcherState.processStartTimeUtc } else { $null }
    $watcherStateValid = $true
  } catch {
    Add-PhaseFailure -Phase 'watcher state read' -Message $_.Exception.Message
  }
}

# Phase: watcher stop
if ($watcherStateValid) {
  $stopResult = Stop-RecordedProcess -ProcessId ([int]$watcherState.watcherPid) -ExpectedScriptPath $recordedWatcherPath -ExpectedExecutablePath $recordedPowerShellPath -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc $watcherStartTime -Description 'watcher'
  if (-not $stopResult.Success -or -not $stopResult.CanDiscardState) {
    Add-PhaseFailure -Phase 'watcher stop' -Message $stopResult.Message
  } else {
    try {
      Remove-Item -LiteralPath $WatcherStatePath -Force -ErrorAction Stop
      Write-Host 'Watcher process stopped or confirmed absent.'
    } catch {
      Add-PhaseFailure -Phase 'watcher state cleanup' -Message $_.Exception.Message
    }
  }
}

# Phase: injector state read
$injectorState = $null
$injectorStateValid = $false
$injectorStateCanBeRemoved = $false
if (Test-Path -LiteralPath $StatePath) {
  try {
    $injectorState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('Port') -and $injectorState.port) { $EffectivePort = [int]$injectorState.port }
    if (-not $injectorState.injectorPid) { throw 'Injector state has no injectorPid.' }
    $recordedInjectorPath = Resolve-RecordedScriptPath -State $injectorState -ExpectedLeafName 'injector.mjs' -RelativePathFromSkillRoot 'scripts\injector.mjs' -FallbackPath $injector
    if ($injectorState.executablePath) {
      $nodeOwnershipFallback = [string]$injectorState.executablePath
    } else {
      $nodeOwnershipFallback = (Get-Command -Name node -ErrorAction Stop).Source
    }
    $recordedNodePath = Resolve-RecordedExecutablePath -State $injectorState -FallbackPath $nodeOwnershipFallback
    $injectorStartTime = if ($injectorState.processStartTimeUtc) { [string]$injectorState.processStartTimeUtc } else { $null }
    $injectorStateValid = $true
  } catch {
    Add-PhaseFailure -Phase 'injector state read' -Message $_.Exception.Message
  }
}

# Phase: injector stop
if ($injectorStateValid) {
  $stopResult = Stop-RecordedProcess -ProcessId ([int]$injectorState.injectorPid) -ExpectedScriptPath $recordedInjectorPath -ExpectedExecutablePath $recordedNodePath -ScriptArgumentMode 'NodeEntryPoint' -ExpectedProcessStartTimeUtc $injectorStartTime -Description 'injector'
  if (-not $stopResult.Success -or -not $stopResult.CanDiscardState) {
    Add-PhaseFailure -Phase 'injector stop' -Message $stopResult.Message
  } else {
    $injectorStateCanBeRemoved = $true
    Write-Host 'Injector process stopped or confirmed absent.'
  }
}

Start-Sleep -Milliseconds 250

# Phase: live DOM removal
$liveRemovalSucceeded = $false
$removeExitCode = -1
try {
  $node = (Get-Command node -ErrorAction Stop).Source
  & $node $runtimeCheck --quiet
  if ($LASTEXITCODE -ne 0) { throw 'Node runtime compatibility check failed.' }
  $removeOutput = @(& $node $injector --remove --port $EffectivePort --timeout-ms 3000 2>&1)
  $removeExitCode = $LASTEXITCODE
  if ($removeExitCode -ne 0) {
    $detail = ($removeOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    Add-PhaseFailure -Phase 'live DOM removal' -Message "Injector exited with code $removeExitCode on port $EffectivePort. $detail"
  } else {
    $liveRemovalSucceeded = $true
    Write-Host "Live Dream Skin removal was verified on port $EffectivePort."
  }
} catch {
  Add-PhaseFailure -Phase 'live DOM removal' -Message $_.Exception.Message
}

if ($injectorStateCanBeRemoved -and $liveRemovalSucceeded) {
  try {
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop
  } catch {
    Add-PhaseFailure -Phase 'injector state cleanup' -Message $_.Exception.Message
  }
}

# Phase: shortcut uninstall
if ($Uninstall) {
  try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    @(
      (Join-Path $desktop 'Codex Dream Skin.lnk'),
      (Join-Path $desktop 'Codex Dream Skin - Restore.lnk'),
      (Join-Path $startMenu 'Codex Dream Skin.lnk'),
      (Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Dream Skin Watcher.lnk')
    ) | ForEach-Object {
      if (Test-Path -LiteralPath $_) { Remove-Item -LiteralPath $_ -Force -ErrorAction Stop }
    }
    Write-Host 'Dream Skin shortcuts were removed.'
  } catch {
    Add-PhaseFailure -Phase 'shortcut uninstall' -Message $_.Exception.Message
  }
}

# Phase: base-theme restore
if ($RestoreBaseTheme) {
  try {
    $backup = Join-Path $StateRoot 'config.before-dream-skin.toml'
    $config = Join-Path $HOME '.codex\config.toml'
    if (-not (Test-Path -LiteralPath $backup)) { throw 'No pre-install config backup is available.' }
    $backupContent = Get-Content -LiteralPath $backup -Raw
    $currentContent = Get-Content -LiteralPath $config -Raw
    foreach ($key in @('appearanceTheme', 'appearanceLightCodeThemeId', 'appearanceLightChromeTheme')) {
      $pattern = "(?m)^$([regex]::Escape($key))\s*=.*(?:\r?\n)?"
      $saved = [regex]::Match($backupContent, $pattern)
      if ([regex]::IsMatch($currentContent, $pattern)) {
        $replacement = if ($saved.Success) { $saved.Value.TrimEnd("`r", "`n") + "`r`n" } else { '' }
        $currentContent = [regex]::Replace($currentContent, $pattern, $replacement, 1)
      } elseif ($saved.Success) {
        $desktopSection = [regex]::Match($currentContent, '(?ms)^\[desktop\]\s*\r?\n(?<body>.*?)(?=^\[|\z)')
        if (-not $desktopSection.Success) {
          $currentContent = $currentContent.TrimEnd() + "`r`n`r`n[desktop]`r`n"
          $desktopSection = [regex]::Match($currentContent, '(?ms)^\[desktop\]\s*\r?\n(?<body>.*?)(?=^\[|\z)')
        }
        $body = $desktopSection.Groups['body'].Value.TrimEnd() + "`r`n" + $saved.Value.TrimEnd("`r", "`n") + "`r`n"
        $currentContent = $currentContent.Substring(0, $desktopSection.Groups['body'].Index) + $body +
          $currentContent.Substring($desktopSection.Groups['body'].Index + $desktopSection.Groups['body'].Length)
      }
    }
    Write-AtomicUtf8File -LiteralPath $config -Content $currentContent
    Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
    Write-Host 'The pre-install Codex appearance settings were restored.'
  } catch {
    Add-PhaseFailure -Phase 'base-theme restore' -Message $_.Exception.Message
  }
}

if ($failures.Count -gt 0) {
  Write-Warning "Dream Skin restore completed with $($failures.Count) failed phase(s). Requested independent local phases were still attempted."
  foreach ($failure in $failures) {
    Write-Warning "[$($failure.Phase)] $($failure.Message)"
  }
  exit 1
}

Write-Host 'Dream Skin restore completed successfully.'
exit 0
