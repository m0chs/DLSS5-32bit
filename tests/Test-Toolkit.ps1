#requires -Version 5.1
param([string]$TestRoot = (Join-Path $PSScriptRoot '..\.local\tests'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $repo 'lib\DLSS5Toolkit.psm1') -Force -DisableNameChecking
$runRoot = [IO.Path]::GetFullPath((Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))))
[IO.Directory]::CreateDirectory($runRoot) | Out-Null
$script:passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
function Assert-Throws([scriptblock]$Body, [string]$Message, [string]$Pattern='') {
    $didThrow = $false
    try { & $Body | Out-Null } catch {
        $didThrow = $true
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw "Wrong failure for ${Message}: $($_.Exception.Message)" }
    }
    Assert-True $didThrow $Message
}
function Write-FakePe([string]$Path, [int]$Machine=0x014C, [string[]]$Imports=@('d3d11.dll')) {
    $bytes = New-Object byte[] 2048
    $bytes[0]=0x4D; $bytes[1]=0x5A; $bytes[60]=128; $bytes[128]=0x50; $bytes[129]=0x45
    [BitConverter]::GetBytes([uint16]$Machine).CopyTo($bytes,132)
    [BitConverter]::GetBytes([uint16]1).CopyTo($bytes,134)
    [BitConverter]::GetBytes([uint16]224).CopyTo($bytes,148)
    [BitConverter]::GetBytes([uint16]0x10B).CopyTo($bytes,152)
    [BitConverter]::GetBytes([uint32]512).CopyTo($bytes,212)
    [BitConverter]::GetBytes([uint32]16).CopyTo($bytes,244)
    if ($Imports.Count) {
        [BitConverter]::GetBytes([uint32]4096).CopyTo($bytes,256)
        [BitConverter]::GetBytes([uint32](20*($Imports.Count+1))).CopyTo($bytes,260)
    }
    [BitConverter]::GetBytes([uint32]1024).CopyTo($bytes,384)
    [BitConverter]::GetBytes([uint32]4096).CopyTo($bytes,388)
    [BitConverter]::GetBytes([uint32]1024).CopyTo($bytes,392)
    [BitConverter]::GetBytes([uint32]512).CopyTo($bytes,396)
    for ($i=0;$i -lt $Imports.Count;$i++) {
        $nameOffset=800+$i*64
        [BitConverter]::GetBytes([uint32](4096+$nameOffset-512)).CopyTo($bytes,512+20*$i+12)
        [Text.Encoding]::ASCII.GetBytes($Imports[$i]).CopyTo($bytes,$nameOffset)
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllBytes($Path,$bytes)
}
function New-Fixture([string]$Name) {
    $base = Join-Path $runRoot $Name
    $game = Join-Path $base 'game with spaces'
    $package = Join-Path $base 'package'
    $install = Join-Path $base 'installation'
    [IO.Directory]::CreateDirectory($game) | Out-Null
    Write-FakePe (Join-Path $game 'ExampleGame.exe')
    Write-Utf8 (Join-Path $game 'zone\original.ff') 'Game data must survive.'
    $lock = Get-Content -LiteralPath (Join-Path $repo 'components.lock.json') -Raw | ConvertFrom-Json
    $files = @()
    foreach ($asset in $lock.assets) {
        foreach ($entry in $asset.entries) {
            $target = Get-ContainedPath (Join-Path $package 'payload') $entry.target
            if ($entry.PSObject.Properties['machine']) {
                $machine = if ($entry.machine -eq 'x86') { 0x014C } else { 0x8664 }
                Write-FakePe $target $machine
            } else { Write-Utf8 $target ('Fixture ' + $entry.target) }
            $files += [pscustomobject]@{path=$entry.target;sha256=(Get-Sha256 $target);mutable=$false;component=$asset.id}
        }
    }
    $profileHashes=@{}
    foreach ($name in @('ReShade.ini','DLSS5-32bit.ini','dlss5-feed.cfg','host-ReShade.ini')) {
        $relative = if ($name -eq 'host-ReShade.ini') { 'host64/ReShade.ini' } else { $name }
        $dest = Get-ContainedPath (Join-Path $package 'payload') $relative
        [IO.File]::Copy((Join-Path $repo "profiles\$name"),$dest)
        $profileHashes[$name]=Get-Sha256 $dest
        $files += [pscustomobject]@{path=$relative;sha256=(Get-Sha256 $dest);mutable=$true;component='profile'}
    }
    Write-JsonFile (Join-Path $package 'package.json') ([pscustomobject]@{schema=1;profile='test-fixture';lockSha256=(Get-Sha256 (Join-Path $repo 'components.lock.json'));profileHashes=$profileHashes;files=$files})
    $exe=Join-Path $game 'ExampleGame.exe'
    [pscustomobject]@{base=$base;game=$game;exe=$exe;target=(Get-GameTarget $exe);package=$package;install=$install}
}

$f = New-Fixture 'lifecycle'
Assert-True ((Get-PeMachine (Join-Path $f.game 'ExampleGame.exe')) -eq 'x86') 'Recognizes the x86 campaign PE header'
Assert-True ((Get-PeMachine (Join-Path $f.package 'payload\host64\dxgi.dll')) -eq 'x64') 'Recognizes the x64 host PE header'
Assert-True ($f.target.api -eq 'D3D11' -and -not $f.target.steamAppId) 'Accepts a general x86 D3D11 game without a BO2 dependency'
$dx10=Join-Path $f.base 'GameDX10.exe'
Write-FakePe $dx10 0x014C @('d3d10_1.dll')
Assert-True ((Get-GameTarget $dx10).api -eq 'D3D10') 'Detects a DirectX 10 import'
$dx9=Join-Path $f.base 'GameDX9.exe'
Write-FakePe $dx9 0x014C @('d3d9.dll')
Assert-Throws { Get-GameTarget $dx9 } 'Refuses an unautomated DX9 route' 'not automated'
$dynamic=Join-Path $f.base 'DynamicGame.exe'
Write-FakePe $dynamic 0x014C @()
Assert-Throws { Get-GameTarget $dynamic } 'Does not guess an API when static imports are absent' 'No DirectX'
Assert-True ((Get-GameTarget $dynamic -Api D3D11).api -eq 'D3D11') 'Allows an explicit API for a known dynamic-loading game'
$mp=Join-Path $f.base 't6mp.exe'
Write-FakePe $mp
Assert-Throws { Get-GameTarget $mp } 'Refuses the known BO2 multiplayer executable' 'online-game'
$badImport=Join-Path $f.base 'BadImport.exe'
Write-FakePe $badImport
$badBytes=[IO.File]::ReadAllBytes($badImport)
[BitConverter]::GetBytes([uint32]0x7FFFFFFF).CopyTo($badBytes,524)
[IO.File]::WriteAllBytes($badImport,$badBytes)
Assert-Throws { Get-PeImports $badImport } 'Rejects an import name RVA outside the PE image' 'PE RVA'
Assert-Throws { Get-ContainedPath $f.game '..\escape.dll' } 'Rejects traversal' 'Unsafe'
Assert-Throws { Get-ContainedPath $f.game 'C:\Windows\dxgi.dll' } 'Rejects rooted paths' 'Unsafe'
Assert-Throws { Get-ContainedPath $f.game 'dxgi.dll:stream' } 'Rejects alternate data streams' 'Unsafe'
$outside = Join-Path $f.base 'outside'
[IO.Directory]::CreateDirectory($outside) | Out-Null
$null = New-Item -ItemType Junction -Path (Join-Path $f.game 'linked') -Target $outside
Assert-Throws { Get-ContainedPath $f.game 'linked\proxy.dll' } 'Rejects junction escape' 'Reparse'
$before = Get-Sha256 (Join-Path $f.game 'ExampleGame.exe')
$installed = Install-ParkedPackage $f.package $f.target $f.install
Assert-True ($installed.status -eq 'disabled' -and -not (Test-Path (Join-Path $f.game 'dxgi.dll'))) 'Install parks the payload without modifying the game'
Assert-Throws { Install-ParkedPackage $f.package $f.target $f.install } 'Refuses to replace an existing installation' 'already exists'
$null = Set-ProfileMode $f.install Depth
$depthText = Get-Content (Join-Path $f.install 'parked\DLSS5-32bit.ini') -Raw
Assert-True ($depthText -match '(?m)^Techniques=DisplayDepth@DisplayDepth.fx') 'Depth mode selects only the depth view'
$null = Set-ProfileMode $f.install Transport
$cfg = Get-Content (Join-Path $f.install 'parked\dlss5-feed.cfg') -Raw
Assert-True ($cfg -match '(?m)^mode=1\r?$' -and $cfg -match '(?m)^enabled=1\r?$') 'Transport mode arms the split-frame round trip without NGX'
$null = Set-ProfileMode $f.install Neural -DepthReversed 1
Assert-True ((Get-Content (Join-Path $f.install 'parked\ReShade.ini') -Raw) -match 'RESHADE_DEPTH_INPUT_IS_REVERSED=1') 'Depth override reaches ReShade'
Assert-True ((Get-Content (Join-Path $f.install 'parked\DLSS5-32bit.ini') -Raw) -match '(?m)^PreprocessorDefinitions=DLSS5_MV_PROVIDER=3') 'Mode changes preserve per-effect motion-provider selection'
$null = Set-InstallationEnabled $f.install $true
Assert-True ((Test-Path (Join-Path $f.game 'dxgi.dll')) -and (Test-Path (Join-Path $f.game 'host64\nvngx_dlssnr.dll'))) 'Enable deploys both architecture halves'
Assert-True ((Read-Installation $f.install).status -eq 'enabled') 'Enable records committed state'
Write-Utf8 (Join-Path $f.game 'host64\user-note.txt') 'Keep custom notes.'
Set-IniValue (Join-Path $f.game 'dlss5-feed.cfg') '' 'work_resolution' '75'
$null = Set-InstallationEnabled $f.install $false
Assert-True (@(Get-InjectionConflicts $f.game).Count -eq 0) 'Disable physically removes owned graphics components'
Assert-True ((Get-Content (Join-Path $f.install 'parked\dlss5-feed.cfg') -Raw) -match 'work_resolution=75') 'Disable preserves configuration edits'
Assert-True (Test-Path (Join-Path $f.install 'parked\host64\user-note.txt')) 'Disable preserves additions inside the owned host folder'
$null = Set-InstallationEnabled $f.install $true
$null = Set-InstallationEnabled $f.install $false
Assert-True ((Get-Sha256 (Join-Path $f.game 'ExampleGame.exe')) -eq $before -and (Get-Content (Join-Path $f.game 'zone\original.ff')) -eq 'Game data must survive.') 'Repeated enable/disable leaves original game data intact'

$f = New-Fixture 'conflict'
Write-Utf8 (Join-Path $f.game 'dxgi.dll') 'Existing user mod'
Assert-Throws { Install-ParkedPackage $f.package $f.target $f.install } 'Install refuses a pre-existing proxy' 'preserved'
Assert-True ((Get-Content (Join-Path $f.game 'dxgi.dll')) -eq 'Existing user mod') 'A refused install preserves the existing proxy'
$f = New-Fixture 'enable-conflict'
$null = Install-ParkedPackage $f.package $f.target $f.install
Write-Utf8 (Join-Path $f.game 'host64\foreign.txt') 'Other mod'
Assert-Throws { Set-InstallationEnabled $f.install $true } 'Enable checks for newly added conflicting folders' 'overlap'
Assert-True ((Read-Installation $f.install).status -eq 'disabled') 'Preflight failures leave installation disabled'

$f = New-Fixture 'rollback'
$null = Install-ParkedPackage $f.package $f.target $f.install
$locked = [IO.File]::Open((Join-Path $f.install 'parked\dlss5-feed.cfg'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
try { Assert-Throws { Set-InstallationEnabled $f.install $true } 'A mid-move file lock triggers rollback' }
finally { $locked.Dispose() }
Assert-True ((Read-Installation $f.install).status -eq 'disabled' -and -not (Test-Path (Join-Path $f.game 'dlss5-feed.addon32'))) 'Rollback removes already moved components and restores state'
$null = Set-InstallationEnabled $f.install $true
$null = Set-InstallationEnabled $f.install $false
Assert-True ((Read-Installation $f.install).status -eq 'disabled') 'Installation remains usable after rollback'
Write-Utf8 (Join-Path $f.install 'parked\dlss5-feed.addon32') 'tampered'
Assert-Throws { Set-InstallationEnabled $f.install $true } 'Enable refuses a changed executable component' 'SHA-256 mismatch'

$missing=New-Fixture 'disable-missing-addon'
$null=Install-ParkedPackage $missing.package $missing.target $missing.install
$null=Set-InstallationEnabled $missing.install $true
$missingAddon=Get-ContainedPath $missing.game 'dlss5-feed.addon32'
Remove-Item -LiteralPath $missingAddon
$null=Set-InstallationEnabled $missing.install $false
Assert-True (-not (Test-Path (Join-Path $missing.game 'dxgi.dll')) -and (Read-Installation $missing.install).status -eq 'disabled') 'A missing add-on does not block removal of the proxy'

$f = New-Fixture 'bad-package'
Write-Utf8 (Join-Path $f.package 'payload\dxgi.dll') 'changed bytes'
Assert-Throws { Install-ParkedPackage $f.package $f.target $f.install } 'Install refuses a corrupted package' 'SHA-256 mismatch'
Assert-True (-not (Test-Path $f.install)) 'Package verification happens before installation writes'
$f = New-Fixture 'wrong-arch'
Write-FakePe (Join-Path $f.game 'ExampleGame.exe') 0x8664
Assert-Throws { Get-GameTarget $f.exe } 'Rejects a 64-bit executable' '32-bit'
$malformed = Join-Path $f.base 'malformed.exe'
Write-Utf8 $malformed 'not executable'
Assert-Throws { Get-PeMachine $malformed } 'Rejects malformed PE files' 'Not a PE'

$logs = Join-Path $runRoot 'log-evidence'
[IO.Directory]::CreateDirectory($logs) | Out-Null
$ev = Get-LogEvidence $logs
Assert-True (-not $ev.neuralEvaluationSucceeded -and -not $ev.hostTest300) 'Missing logs never count as success'
Write-Utf8 (Join-Path $logs 'host64\dlss5-feed-host.log') '[host] --test finished: 300/300 evaluates succeeded'
$ev = Get-LogEvidence $logs
Assert-True ($ev.hostTest300 -and -not $ev.neuralEvaluationSucceeded) '300 DLAA evaluations do not imply neural rendering'
Write-Utf8 (Join-Path $logs 'host64\ReShade.log') "feature 18 created`ninline feature 18 evaluation succeeded"
$ev = Get-LogEvidence $logs
Assert-True ($ev.hostTest300 -and $ev.neuralFeatureCreated -and $ev.neuralEvaluationSucceeded) 'Neural success needs distinct feature-18 log evidence'
Assert-True (-not $ev.visualABVerified -and -not $ev.gameplayStabilityVerified) 'Log success never claims visual quality or gameplay stability'
$old = [DateTime]::UtcNow.AddDays(-2)
(Get-Item (Join-Path $logs 'host64\ReShade.log')).LastWriteTimeUtc=$old
$ev = Get-LogEvidence $logs -Since ([DateTime]::UtcNow.AddMinutes(-1))
Assert-True (-not $ev.neuralFeatureCreated -and -not $ev.neuralEvaluationSucceeded) 'Stale success logs cannot pass a new host test'
Write-Utf8 (Join-Path $logs 'host64\ReShade.log') 'evaluate raised 0xC0000005 in D3D12Core.dll'
Assert-True (Get-LogEvidence $logs).runtimeFaultObserved 'Records a neural runtime fault'

$gameLogs = Join-Path $runRoot 'separate-game-logs'
Write-Utf8 (Join-Path $gameLogs 'ReShade.log') "ReShade (32-bit) loaded into ExampleGame.exe"
Write-Utf8 (Join-Path $gameLogs 'dlss5-feed.log') "[feed32] D3D11 multithread protection enabled`n[feed32] frame 3 delivered`nDLSS5_MV_PROVIDER=3 (LumeniteFX Kernel) -> Lumenite_Kernel (enabled)"
$ev = Get-LogEvidence $logs -GameLogRoot $gameLogs
Assert-True ($ev.reshade32Loaded -and $ev.d3d11DeviceObserved -and $ev.frameDelivered -and $ev.lumeniteSelected) 'Disabled diagnostics combine root game logs with the parked host logs'
$copy = Join-Path $runRoot 'collected-logs'
Copy-SessionLogs $logs $copy -GameLogRoot $gameLogs
Assert-True ((Test-Path (Join-Path $copy 'dlss5-feed.log')) -and (Test-Path (Join-Path $copy 'host64\ReShade.log'))) 'Log collection preserves both process sides after disabling'

# Exercise the real CLI entrypoint too; module-only tests cannot catch defaults
# that are evaluated before Windows PowerShell has initialized script variables.
$cliFixture = New-Fixture 'cli'
$cliState = Join-Path $cliFixture.base 'state'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'DLSS5-32bit.ps1') -Action Install -GameExe $cliFixture.exe -PackageDirectory $cliFixture.package -StateRoot $cliState | Out-Null
Assert-True ($LASTEXITCODE -eq 0) 'CLI Install works under Windows PowerShell 5.1'
$cliOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'DLSS5-32bit.ps1') -Action Status -GameExe $cliFixture.exe -StateRoot $cliState -Json
$cliStatus = $cliOutput | ConvertFrom-Json
Assert-True ($LASTEXITCODE -eq 0 -and $cliStatus.state -eq 'disabled') 'CLI Status discovers the parked install and emits JSON'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\Open-Menu.ps1') -Action Setup -GameExe $cliFixture.exe -PackageDirectory $cliFixture.package -StateRoot $cliState -NonInteractive | Out-Null
Assert-True ($LASTEXITCODE -eq 0) 'Simple Setup can be repeated without overwriting an existing installation'
$cliInstall=Get-InstallationDirectory $cliState $cliFixture.game
$fingerprint=Get-HostTestFingerprint $cliInstall
Assert-True ($fingerprint -match '^[0-9a-f]{64}$') 'Host-test cache identity includes the actual host configuration'
Set-IniValue (Join-Path $cliInstall 'parked\host64\ReShade.ini') 'RenoDX.DLSS5' 'NRStyle' '1'
Assert-True ((Get-HostTestFingerprint $cliInstall) -ne $fingerprint) 'Changing the neural style invalidates the host-test cache'
Assert-True ($null -eq (Get-CachedHostTest $cliInstall $fingerprint)) 'A missing cache never skips the GPU test'

$cachedReport=Join-Path $cliInstall 'host-tests\fixture'
Write-Utf8 (Join-Path $cachedReport 'host64\dlss5-feed-host.log') '[host] --test finished: 300/300 evaluates succeeded'
Write-Utf8 (Join-Path $cachedReport 'host64\ReShade.log') "feature 18 created`ninline feature 18 evaluation succeeded"
Write-JsonFile (Join-Path $cachedReport 'result.json') ([pscustomobject]@{passed=$true;exitCode=0})
$currentFingerprint=Get-HostTestFingerprint $cliInstall
Write-JsonFile (Join-Path $cliInstall 'last-host-test.json') ([pscustomobject]@{fingerprint=$currentFingerprint;report='host-tests/fixture'})
Assert-True ($null -ne (Get-CachedHostTest $cliInstall $currentFingerprint)) 'A matching successful host report can be reused'
Assert-True ($null -eq (Get-CachedHostTest $cliInstall $fingerprint)) 'A host report cannot be reused for different settings'
Write-Utf8 (Join-Path $cachedReport 'host64\ReShade.log') "feature 18 created`ninline feature 18 evaluation succeeded`nevaluate raised 0xC0000005"
Assert-True ($null -eq (Get-CachedHostTest $cliInstall $currentFingerprint)) 'A fault invalidates cached success markers'
Write-JsonFile (Join-Path $cliInstall 'last-host-test.json') ([pscustomobject]@{fingerprint=$currentFingerprint;report='../outside'})
Assert-True ($null -eq (Get-CachedHostTest $cliInstall $currentFingerprint)) 'Cache report paths cannot escape the installation'

$checkFirst=New-Fixture 'check-before-setup'
$checkState=Join-Path $checkFirst.base 'state'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\Open-Menu.ps1') -Action Check -GameExe $checkFirst.exe -StateRoot $checkState -NonInteractive | Out-Null
Assert-True ($LASTEXITCODE -eq 0) 'Check setup works before first installation'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\Open-Menu.ps1') -Action Setup -GameExe $checkFirst.exe -PackageDirectory $checkFirst.package -StateRoot $checkState -Offline -NonInteractive | Out-Null
Assert-True ($LASTEXITCODE -eq 0) 'A diagnostic report does not block subsequent setup'
$sibling=Join-Path $checkFirst.game 'AnotherGame.exe'
Write-FakePe $sibling
$savedErrorPreference=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'DLSS5-32bit.ps1') -Action Status -GameExe $sibling -StateRoot $checkState 2>$null | Out-Null
    $siblingExit=$LASTEXITCODE
} finally { $ErrorActionPreference=$savedErrorPreference }
Assert-True ($siblingExit -ne 0) 'A second executable in the same directory cannot claim another game setup'

Write-Host "All $script:passed assertions passed. No real game or GPU workload was launched."
Write-Host "Test artifacts: $runRoot"
