function Get-AtomicTempPath {
  param([Parameter(Mandatory)][string]$LiteralPath)

  $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
  $directory = [System.IO.Path]::GetDirectoryName($fullPath)
  if (-not [System.IO.Directory]::Exists($directory)) {
    [void][System.IO.Directory]::CreateDirectory($directory)
  }
  $fileName = [System.IO.Path]::GetFileName($fullPath)
  return Join-Path $directory ".$fileName.$PID.$([guid]::NewGuid().ToString('N')).tmp"
}

function Complete-AtomicFileWrite {
  param(
    [Parameter(Mandatory)][string]$TempPath,
    [Parameter(Mandatory)][string]$LiteralPath
  )

  $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
  if ([System.IO.File]::Exists($fullPath)) {
    [void][System.IO.File]::Replace($TempPath, $fullPath, $null)
  } else {
    [System.IO.File]::Move($TempPath, $fullPath)
  }
}

function Write-AtomicUtf8File {
  param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Content
  )

  $tempPath = Get-AtomicTempPath -LiteralPath $LiteralPath
  try {
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempPath, $Content, $utf8WithoutBom)
    Complete-AtomicFileWrite -TempPath $tempPath -LiteralPath $LiteralPath
  } finally {
    if ([System.IO.File]::Exists($tempPath)) {
      [System.IO.File]::Delete($tempPath)
    }
  }
}

function Copy-FileAtomically {
  param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$DestinationPath
  )

  $tempPath = Get-AtomicTempPath -LiteralPath $DestinationPath
  try {
    [System.IO.File]::Copy([System.IO.Path]::GetFullPath($SourcePath), $tempPath, $false)
    Complete-AtomicFileWrite -TempPath $tempPath -LiteralPath $DestinationPath
  } finally {
    if ([System.IO.File]::Exists($tempPath)) {
      [System.IO.File]::Delete($tempPath)
    }
  }
}
