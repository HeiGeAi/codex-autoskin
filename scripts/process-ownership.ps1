if (-not ('CodexAutoSkin.NativeCommandLine' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexAutoSkin {
  public static class NativeCommandLine {
    [DllImport("shell32.dll", SetLastError = true)]
    public static extern IntPtr CommandLineToArgvW(
      [MarshalAs(UnmanagedType.LPWStr)] string commandLine,
      out int argumentCount);

    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr memory);
  }
}
'@
}

function New-ProcessOwnershipResult {
  param(
    [Parameter(Mandatory)][bool]$Success,
    [Parameter(Mandatory)][string]$Status,
    [Parameter(Mandatory)][string]$Message,
    [bool]$Owned = $false,
    [bool]$CanDiscardState = $false,
    [System.Diagnostics.Process]$Process = $null
  )

  return [pscustomobject]@{
    Success = $Success
    Status = $Status
    Message = $Message
    Owned = $Owned
    CanDiscardState = $CanDiscardState
    Process = $Process
  }
}

function ConvertTo-NormalizedProcessPath {
  param([Parameter(Mandatory)][string]$LiteralPath)

  if ([string]::IsNullOrWhiteSpace($LiteralPath)) { throw 'A process path was empty.' }
  return [System.IO.Path]::GetFullPath($LiteralPath)
}

function ConvertFrom-WindowsCommandLine {
  param([Parameter(Mandatory)][string]$CommandLine)

  $argumentCount = 0
  $argumentsPointer = [CodexAutoSkin.NativeCommandLine]::CommandLineToArgvW($CommandLine, [ref]$argumentCount)
  if ($argumentsPointer -eq [IntPtr]::Zero) {
    throw "CommandLineToArgvW failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
  }
  try {
    $arguments = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $argumentCount; $index++) {
      $itemPointer = [Runtime.InteropServices.Marshal]::ReadIntPtr(
        $argumentsPointer,
        $index * [IntPtr]::Size
      )
      $arguments.Add([Runtime.InteropServices.Marshal]::PtrToStringUni($itemPointer))
    }
    return $arguments.ToArray()
  } finally {
    [void][CodexAutoSkin.NativeCommandLine]::LocalFree($argumentsPointer)
  }
}

