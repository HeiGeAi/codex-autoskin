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
$StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
$ConfigPath = Join-Path $HOME '.codex\config.toml'
$BackupPath = Join-Path $StateRoot 'config.before-dream-skin.toml'
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
  $powershell = (Get-Command powershell.exe).Source
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
  $powershell = (Get-Command powershell.exe).Source
  $startup = [Environment]::GetFolderPath('Startup')
  $watchScript = Join-Path $PSScriptRoot 'watch-dream-skin.ps1'
  $watcherShortcutPath = Join-Path $startup 'Codex Dream Skin Watcher.lnk'
  $watcherShortcut = $shell.CreateShortcut($watcherShortcutPath)
  $watcherShortcut.TargetPath = $powershell
  $watcherShortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchScript`" -Port $Port"
  $watcherShortcut.WorkingDirectory = $SkillRoot
  $watcherShortcut.Description = 'Automatically restore Codex Dream Skin after a normal Codex restart'
  $watcherShortcut.Save()

  $watcherStatePath = Join-Path $StateRoot 'watcher-state.json'
  if (Test-Path -LiteralPath $watcherStatePath) {
    $recordedWatcherPid = $null
    try {
      $watcherState = Get-Content -LiteralPath $watcherStatePath -Raw | ConvertFrom-Json
      if ($watcherState.watcherPid) { $recordedWatcherPid = [int]$watcherState.watcherPid }
    } catch {
      Write-Warning "Could not read the previous watcher state: $($_.Exception.Message)"
    }
    if ($recordedWatcherPid) {
      [void](Stop-RecordedProcess -ProcessId $recordedWatcherPid -ExpectedScriptPath $watchScript -Description 'watcher')
    }
    Remove-Item -LiteralPath $watcherStatePath -Force -ErrorAction SilentlyContinue
  }
  Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$watchScript`"", '-Port', "$Port"
  )
}

Write-Host 'Codex Dream Skin installed. Normal Codex restarts will now recover the skin automatically.'
