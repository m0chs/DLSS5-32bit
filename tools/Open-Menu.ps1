#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Menu','Setup','Play','Check','Disable','Enable')][string]$Action='Menu',
    [string]$GameExe,
    [ValidateSet('Auto','D3D10','D3D11')][string]$Api='Auto',
    [string]$StateRoot,
    [string]$PackageDirectory,
    [string]$CacheDirectory,
    [switch]$Offline,
    [switch]$NonInteractive
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repository 'lib\DLSS5Toolkit.psm1') -Force -DisableNameChecking
$info=Get-Content -LiteralPath (Join-Path $repository 'toolkit.json') -Raw | ConvertFrom-Json
if (-not $StateRoot) { $StateRoot=Join-Path $env:LOCALAPPDATA 'DLSS5-32bit\installations' }
if (-not $PackageDirectory) { $PackageDirectory=Join-Path $repository '.local\generic-package' }
if (-not $CacheDirectory) { $CacheDirectory=Join-Path $repository '.cache\downloads' }
$preferencesPath=Get-ContainedPath $StateRoot 'preferences.json'
if (-not $GameExe -and (Test-Path -LiteralPath $preferencesPath)) {
    try {
        $saved=Get-Content -LiteralPath $preferencesPath -Raw | ConvertFrom-Json
        $GameExe=$saved.gameExe
        if ($Api -eq 'Auto') { $Api=$saved.api }
    }
    catch { $GameExe=$null }
}

function Select-GameExecutable {
    param([switch]$Ask)
    if ($Ask -and $NonInteractive) { throw 'Pass -GameExe for noninteractive use.' }
    if ($Ask) { $script:GameExe=(Read-Host 'Paste the full path to the actual 32-bit game .exe').Trim().Trim('"'); $script:Api='Auto' }
    try { $script:target=Get-GameTarget $script:GameExe -Api $script:Api }
    catch {
        if ($NonInteractive -or $Ask) { throw }
        Write-Host $_.Exception.Message
        $script:GameExe=(Read-Host 'Paste the full path to the actual 32-bit game .exe').Trim().Trim('"')
        $script:target=Get-GameTarget $script:GameExe -Api $script:Api
    }
    $script:GameExe=$script:target.exe
    Write-JsonFile $preferencesPath ([pscustomobject]@{gameExe=$script:GameExe;api=$script:target.api})
    return (Get-InstallationDirectory $StateRoot $script:target.directory)
}

