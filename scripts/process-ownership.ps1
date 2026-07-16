$script:CodexAutoSkinOwnershipCache = @{}

function Test-RecordedProcessOwnership {
  param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][string]$ExpectedScriptPath
  )

  if ($ProcessId -le 0) { return $false }
  $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $process) { return $false }
  try {
    $expectedPath = [System.IO.Path]::GetFullPath($ExpectedScriptPath)
    $cacheKey = "$ProcessId|$($process.StartTime.ToUniversalTime().Ticks)|$expectedPath"
    if ($script:CodexAutoSkinOwnershipCache.ContainsKey($cacheKey)) { return $true }
    $processInfo = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
    if (-not $processInfo.CommandLine) { return $false }
    $owned = $processInfo.CommandLine.IndexOf($expectedPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    if ($owned) { $script:CodexAutoSkinOwnershipCache[$cacheKey] = $true }
    return $owned
  } catch {
    return $false
  }
}

function Stop-RecordedProcess {
  param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][string]$ExpectedScriptPath,
    [string]$Description = 'recorded process'
  )

  $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $process) { return $false }
  if (-not (Test-RecordedProcessOwnership -ProcessId $ProcessId -ExpectedScriptPath $ExpectedScriptPath)) {
    Write-Warning "Refusing to stop PID $ProcessId because it is not the expected AutoSkin $Description process."
    return $false
  }
  Stop-Process -Id $ProcessId -Force -ErrorAction Stop
  return $true
}
