[CmdletBinding()]
param(
  [int]$Port = 9335,
  [switch]$NoShortcuts,
  [switch]$NoAutoRecover
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'file-io.ps1')
. (Join-Path $PSScriptRoot 'process-ownership.ps1')
$SkillRoot = Split-Path -Parent $PSScriptRoot
$node = (Get-Command node -ErrorAction Stop).Source
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$runtimeCheck = Join-Path $PSScriptRoot 'runtime-compat.mjs'
& $node $runtimeCheck --quiet
if ($LASTEXITCODE -ne 0) { throw 'Node runtime compatibility check failed; install was not changed.' }
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
$ConfigPath = Join-Path $HOME '.codex\config.toml'
$BackupPath = Join-Path $StateRoot 'config.before-dream-skin.toml'
$watchScript = Join-Path $PSScriptRoot 'watch-dream-skin.ps1'
$watcherStatePath = Join-Path $StateRoot 'watcher-state.json'
$startup = [Environment]::GetFolderPath('Startup')
$watcherShortcutPath = Join-Path $startup 'Codex Dream Skin Watcher.lnk'
$recordedWatcherReconciled = $false

function Test-WatcherMutexPresent {
  $existingMutex = $null
  $present = $false
  try {
    $existingMutex = [System.Threading.Mutex]::OpenExisting("Local\CodexDreamSkinWatcher-$Port")
    $present = $true
  } catch [System.Threading.WaitHandleCannotBeOpenedException] {
    $present = $false
  } finally {
    if ($existingMutex) { $existingMutex.Dispose() }
  }
  return $present
}

if ($NoAutoRecover) {
  Remove-Item -LiteralPath $watcherShortcutPath -Force -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $watcherStatePath) {
  try {
    $watcherState = Get-Content -LiteralPath $watcherStatePath -Raw | ConvertFrom-Json
    if (-not $watcherState.watcherPid) { throw 'Previous watcher state has no watcherPid.' }
    $recordedWatcherPath = Resolve-RecordedScriptPath -State $watcherState -ExpectedLeafName 'watch-dream-skin.ps1' -RelativePathFromSkillRoot 'scripts\watch-dream-skin.ps1' -FallbackPath $watchScript
    $recordedPowerShellPath = Resolve-RecordedExecutablePath -State $watcherState -FallbackPath $powershell
  } catch {
    throw "Could not validate the previous watcher state; state was preserved: $($_.Exception.Message)"
  }
  $recordedStartTime = if ($watcherState.processStartTimeUtc) { [string]$watcherState.processStartTimeUtc } else { $null }
  $stopResult = Stop-RecordedProcess -ProcessId ([int]$watcherState.watcherPid) -ExpectedScriptPath $recordedWatcherPath -ExpectedExecutablePath $recordedPowerShellPath -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc $recordedStartTime -Description 'watcher'
  if (-not $stopResult.Success) {
    throw "Could not safely replace or disable the previous watcher; state was preserved. $($stopResult.Message)"
  }
  if (-not $stopResult.CanDiscardState) {
    throw 'Previous watcher reconciliation did not confirm that its state can be discarded.'
  }
  Remove-Item -LiteralPath $watcherStatePath -Force -ErrorAction Stop
  $recordedWatcherReconciled = $true
}

if (Test-WatcherMutexPresent) {
  throw "A watcher mutex exists on port $Port without safely reconcilable state. The Startup shortcut was removed when -NoAutoRecover was requested, but a current watcher may still be running."
}

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Codex config not found: $ConfigPath" }
if (-not (Test-Path -LiteralPath $BackupPath)) {
  Copy-FileAtomically -SourcePath $ConfigPath -DestinationPath $BackupPath
}

$content = Get-Content -LiteralPath $ConfigPath -Raw
$desktopMatch = [regex]::Match($content, '(?ms)^\[desktop\]\s*\r?\n(?<body>.*?)(?=^\[|\z)')
if (-not $desktopMatch.Success) {
  $content = $content.TrimEnd() + "`r`n`r`n[desktop]`r`n"
  $desktopMatch = [regex]::Match($content, '(?ms)^\[desktop\]\s*\r?\n(?<body>.*?)(?=^\[|\z)')
}
$body = $desktopMatch.Groups['body'].Value
$settings = [ordered]@{
  appearanceTheme = 'appearanceTheme = "light"'
  appearanceLightCodeThemeId = 'appearanceLightCodeThemeId = "codex"'
  appearanceLightChromeTheme = 'appearanceLightChromeTheme = { accent = "#B65CFF", contrast = 64, fonts = { code = "Cascadia Code", ui = "Microsoft YaHei UI" }, ink = "#4A235F", opaqueWindows = true, semanticColors = { diffAdded = "#BCE8CF", diffRemoved = "#F7B8CE", skill = "#C47BFF" }, surface = "#FFF4FA" }'
}
foreach ($key in $settings.Keys) {
  $pattern = "(?m)^$([regex]::Escape($key))\s*=.*$"
  if ([regex]::IsMatch($body, $pattern)) { $body = [regex]::Replace($body, $pattern, $settings[$key]) }
  else { $body = $body.TrimEnd() + "`r`n" + $settings[$key] + "`r`n" }
}
$content = $content.Substring(0, $desktopMatch.Groups['body'].Index) + $body + $content.Substring($desktopMatch.Groups['body'].Index + $desktopMatch.Groups['body'].Length)
Write-AtomicUtf8File -LiteralPath $ConfigPath -Content $content

