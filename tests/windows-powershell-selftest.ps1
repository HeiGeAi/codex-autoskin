[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PowerShellPath = (Get-Process -Id $PID -ErrorAction Stop).Path
$NodePath = (Get-Command node -ErrorAction Stop).Source
$Sandbox = Join-Path $env:TEMP "codex-autoskin-ps51-$([guid]::NewGuid().ToString('N'))"
$OriginalLocalAppData = $env:LOCALAPPDATA
$OriginalAppData = $env:APPDATA
$OriginalPath = $env:PATH
$StateRoot = Join-Path $Sandbox 'local\CodexDreamSkin'
$FixtureSkillRoot = Join-Path $Sandbox 'fixture-skill'
$FixtureScripts = Join-Path $FixtureSkillRoot 'scripts'
$Children = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
$ExternalArtifacts = New-Object System.Collections.Generic.List[string]
$Failures = New-Object System.Collections.Generic.List[string]
$Utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
$ConfigDirectory = Join-Path $HOME '.codex'
$ConfigPath = Join-Path $ConfigDirectory 'config.toml'
$ConfigDirectoryExisted = Test-Path -LiteralPath $ConfigDirectory
$OriginalConfigExists = Test-Path -LiteralPath $ConfigPath
$OriginalConfigBytes = if ($OriginalConfigExists) { [System.IO.File]::ReadAllBytes($ConfigPath) } else { $null }

function Write-TestFile {
  param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Content
  )
  $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($LiteralPath))
  [void][System.IO.Directory]::CreateDirectory($directory)
  [System.IO.File]::WriteAllText($LiteralPath, $Content, $Utf8WithoutBom)
}

function Write-TestJson {
  param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [Parameter(Mandatory)][object]$Value
  )
  Write-TestFile -LiteralPath $LiteralPath -Content (($Value | ConvertTo-Json -Depth 8) + "`r`n")
}

function Assert-True {
  param(
    [Parameter(Mandatory)][bool]$Condition,
    [Parameter(Mandatory)][string]$Message
  )
  if (-not $Condition) { throw $Message }
}

function Assert-Equal {
  param(
    [Parameter(Mandatory)]$Expected,
    [Parameter(Mandatory)]$Actual,
    [Parameter(Mandatory)][string]$Message
  )
  if (-not [object]::Equals($Expected, $Actual)) {
    throw "$Message Expected '$Expected', received '$Actual'."
  }
}

function Invoke-SelfTest {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$Body
  )
  try {
    & $Body
    Write-Host "PASS: $Name"
  } catch {
    $Failures.Add("${Name}: $($_.Exception.Message)")
    Write-Host "FAIL: ${Name}: $($_.Exception.Message)" -ForegroundColor Red
  }
}

function Start-TestProcess {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string[]]$ArgumentList
  )
  $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WindowStyle Hidden -PassThru
  $Children.Add($process)
  Start-Sleep -Milliseconds 400
  if ($process.HasExited) { throw "Fixture process exited early with code $($process.ExitCode)." }
  return $process
}

function New-ExternalArtifact {
  param([Parameter(Mandatory)][string]$LiteralPath)
  if (Test-Path -LiteralPath $LiteralPath) {
    throw "Refusing to overwrite a pre-existing runner artifact: $LiteralPath"
  }
  Write-TestFile -LiteralPath $LiteralPath -Content 'codex-autoskin PS5.1 selftest marker'
  $ExternalArtifacts.Add($LiteralPath)
}

function Reset-StateRoot {
  if (Test-Path -LiteralPath $StateRoot) { Remove-Item -LiteralPath $StateRoot -Recurse -Force }
  [void][System.IO.Directory]::CreateDirectory($StateRoot)
}

