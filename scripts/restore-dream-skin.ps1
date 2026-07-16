[CmdletBinding()]
param(
  [int]$Port = 9335,
  [switch]$Uninstall,
  [switch]$RestoreBaseTheme
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'file-io.ps1')
. (Join-Path $PSScriptRoot 'process-ownership.ps1')
$node = (Get-Command node -ErrorAction Stop).Source
$injector = Join-Path $PSScriptRoot 'injector.mjs'
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
$StatePath = Join-Path $StateRoot 'state.json'
$WatcherStatePath = Join-Path $StateRoot 'watcher-state.json'
$EffectivePort = $Port
$watchScript = Join-Path $PSScriptRoot 'watch-dream-skin.ps1'

if (Test-Path -LiteralPath $WatcherStatePath) {
  $recordedWatcherPid = $null
  try {
    $watcherState = Get-Content -LiteralPath $WatcherStatePath -Raw | ConvertFrom-Json
    if ($watcherState.watcherPid) { $recordedWatcherPid = [int]$watcherState.watcherPid }
  } catch {
    Write-Warning "Could not read the watcher state: $($_.Exception.Message)"
  }
  if ($recordedWatcherPid) {
    [void](Stop-RecordedProcess -ProcessId $recordedWatcherPid -ExpectedScriptPath $watchScript -Description 'watcher')
  }
  Remove-Item -LiteralPath $WatcherStatePath -Force -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $StatePath) {
  $recordedInjectorPid = $null
  try {
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('Port') -and $state.port) { $EffectivePort = [int]$state.port }
    if ($state.injectorPid) { $recordedInjectorPid = [int]$state.injectorPid }
  } catch {
    Write-Warning "Could not read the injector state: $($_.Exception.Message)"
  }
  if ($recordedInjectorPid) {
    [void](Stop-RecordedProcess -ProcessId $recordedInjectorPid -ExpectedScriptPath $injector -Description 'injector')
  }
}
Start-Sleep -Milliseconds 250
$codexRunning = @(Get-Process ChatGPT -ErrorAction SilentlyContinue).Count -gt 0
$removeOutput = @(& $node $injector --remove --port $EffectivePort --timeout-ms 3000 2>&1)
$removeExitCode = $LASTEXITCODE
if ($removeExitCode -ne 0 -and $codexRunning) {
  $detail = ($removeOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
  throw "Failed to remove the live Dream Skin from Codex on port $EffectivePort (injector exit $removeExitCode). $detail"
}
Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue

if ($Uninstall) {
  $desktop = [Environment]::GetFolderPath('Desktop')
  $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  @(
    (Join-Path $desktop 'Codex Dream Skin.lnk'),
    (Join-Path $desktop 'Codex Dream Skin - Restore.lnk'),
    (Join-Path $startMenu 'Codex Dream Skin.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Dream Skin Watcher.lnk')
  ) | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }
}

if ($RestoreBaseTheme) {
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
      $desktop = [regex]::Match($currentContent, '(?ms)^\[desktop\]\s*\r?\n(?<body>.*?)(?=^\[|\z)')
      if (-not $desktop.Success) {
        $currentContent = $currentContent.TrimEnd() + "`r`n`r`n[desktop]`r`n"
        $desktop = [regex]::Match($currentContent, '(?ms)^\[desktop\]\s*\r?\n(?<body>.*?)(?=^\[|\z)')
      }
      $body = $desktop.Groups['body'].Value.TrimEnd() + "`r`n" + $saved.Value.TrimEnd("`r", "`n") + "`r`n"
      $currentContent = $currentContent.Substring(0, $desktop.Groups['body'].Index) + $body +
        $currentContent.Substring($desktop.Groups['body'].Index + $desktop.Groups['body'].Length)
    }
  }
  Write-AtomicUtf8File -LiteralPath $config -Content $currentContent
  # The backup represents the state immediately before one install lifecycle.
  # Consume it after a successful restore so a later reinstall snapshots the
  # user's then-current official theme instead of reusing stale first-run data.
  Remove-Item -LiteralPath $backup -Force
}

Write-Host 'The live Dream Skin was removed.'
