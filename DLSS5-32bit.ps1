#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Prepare','Install','Status','Enable','Disable','Mode','HostTest','Launch','CollectLogs')][string]$Action='Status',
    [string]$GameExe,
    [ValidateSet('Auto','D3D10','D3D11')][string]$Api='Auto',
    [string]$PackageDirectory,
    [string]$CacheDirectory,
    [string]$StateRoot,
    [ValidateSet('Plain','Depth','Transport','Neural')][string]$Mode='Neural',
    [ValidateSet(-1,0,1)][int]$DepthReversed=-1,
    [string]$SteamExe,
    [switch]$Offline,
    [switch]$UseCachedHostTest,
    [switch]$Json
)
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
if (-not $PackageDirectory) { $PackageDirectory=Join-Path $repository '.local\generic-package' }
if (-not $CacheDirectory) { $CacheDirectory=Join-Path $repository '.cache\downloads' }
if (-not $StateRoot) { $StateRoot=Join-Path $env:LOCALAPPDATA 'DLSS5-32bit\installations' }
Import-Module (Join-Path $repository 'lib\DLSS5Toolkit.psm1') -Force -DisableNameChecking
try {
    if ($Action -eq 'Prepare') {
        $package=New-PreparedPackage $repository $PackageDirectory $CacheDirectory -Offline:$Offline
        Write-Host "Prepared $($package.files.Count) verified files. No game files changed."
        exit 0
    }
    $preferences=Get-ContainedPath $StateRoot 'preferences.json'
    if (-not $GameExe -and (Test-Path -LiteralPath $preferences)) {
        $saved=Get-Content -LiteralPath $preferences -Raw | ConvertFrom-Json
        $GameExe=$saved.gameExe
        if ($Api -eq 'Auto') { $Api=$saved.api }
    }
    $target=Get-GameTarget $GameExe -Api $Api
    $installation=Get-InstallationDirectory $StateRoot $target.directory
    if ((Test-Path -LiteralPath (Join-Path $installation 'installation.json')) -and
        (Read-Installation $installation).gameExe -ine $target.exe) { throw 'A different executable in this folder owns the installation. Select that executable.' }
    $result=switch ($Action) {
        'Install' { Install-ParkedPackage $PackageDirectory $target $installation }
        'Status' { Get-ToolkitStatus $target $installation }
        'Enable' { Set-InstallationEnabled $installation $true }
        'Disable' { Set-InstallationEnabled $installation $false }
        'Mode' { Set-ProfileMode $installation $Mode -DepthReversed $DepthReversed }
        'HostTest' { Invoke-HostTest $installation -UseCache:$UseCachedHostTest }
        'Launch' { Start-SelectedGame $installation -SteamExe $SteamExe }
        'CollectLogs' {
            $state=Read-Installation $installation
            $root=if ($state.status -eq 'enabled') { $target.directory } else { Join-Path $installation 'parked' }
            $out=Get-ContainedPath $installation ('reports/'+[guid]::NewGuid().ToString('N'))
            Copy-SessionLogs $root $out -GameLogRoot $target.directory
            [pscustomobject]@{localReport=$out;uploaded=$false}
        }
    }
    if ($Json -or $Action -in @('Status','HostTest','CollectLogs')) { $result | ConvertTo-Json -Depth 10 }
    elseif ($result) { Write-Host "DLSS5: $($result.status), mode $($result.mode)." }
    if ($Action -eq 'HostTest' -and -not $result.passed) { exit 2 }
} catch { Write-Error $_ -ErrorAction Continue; exit 1 }