try {
  [void][System.IO.Directory]::CreateDirectory($FixtureScripts)
  [void][System.IO.Directory]::CreateDirectory($ConfigDirectory)
  $env:LOCALAPPDATA = Join-Path $Sandbox 'local'
  $env:APPDATA = Join-Path $Sandbox 'roaming'
  [void][System.IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
  [void][System.IO.Directory]::CreateDirectory($env:APPDATA)

  $WatcherFixture = Join-Path $FixtureScripts 'watch-dream-skin.ps1'
  $DecoyFixture = Join-Path $FixtureScripts 'decoy.ps1'
  $InjectorFixture = Join-Path $FixtureScripts 'injector.mjs'
  Write-TestFile -LiteralPath $WatcherFixture -Content @'
[CmdletBinding()]
param([int]$HoldSeconds = 60, [string]$Decoy)
Start-Sleep -Seconds $HoldSeconds
'@
  Write-TestFile -LiteralPath $DecoyFixture -Content "Start-Sleep -Seconds 60`r`n"
  Write-TestFile -LiteralPath $InjectorFixture -Content "setInterval(() => {}, 1000);`n"

  . (Join-Path $RepoRoot 'scripts\process-ownership.ps1')

  Invoke-SelfTest 'ownership contract verifies exact executable, argv position, start time, and stop confirmation' {
    $powerShellChild = Start-TestProcess -FilePath $PowerShellPath -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$WatcherFixture`"",
      '-HoldSeconds', '60', '-Decoy', "`"$DecoyFixture`""
    )
    $powerShellStart = $powerShellChild.StartTime.ToUniversalTime().ToString('o')
    $owned = Get-RecordedProcessOwnership -ProcessId $powerShellChild.Id -ExpectedScriptPath $WatcherFixture -ExpectedExecutablePath $PowerShellPath -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc $powerShellStart
    Assert-Equal -Expected 'owned' -Actual $owned.Status -Message 'A correct PowerShell -File process must be owned.'
    Assert-True -Condition ($owned.Success -and $owned.Owned -and -not $owned.CanDiscardState) -Message 'The owned status flags are inconsistent.'

    $wrongExecutable = Get-RecordedProcessOwnership -ProcessId $powerShellChild.Id -ExpectedScriptPath $WatcherFixture -ExpectedExecutablePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc $powerShellStart
    Assert-Equal -Expected 'ownership-failed' -Actual $wrongExecutable.Status -Message 'A wrong executable must fail ownership.'

    $ordinaryArgument = Get-RecordedProcessOwnership -ProcessId $powerShellChild.Id -ExpectedScriptPath $DecoyFixture -ExpectedExecutablePath $PowerShellPath -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc $powerShellStart
    Assert-Equal -Expected 'ownership-failed' -Actual $ordinaryArgument.Status -Message 'A script path in an ordinary argument must not satisfy the -File contract.'

    $wrongStart = $powerShellChild.StartTime.ToUniversalTime().AddSeconds(-1).ToString('o')
    $reusedPid = Get-RecordedProcessOwnership -ProcessId $powerShellChild.Id -ExpectedScriptPath $WatcherFixture -ExpectedExecutablePath $PowerShellPath -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc $wrongStart
    Assert-Equal -Expected 'ownership-failed' -Actual $reusedPid.Status -Message 'A mismatched process start time must fail ownership.'

    $invalidState = Get-RecordedProcessOwnership -ProcessId $powerShellChild.Id -ExpectedScriptPath $WatcherFixture -ExpectedExecutablePath $PowerShellPath -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc 'not-a-date'
    Assert-Equal -Expected 'invalid-state' -Actual $invalidState.Status -Message 'Malformed recorded metadata must be invalid-state.'

    Set-Item -Path Function:\Get-CimInstance -Value { throw 'simulated CIM failure' }
    try {
      $inspection = Get-RecordedProcessOwnership -ProcessId $powerShellChild.Id -ExpectedScriptPath $WatcherFixture -ExpectedExecutablePath $PowerShellPath -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc $powerShellStart
      Assert-Equal -Expected 'inspection-failed' -Actual $inspection.Status -Message 'CIM failure must not be treated as a missing process.'
    } finally {
      Remove-Item -Path Function:\Get-CimInstance -Force
    }

    $stopped = Stop-RecordedProcess -ProcessId $powerShellChild.Id -ExpectedScriptPath $WatcherFixture -ExpectedExecutablePath $PowerShellPath -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc $powerShellStart -Description 'selftest watcher'
    Assert-Equal -Expected 'stopped' -Actual $stopped.Status -Message 'A verified child must be stopped.'
    Assert-True -Condition ($stopped.Success -and $stopped.CanDiscardState) -Message 'Stopped status must allow state cleanup.'
    $powerShellChild.Refresh()
    Assert-True -Condition $powerShellChild.HasExited -Message 'Stop-RecordedProcess returned before the child exited.'

    $notRunning = Get-RecordedProcessOwnership -ProcessId $powerShellChild.Id -ExpectedScriptPath $WatcherFixture -ExpectedExecutablePath $PowerShellPath -ScriptArgumentMode 'PowerShellFile' -ExpectedProcessStartTimeUtc $powerShellStart
    Assert-Equal -Expected 'not-running' -Actual $notRunning.Status -Message 'An exited recorded process must be not-running.'
    Assert-True -Condition $notRunning.CanDiscardState -Message 'not-running must allow state cleanup.'

    $nodeChild = Start-TestProcess -FilePath $NodePath -ArgumentList @("`"$InjectorFixture`"", "`"$DecoyFixture`"")
    $nodeStart = $nodeChild.StartTime.ToUniversalTime().ToString('o')
    $nodeOwned = Get-RecordedProcessOwnership -ProcessId $nodeChild.Id -ExpectedScriptPath $InjectorFixture -ExpectedExecutablePath $NodePath -ScriptArgumentMode 'NodeEntryPoint' -ExpectedProcessStartTimeUtc $nodeStart
    Assert-Equal -Expected 'owned' -Actual $nodeOwned.Status -Message 'Node argv[1] must identify the owned entry point.'
    $nodeDecoy = Get-RecordedProcessOwnership -ProcessId $nodeChild.Id -ExpectedScriptPath $DecoyFixture -ExpectedExecutablePath $NodePath -ScriptArgumentMode 'NodeEntryPoint' -ExpectedProcessStartTimeUtc $nodeStart
    Assert-Equal -Expected 'ownership-failed' -Actual $nodeDecoy.Status -Message 'A later Node argument must not identify the entry point.'
    $nodeStopped = Stop-RecordedProcess -ProcessId $nodeChild.Id -ExpectedScriptPath $InjectorFixture -ExpectedExecutablePath $NodePath -ScriptArgumentMode 'NodeEntryPoint' -ExpectedProcessStartTimeUtc $nodeStart -Description 'selftest injector'
    Assert-Equal -Expected 'stopped' -Actual $nodeStopped.Status -Message 'The owned Node child must stop cleanly.'
  }

  Invoke-SelfTest 'start fails closed and preserves injector state before touching Codex' {
    Reset-StateRoot
    $statePath = Join-Path $StateRoot 'state.json'
    $state = @{
      schemaVersion = 2
      component = 'injector'
      injectorPid = $PID
      port = 19335
      scriptPath = Join-Path $RepoRoot 'scripts\injector.mjs'
      executablePath = $NodePath
      skillRoot = $RepoRoot
      processStartTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
      startedAt = (Get-Date).ToString('o')
    }
    Write-TestJson -LiteralPath $statePath -Value $state
    $before = [System.IO.File]::ReadAllText($statePath)
    $failedClosed = $false
    try {
      & (Join-Path $RepoRoot 'scripts\start-dream-skin.ps1') -Port 19335
    } catch {
      $failedClosed = $true
      Assert-True -Condition ($_.Exception.Message -like '*state was preserved*') -Message 'The launcher did not report preserved state.'
    }
    Assert-True -Condition $failedClosed -Message 'The launcher accepted a PID owned by another executable.'
    Assert-True -Condition (Test-Path -LiteralPath $statePath) -Message 'The launcher deleted untrusted injector state.'
    Assert-Equal -Expected $before -Actual ([System.IO.File]::ReadAllText($statePath)) -Message 'The launcher mutated untrusted injector state.'
  }

  Invoke-SelfTest 'NoAutoRecover removes Startup re-entry but preserves mismatched watcher state' {
    Reset-StateRoot
    $watcherStatePath = Join-Path $StateRoot 'watcher-state.json'
    $startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Dream Skin Watcher.lnk'
    New-ExternalArtifact -LiteralPath $startupShortcut
    $state = @{
      schemaVersion = 2
      component = 'watcher'
      watcherPid = $PID
      port = 19335
      scriptPath = Join-Path $RepoRoot 'scripts\watch-dream-skin.ps1'
      executablePath = $PowerShellPath
      skillRoot = $RepoRoot
      processStartTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
      startedAt = (Get-Date).ToString('o')
    }
    Write-TestJson -LiteralPath $watcherStatePath -Value $state
    $failedClosed = $false
    try {
      & (Join-Path $RepoRoot 'scripts\install-dream-skin.ps1') -Port 19335 -NoShortcuts -NoAutoRecover
    } catch {
      $failedClosed = $true
    }
    Assert-True -Condition $failedClosed -Message 'Install accepted a watcher PID with the wrong -File script.'
    Assert-True -Condition (Test-Path -LiteralPath $watcherStatePath) -Message 'Install deleted mismatched watcher state.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $startupShortcut)) -Message 'NoAutoRecover left the Startup shortcut after fail-closed reconciliation.'
  }

  Invoke-SelfTest 'NoAutoRecover fails closed when a watcher mutex has no ownership state' {
    Reset-StateRoot
    $startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Dream Skin Watcher.lnk'
    New-ExternalArtifact -LiteralPath $startupShortcut
    $createdMutex = $false
    $orphanMutex = New-Object System.Threading.Mutex($true, 'Local\CodexDreamSkinWatcher-19335', [ref]$createdMutex)
    try {
      Assert-True -Condition $createdMutex -Message 'The selftest could not create its orphan watcher mutex.'
      $failedClosed = $false
      try {
        & (Join-Path $RepoRoot 'scripts\install-dream-skin.ps1') -Port 19335 -NoShortcuts -NoAutoRecover
      } catch {
        $failedClosed = $true
        Assert-True -Condition ($_.Exception.Message -like '*current watcher may still be running*') -Message 'Install hid the untracked watcher boundary.'
      }
      Assert-True -Condition $failedClosed -Message 'Install ignored an untracked watcher mutex.'
      Assert-True -Condition (-not (Test-Path -LiteralPath $startupShortcut)) -Message 'NoAutoRecover left the Startup shortcut for an untracked watcher.'
    } finally {
      try { $orphanMutex.ReleaseMutex() } catch {}
      $orphanMutex.Dispose()
    }
  }

  Invoke-SelfTest 'NoAutoRecover stops a verified legacy watcher and reports an honest disabled state' {
    Reset-StateRoot
    Write-TestFile -LiteralPath $ConfigPath -Content "[desktop]`r`nappearanceTheme = `"dark`"`r`n"
    $startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Dream Skin Watcher.lnk'
    New-ExternalArtifact -LiteralPath $startupShortcut
    $watcher = Start-TestProcess -FilePath $PowerShellPath -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$WatcherFixture`"", '-HoldSeconds', '60'
    )
    $watcherStatePath = Join-Path $StateRoot 'watcher-state.json'
    Write-TestJson -LiteralPath $watcherStatePath -Value @{
      schemaVersion = 2
      component = 'watcher'
      watcherPid = $watcher.Id
      port = 19335
      scriptPath = $WatcherFixture
      executablePath = $PowerShellPath
      skillRoot = $FixtureSkillRoot
      processStartTimeUtc = $watcher.StartTime.ToUniversalTime().ToString('o')
      startedAt = (Get-Date).ToString('o')
    }
    $output = (& (Join-Path $RepoRoot 'scripts\install-dream-skin.ps1') -Port 19335 -NoShortcuts -NoAutoRecover | Out-String)
    $watcher.Refresh()
    Assert-True -Condition $watcher.HasExited -Message 'NoAutoRecover did not stop the verified old watcher.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $watcherStatePath)) -Message 'NoAutoRecover retained safely discardable watcher state.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $startupShortcut)) -Message 'NoAutoRecover left the Startup shortcut installed.'
    Assert-True -Condition ($output -like '*Auto-recovery disabled; the recorded watcher was stopped and the Startup shortcut was removed.*') -Message 'Install did not report the disabled auto-recovery state.'
  }

  Invoke-SelfTest 'restore continues uninstall and config restore after live removal fails, then exits nonzero' {
    Reset-StateRoot
    $statePath = Join-Path $StateRoot 'state.json'
    Write-TestJson -LiteralPath $statePath -Value @{
      schemaVersion = 2
      component = 'injector'
      injectorPid = $PID
      port = 19335
      scriptPath = Join-Path $RepoRoot 'scripts\injector.mjs'
      executablePath = $NodePath
      skillRoot = $RepoRoot
      processStartTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
      startedAt = (Get-Date).ToString('o')
    }
    Write-TestFile -LiteralPath $ConfigPath -Content @'
[desktop]
appearanceTheme = "light"
appearanceLightCodeThemeId = "codex"
appearanceLightChromeTheme = { accent = "#B65CFF" }
'@
    $backupPath = Join-Path $StateRoot 'config.before-dream-skin.toml'
    Write-TestFile -LiteralPath $backupPath -Content @'
[desktop]
appearanceTheme = "dark"
appearanceLightCodeThemeId = "one-dark"
appearanceLightChromeTheme = { accent = "#000000" }
'@
    $desktop = [Environment]::GetFolderPath('Desktop')
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $restoreArtifacts = @(
      (Join-Path $desktop 'Codex Dream Skin.lnk'),
      (Join-Path $desktop 'Codex Dream Skin - Restore.lnk'),
      (Join-Path $startMenu 'Codex Dream Skin.lnk'),
      (Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Dream Skin Watcher.lnk')
    )
    foreach ($artifact in $restoreArtifacts) { New-ExternalArtifact -LiteralPath $artifact }

    $stdoutPath = Join-Path $Sandbox 'restore.stdout.log'
    $stderrPath = Join-Path $Sandbox 'restore.stderr.log'
    try {
      $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
      $restoreProcess = Start-Process -FilePath $PowerShellPath -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        "`"$(Join-Path $RepoRoot 'scripts\restore-dream-skin.ps1')`"",
        '-Port', '19335', '-Uninstall', '-RestoreBaseTheme'
      ) -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    } finally {
      $env:PATH = $OriginalPath
    }
    Assert-Equal -Expected 1 -Actual $restoreProcess.ExitCode -Message 'A failed live removal must produce a nonzero restore result.'
    foreach ($artifact in $restoreArtifacts) {
      Assert-True -Condition (-not (Test-Path -LiteralPath $artifact)) -Message "Restore skipped shortcut uninstall after live failure: $artifact"
    }
    $restoredConfig = [System.IO.File]::ReadAllText($ConfigPath)
    Assert-True -Condition ($restoredConfig -match 'appearanceTheme\s*=\s*"dark"') -Message 'Restore skipped appearanceTheme recovery after live failure.'
    Assert-True -Condition ($restoredConfig -match 'appearanceLightCodeThemeId\s*=\s*"one-dark"') -Message 'Restore skipped code-theme recovery after live failure.'
    Assert-True -Condition ($restoredConfig -match 'accent\s*=\s*"#000000"') -Message 'Restore skipped chrome-theme recovery after live failure.'
    Assert-True -Condition (-not (Test-Path -LiteralPath $backupPath)) -Message 'A successful config restore did not consume its backup.'
    Assert-True -Condition (Test-Path -LiteralPath $statePath) -Message 'Restore deleted injector state whose ownership failed.'
    $combinedOutput = ([System.IO.File]::ReadAllText($stdoutPath) + [System.IO.File]::ReadAllText($stderrPath))
    Assert-True -Condition ($combinedOutput -like '*Requested independent local phases were still attempted*') -Message 'Restore did not report its truthful partial-failure summary.'
  }
} finally {
  $env:PATH = $OriginalPath
  $env:LOCALAPPDATA = $OriginalLocalAppData
  $env:APPDATA = $OriginalAppData
  foreach ($process in $Children) {
    try {
      $process.Refresh()
      if (-not $process.HasExited) {
        $process.Kill()
        [void]$process.WaitForExit(5000)
      }
      $process.Dispose()
    } catch {}
  }
  foreach ($artifact in $ExternalArtifacts) {
    try {
      if (Test-Path -LiteralPath $artifact) { Remove-Item -LiteralPath $artifact -Force }
    } catch {}
  }
  try {
    if ($OriginalConfigExists) {
      [System.IO.File]::WriteAllBytes($ConfigPath, $OriginalConfigBytes)
    } elseif (Test-Path -LiteralPath $ConfigPath) {
      Remove-Item -LiteralPath $ConfigPath -Force
    }
    if (-not $ConfigDirectoryExisted -and (Test-Path -LiteralPath $ConfigDirectory)) {
      $remaining = @(Get-ChildItem -LiteralPath $ConfigDirectory -Force)
      if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $ConfigDirectory -Force }
    }
  } catch {}
  try {
    if (Test-Path -LiteralPath $Sandbox) { Remove-Item -LiteralPath $Sandbox -Recurse -Force }
  } catch {}
}

if ($Failures.Count -gt 0) {
  Write-Host "Windows PowerShell 5.1 selftest failed ($($Failures.Count) test group(s)):" -ForegroundColor Red
  foreach ($failure in $Failures) { Write-Host "  $failure" -ForegroundColor Red }
  exit 1
}

Write-Host 'Windows PowerShell 5.1 selftest passed.' -ForegroundColor Green
exit 0