function Invoke-MenuAction {
    param([string]$Choice)
    $installation=Select-GameExecutable
    $manifest=Join-Path $installation 'installation.json'
    switch ($Choice) {
        'Setup' {
            Assert-GameClosed $script:target.directory
            if (Test-Path -LiteralPath $manifest) {
                $status=Get-ToolkitStatus $script:target $installation
                if ((Read-Installation $installation).gameExe -ine $script:target.exe) { throw 'Another executable in this folder owns the existing setup. Select that executable or disable its setup first.' }
                $bad=@($status.files | Where-Object { -not $_.exists -or $_.hashMatches -eq $false })
                if ($status.state -eq 'moving' -or $bad.Count) { throw 'An existing setup needs attention. Choose Check setup; your files have been preserved.' }
                Write-Host "Already set up ($($status.state)). Your existing settings are preserved. Choose Play game."
                return
            }
            Write-Host 'Preparing the pinned components. The game folder will remain unchanged until Play.'
            $null=New-PreparedPackage $repository $PackageDirectory $CacheDirectory -Offline:$Offline
            $null=Install-ParkedPackage $PackageDirectory $script:target $installation
            Write-Host 'Setup complete. Choose Play game when ready.'
        }
        'Play' {
            if (-not (Test-Path -LiteralPath $manifest)) { throw 'Choose Set up first.' }
            if ((Read-Installation $installation).gameExe -ine $script:target.exe) { throw 'The existing setup belongs to another executable in this folder. Choose its original executable.' }
            Write-Host 'Offline single-player only. Keep your store launcher running if the game needs it.'
            $test=Invoke-HostTest $installation -UseCache
            if (-not $test.passed) { throw "The neural host test did not pass. Game launch stopped. Logs: $($test.reportDirectory)" }
            Start-SelectedGame $installation
        }
        'Check' {
            $status=Get-ToolkitStatus $script:target $installation
            Write-Host "`nGame: $($status.gameDirectory)"
            Write-Host "Setup: $($status.state)"
            if ($status.files.Count) {
                $bad=@($status.files | Where-Object { -not $_.exists -or $_.hashMatches -eq $false })
                Write-Host "Files: $($status.files.Count - $bad.Count)/$($status.files.Count) present and valid (editable settings may differ)."
                foreach ($file in $bad) { Write-Host "  Check: $($file.path)" }
            }
            Write-Host "Latest game log: frames delivered = $($status.evidence.frameDelivered)"
            Write-Host "Latest host log: neural evaluation = $($status.evidence.neuralEvaluationSucceeded)"
            Write-Host 'These are past log observations, not live image-quality checks.'
            $report=Get-ContainedPath $installation ('reports/check-'+[guid]::NewGuid().ToString('N')+'.json')
            Write-JsonFile $report $status
            Write-Host "Full local report: $report"
            Write-Host 'No report was uploaded.'
        }
        'Disable' {
            if (-not (Test-Path -LiteralPath $manifest)) { Write-Host 'No installation is registered for this folder.'; return }
            $null=Set-InstallationEnabled $installation $false
            Write-Host 'Mod disabled. Its files are parked outside the game folder.'
        }
        'Enable' {
            if (-not (Test-Path -LiteralPath $manifest)) { throw 'Choose Set up first.' }
            if ((Read-Installation $installation).gameExe -ine $script:target.exe) { throw 'The existing setup belongs to another executable in this folder.' }
            $test=Invoke-HostTest $installation -UseCache
            if (-not $test.passed) { throw "The neural host test did not pass. Logs: $($test.reportDirectory)" }
            $null=Set-InstallationEnabled $installation $true
            Write-Host 'Mod enabled. Launch the selected game through its store launcher.'
            Write-Host 'Choose Disable mod after exiting. Manual launch does not automatically disable the mod.'
        }
    }
}

try {
    if ($Action -ne 'Menu') { Invoke-MenuAction $Action; exit 0 }
    if ($NonInteractive) { throw 'Choose -Action Setup, Play, Check or Disable for noninteractive use.' }
    while ($true) {
        Write-Host "`nDLSS5 for 32-bit games - $($info.version)"
        Write-Host 'DirectX 10/11 | Offline single-player | Experimental'
        Write-Host ''
        Write-Host '  1  Set up'
        Write-Host '  2  Play game'
        Write-Host '  3  Check setup'
        Write-Host '  4  Disable mod'
        Write-Host '  5  Choose game executable'
        Write-Host '  6  Enable only (use your store launcher)'
        Write-Host '  0  Exit'
        $choice=Read-Host 'Choose a number'
        if ($choice -eq '0') { break }
        try {
            switch ($choice) {
                '1' { Invoke-MenuAction Setup }
                '2' { Invoke-MenuAction Play }
                '3' { Invoke-MenuAction Check }
                '4' { Invoke-MenuAction Disable }
                '5' { $null=Select-GameExecutable -Ask; Write-Host 'Game selection saved.' }
                '6' { Invoke-MenuAction Enable }
                default { Write-Host 'Enter a number from 0 to 6.'; continue }
            }
        } catch { Write-Host "`n$($_.Exception.Message)" -ForegroundColor Red }
        $null=Read-Host 'Press Enter to return to the menu'
    }
} catch { Write-Error $_ -ErrorAction Continue; exit 1 }