function Resolve-RecordedScriptPath {
  param(
    [Parameter(Mandatory)][object]$State,
    [Parameter(Mandatory)][string]$ExpectedLeafName,
    [Parameter(Mandatory)][string]$RelativePathFromSkillRoot,
    [Parameter(Mandatory)][string]$FallbackPath
  )

  $hasScriptPath = $null -ne $State.PSObject.Properties['scriptPath']
  $hasSkillRoot = $null -ne $State.PSObject.Properties['skillRoot']
  $candidate = $null
  if ($hasScriptPath) {
    if ([string]::IsNullOrWhiteSpace([string]$State.scriptPath)) {
      throw 'Recorded process scriptPath is present but empty.'
    }
    $candidate = [string]$State.scriptPath
  } elseif ($hasSkillRoot) {
    if ([string]::IsNullOrWhiteSpace([string]$State.skillRoot)) {
      throw 'Recorded process skillRoot is present but empty.'
    }
    $candidate = Join-Path ([string]$State.skillRoot) $RelativePathFromSkillRoot
  } else {
    $candidate = $FallbackPath
  }
  if (-not [System.IO.Path]::IsPathRooted($candidate)) {
    throw "Recorded process script path is not absolute: $candidate"
  }
  $normalized = ConvertTo-NormalizedProcessPath -LiteralPath $candidate
  if (-not [string]::Equals(
      [System.IO.Path]::GetFileName($normalized),
      $ExpectedLeafName,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Recorded process script is not ${ExpectedLeafName}: $normalized"
  }
  if ($hasScriptPath -and $hasSkillRoot) {
    if (-not [System.IO.Path]::IsPathRooted([string]$State.skillRoot)) {
      throw "Recorded process skillRoot is not absolute: $($State.skillRoot)"
    }
    $rootDerived = ConvertTo-NormalizedProcessPath -LiteralPath (Join-Path ([string]$State.skillRoot) $RelativePathFromSkillRoot)
    if (-not [string]::Equals($normalized, $rootDerived, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw 'Recorded process scriptPath is inconsistent with skillRoot.'
    }
  }
  return $normalized
}

function Resolve-RecordedExecutablePath {
  param(
    [Parameter(Mandatory)][object]$State,
    [Parameter(Mandatory)][string]$FallbackPath
  )

  $hasExecutablePath = $null -ne $State.PSObject.Properties['executablePath']
  if ($hasExecutablePath -and [string]::IsNullOrWhiteSpace([string]$State.executablePath)) {
    throw 'Recorded process executablePath is present but empty.'
  }
  $candidate = if ($hasExecutablePath) { [string]$State.executablePath } else { $FallbackPath }
  if (-not [System.IO.Path]::IsPathRooted($candidate)) {
    throw "Recorded process executable path is not absolute: $candidate"
  }
  return ConvertTo-NormalizedProcessPath -LiteralPath $candidate
}

function Get-RecordedProcessOwnership {
  param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][string]$ExpectedScriptPath,
    [Parameter(Mandatory)][string]$ExpectedExecutablePath,
    [Parameter(Mandatory)][ValidateSet('NodeEntryPoint', 'PowerShellFile')][string]$ScriptArgumentMode,
    [string]$ExpectedProcessStartTimeUtc
  )

  if ($ProcessId -le 0) {
    return New-ProcessOwnershipResult -Success $false -Status 'invalid-state' -Message "Recorded PID $ProcessId is invalid."
  }
  try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
  } catch {
    if ($_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId*') {
      return New-ProcessOwnershipResult -Success $true -Status 'not-running' -Message "Recorded PID $ProcessId is not running." -CanDiscardState $true
    }
    return New-ProcessOwnershipResult -Success $false -Status 'inspection-failed' -Message "Could not inspect recorded PID ${ProcessId}: $($_.Exception.Message)"
  }

  $expectedStartTimeUtc = $null
  try {
    $expectedScript = ConvertTo-NormalizedProcessPath -LiteralPath $ExpectedScriptPath
    $expectedExecutable = ConvertTo-NormalizedProcessPath -LiteralPath $ExpectedExecutablePath
    if (-not [string]::IsNullOrWhiteSpace($ExpectedProcessStartTimeUtc)) {
      $expectedStartTimeUtc = [datetime]::Parse(
        $ExpectedProcessStartTimeUtc,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
      ).ToUniversalTime()
    }
  } catch {
    return New-ProcessOwnershipResult -Success $false -Status 'invalid-state' -Message "Recorded ownership metadata is invalid: $($_.Exception.Message)"
  }

  try {
    # Force the Process object to open and retain its OS handle before ownership
    # inspection. Stop-RecordedProcess later kills through this verified object,
    # rather than reopening an arbitrary process by a potentially reused PID.
    [void]$process.Handle
    $actualStartTimeUtc = $process.StartTime.ToUniversalTime()
    if ($null -ne $expectedStartTimeUtc) {
      if ($actualStartTimeUtc.Ticks -ne $expectedStartTimeUtc.Ticks) {
        return New-ProcessOwnershipResult -Success $false -Status 'ownership-failed' -Message "PID $ProcessId start time does not match the recorded AutoSkin process."
      }
    }
    $processInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
    if (-not $processInfo -or -not $processInfo.ExecutablePath -or -not $processInfo.CommandLine) {
      throw 'Win32_Process did not expose both ExecutablePath and CommandLine.'
    }
  } catch {
    try { $process.Refresh() } catch {}
    if ($process.HasExited) {
      return New-ProcessOwnershipResult -Success $true -Status 'not-running' -Message "Recorded PID $ProcessId exited during ownership inspection." -CanDiscardState $true
    }
    return New-ProcessOwnershipResult -Success $false -Status 'inspection-failed' -Message "Could not inspect PID ${ProcessId}: $($_.Exception.Message)"
  }

  try {
    $actualExecutable = ConvertTo-NormalizedProcessPath -LiteralPath ([string]$processInfo.ExecutablePath)
    if (-not [string]::Equals($actualExecutable, $expectedExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
      return New-ProcessOwnershipResult -Success $false -Status 'ownership-failed' -Message "PID $ProcessId executable does not match the recorded AutoSkin executable."
    }

    $arguments = ConvertFrom-WindowsCommandLine -CommandLine ([string]$processInfo.CommandLine)
    $scriptArgument = $null
    if ($ScriptArgumentMode -eq 'NodeEntryPoint') {
      if ($arguments.Count -lt 2) {
        return New-ProcessOwnershipResult -Success $false -Status 'ownership-failed' -Message "PID $ProcessId Node command line has no entry-point argument."
      }
      $scriptArgument = [string]$arguments[1]
    } elseif ($ScriptArgumentMode -eq 'PowerShellFile') {
      $fileIndex = -1
      for ($index = 1; $index -lt $arguments.Count; $index++) {
        if ([string]::Equals([string]$arguments[$index], '-File', [System.StringComparison]::OrdinalIgnoreCase)) {
          if ($fileIndex -ge 0) {
            return New-ProcessOwnershipResult -Success $false -Status 'ownership-failed' -Message "PID $ProcessId PowerShell command line has more than one -File argument."
          }
          $fileIndex = $index
        }
      }
      if ($fileIndex -lt 1 -or $fileIndex -ge ($arguments.Count - 1)) {
        return New-ProcessOwnershipResult -Success $false -Status 'ownership-failed' -Message "PID $ProcessId PowerShell command line has no script token immediately after -File."
      }
      $scriptArgument = [string]$arguments[$fileIndex + 1]
    }
    if (-not [System.IO.Path]::IsPathRooted($scriptArgument)) {
      return New-ProcessOwnershipResult -Success $false -Status 'ownership-failed' -Message "PID $ProcessId script argument is not an absolute path."
    }
    try {
      $argumentPath = ConvertTo-NormalizedProcessPath -LiteralPath $scriptArgument
    } catch {
      return New-ProcessOwnershipResult -Success $false -Status 'ownership-failed' -Message "PID $ProcessId script argument is not a valid path."
    }
    if (-not [string]::Equals($argumentPath, $expectedScript, [System.StringComparison]::OrdinalIgnoreCase)) {
      return New-ProcessOwnershipResult -Success $false -Status 'ownership-failed' -Message "PID $ProcessId script argument does not exactly match the recorded AutoSkin script."
    }
    return New-ProcessOwnershipResult -Success $true -Status 'owned' -Message "Recorded PID $ProcessId ownership was verified." -Owned $true -Process $process
  } catch {
    return New-ProcessOwnershipResult -Success $false -Status 'inspection-failed' -Message "Could not parse PID $ProcessId command line: $($_.Exception.Message)"
  }
}

