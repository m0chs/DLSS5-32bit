#requires -Version 5.1
param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'lib\DLSS5Toolkit.psm1') -Force -DisableNameChecking
$info=Get-Content -LiteralPath (Join-Path $repo 'toolkit.json') -Raw | ConvertFrom-Json
if (-not $OutputPath) { $OutputPath = Join-Path $repo ('.local\releases\DLSS5-32bit-'+$info.version+'.zip') }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { throw 'Release archive already exists; use a new -OutputPath.' }
$sources = Get-Content -LiteralPath (Join-Path $repo 'release-files.json') -Raw | ConvertFrom-Json
if ($sources -isnot [array] -or $sources.Count -eq 0) { throw 'The release allowlist must be a nonempty JSON array.' }
$files = @()
foreach ($relative in $sources) {
    $path = Get-ContainedPath $repo $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release allowlist must name an existing file: $relative" }
    $files += Get-Item -LiteralPath $path -Force
}
foreach ($file in $files) {
    if ($file.Extension -notin @('.ps1','.psm1','.cmd','.json','.md','.ini','.cfg','.yml','.txt','') -and $file.Name -notin @('.gitignore','.gitattributes')) {
        throw "Unapproved source-release file: $($file.Name)"
    }
    if ($file.Length -gt 1MB) { throw "Oversized source file: $($file.Name)" }
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputPath)) | Out-Null
$zip = [IO.Compression.ZipFile]::Open($OutputPath,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($repo.TrimEnd('\').Length+1).Replace('\','/')
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$file.FullName,('DLSS5-32bit/'+$relative))
    }
} finally { $zip.Dispose() }
$zip = [IO.Compression.ZipFile]::OpenRead($OutputPath)
try {
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName -match '(?i)\.(dll|exe|addon32|addon64|log|dmp|ff|iwd)$|/(\.cache|\.local|\.work|players)/') {
            throw "Forbidden release content: $($entry.FullName)"
        }
    }
    Write-Host "Source-only release: $OutputPath ($($zip.Entries.Count) entries)"
} finally { $zip.Dispose() }
Write-Host ('SHA-256: ' + (Get-Sha256 $OutputPath))