if (-not $NoShortcuts) {
  $shell = New-Object -ComObject WScript.Shell
  $desktop = [Environment]::GetFolderPath('Desktop')
  $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  $startScript = Join-Path $PSScriptRoot 'start-dream-skin.ps1'
  $restoreScript = Join-Path $PSScriptRoot 'restore-dream-skin.ps1'
  foreach ($folder in @($desktop, $startMenu)) {
    $shortcut = $shell.CreateShortcut((Join-Path $folder 'Codex Dream Skin.lnk'))
    $shortcut.TargetPath = $powershell
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$startScript`" -Port $Port -RestartExisting"
    $shortcut.WorkingDirectory = $SkillRoot
    $shortcut.Description = 'Launch Codex with the Dream Skin theme engine'
    $shortcut.Save()
  }
  $restore = $shell.CreateShortcut((Join-Path $desktop 'Codex Dream Skin - Restore.lnk'))
  $restore.TargetPath = $powershell
  $restore.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$restoreScript`" -Port $Port"
  $restore.WorkingDirectory = $SkillRoot
  $restore.Description = 'Remove the live Codex Dream Skin'
  $restore.Save()
}

if (-not $NoAutoRecover) {
  $shell = New-Object -ComObject WScript.Shell
  $watcherShortcut = $shell.CreateShortcut($watcherShortcutPath)
  $watcherShortcut.TargetPath = $powershell
  $watcherShortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchScript`" -Port $Port"
  $watcherShortcut.WorkingDirectory = $SkillRoot
  $watcherShortcut.Description = 'Automatically restore Codex Dream Skin after a normal Codex restart'
  $watcherShortcut.Save()
  $watcherProcess = Start-Process -FilePath $powershell -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$watchScript`"", '-Port', "$Port"
  )
  $watcherStartTime = $watcherProcess.StartTime.ToUniversalTime().ToString('o')
  $watcherReady = $false
  $watcherLaunchFailure = 'Watcher did not publish verifiable state within 8 seconds.'
  for ($attempt = 0; $attempt -lt 32; $attempt++) {
    Start-Sleep -Milliseconds 250
    try {
      if ($watcherProcess.HasExited) {
        $watcherLaunchFailure = "Watcher process exited with code $($watcherProcess.ExitCode) before readiness."
        break
      }
      if (-not (Test-Path -LiteralPath $watcherStatePath)) { continue }
      $newWatcherState = Get-Content -LiteralPath $watcherStatePath -Raw | ConvertFrom-Json
      if ([int]$newWatcherState.watcherPid -ne [int]$watcherProcess.Id) {
        $watcherLaunchFailure = 'Watcher state belongs to a different process.'
        break
      }
      $newWatcherOwnership = Get-RecordedProcessOwnership -ProcessId ([int]$newWatcherState.watcherPid) -ExpectedScriptPath $watchScript -ExpectedExecutablePath $powershell -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc $watcherStartTime
      if ($newWatcherOwnership.Status -eq 'owned') {
        $watcherReady = $true
        break
      }
      $watcherLaunchFailure = $newWatcherOwnership.Message
      if ($newWatcherOwnership.Status -ne 'inspection-failed') { break }
    } catch {
      $watcherLaunchFailure = $_.Exception.Message
    }
  }
  if (-not $watcherReady) {
    Remove-Item -LiteralPath $watcherShortcutPath -Force -ErrorAction SilentlyContinue
    $cleanupResult = Stop-RecordedProcess -ProcessId ([int]$watcherProcess.Id) -ExpectedScriptPath $watchScript -ExpectedExecutablePath $powershell -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc $watcherStartTime -Description 'new watcher'
    if ($cleanupResult.CanDiscardState -and (Test-Path -LiteralPath $watcherStatePath)) {
      try {
        $cleanupState = Get-Content -LiteralPath $watcherStatePath -Raw | ConvertFrom-Json
        if ([int]$cleanupState.watcherPid -eq [int]$watcherProcess.Id) {
          Remove-Item -LiteralPath $watcherStatePath -Force -ErrorAction Stop
        }
      } catch {}
    }
    throw "Auto-recovery watcher failed readiness verification. $watcherLaunchFailure"
  }
}

if ($NoAutoRecover) {
  if ($recordedWatcherReconciled) {
    Write-Host 'Codex Dream Skin installed. Auto-recovery disabled; the recorded watcher was stopped and the Startup shortcut was removed.'
  } else {
    Write-Host "Codex Dream Skin installed. Auto-recovery disabled; no watcher mutex was present on port $Port and the Startup shortcut was removed."
  }
} else {
  Write-Host "Codex Dream Skin installed. Auto-recovery watcher started as PID $($watcherProcess.Id); normal Codex restarts will recover the skin automatically."
}