function Test-RecordedProcessOwnership {
  param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][string]$ExpectedScriptPath,
    [Parameter(Mandatory)][string]$ExpectedExecutablePath,
    [Parameter(Mandatory)][ValidateSet('NodeEntryPoint', 'PowerShellFile')][string]$ScriptArgumentMode,
    [string]$ExpectedProcessStartTimeUtc
  )

  $result = Get-RecordedProcessOwnership -ProcessId $ProcessId -ExpectedScriptPath $ExpectedScriptPath -ExpectedExecutablePath $ExpectedExecutablePath -ScriptArgumentMode $ScriptArgumentMode -ExpectedProcessStartTimeUtc $ExpectedProcessStartTimeUtc
  return $result.Status -eq 'owned'
}

function Stop-RecordedProcess {
  param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][string]$ExpectedScriptPath,
    [Parameter(Mandatory)][string]$ExpectedExecutablePath,
    [Parameter(Mandatory)][ValidateSet('NodeEntryPoint', 'PowerShellFile')][string]$ScriptArgumentMode,
    [string]$ExpectedProcessStartTimeUtc,
    [string]$Description = 'recorded process'
  )

  $ownership = Get-RecordedProcessOwnership -ProcessId $ProcessId -ExpectedScriptPath $ExpectedScriptPath -ExpectedExecutablePath $ExpectedExecutablePath -ScriptArgumentMode $ScriptArgumentMode -ExpectedProcessStartTimeUtc $ExpectedProcessStartTimeUtc
  if ($ownership.Status -eq 'not-running') { return $ownership }
  if (-not $ownership.Success) {
    Write-Warning "Refusing to stop AutoSkin $Description. $($ownership.Message)"
    return $ownership
  }
  try {
    $ownership.Process.Kill()
    if (-not $ownership.Process.WaitForExit(5000)) {
      return New-ProcessOwnershipResult -Success $false -Status 'stop-failed' -Message "Timed out waiting for AutoSkin $Description PID $ProcessId to exit." -Owned $true -Process $ownership.Process
    }
    return New-ProcessOwnershipResult -Success $true -Status 'stopped' -Message "AutoSkin $Description PID $ProcessId was stopped." -Owned $true -CanDiscardState $true
  } catch {
    try { $ownership.Process.Refresh() } catch {}
    if ($ownership.Process.HasExited) {
      return New-ProcessOwnershipResult -Success $true -Status 'not-running' -Message "AutoSkin $Description PID $ProcessId exited before it could be stopped." -CanDiscardState $true
    }
    return New-ProcessOwnershipResult -Success $false -Status 'stop-failed' -Message "Failed to stop AutoSkin $Description PID ${ProcessId}: $($_.Exception.Message)" -Owned $true -Process $ownership.Process
  }
}
