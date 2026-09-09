Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ContainedPath {
    param([string]$Root, [string]$Relative)
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or
        $Relative.Contains(':') -or ($Relative -split '[/\\]') -contains '..') {
        throw "Unsafe relative path: $Relative"
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $path = [IO.Path]::GetFullPath([IO.Path]::Combine($base, $Relative))
    if (-not $path.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its root: $Relative"
    }
    # Check existing ancestors too: lexical containment alone does not constrain junctions.
    $cursor = $path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points are not supported: $cursor"
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $path
}

function Get-RegularFiles {
    param([string]$Root)
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $item }
        }
    }
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Write-JsonFile {
    param([string]$Path, $Value)
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    Write-Utf8 $temp (($Value | ConvertTo-Json -Depth 12) + "`n")
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
}

function Get-Sha256 {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $hasher.Dispose(); $stream.Dispose() }
}

function Assert-Hash {
    param([string]$Path, [string]$Expected)
    if ($Expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-Sha256 $Path) -ne $Expected) {
        throw "SHA-256 mismatch: $Path. File was not installed or executed."
    }
}

function Get-PeMachine {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw "Not a PE file: $Path" }
        $stream.Position = 60
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $stream.Length - 6) { throw "Invalid PE offset: $Path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Missing PE signature: $Path" }
        switch ($reader.ReadUInt16()) {
            0x014C { return 'x86' }
            0x8664 { return 'x64' }
            default { throw "Unsupported PE architecture: $Path" }
        }
    } finally { $reader.Dispose() }
}

function Assert-GameClosed {
    param([string]$GameDirectory)
    $running = @(Get-Process -Name dlss5-feed-host64 -ErrorAction SilentlyContinue)
    if ($GameDirectory) {
        $prefix=[IO.Path]::GetFullPath($GameDirectory).TrimEnd('\')+'\'
        $running += @(Get-Process | Where-Object {
            try { $_.Path -and $_.Path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) } catch { $false }
        })
    }
    if ($running.Count) { throw ('Close the game and DLSS5 helper first: ' + (($running | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')) }
}

function Get-PeImports {
    param([string]$Path)
    $null=Get-PeMachine $Path
    $bytes=[IO.File]::ReadAllBytes($Path)
    $pe=[BitConverter]::ToInt32($bytes,60)
    if ($pe -gt $bytes.Length-24) { throw 'Truncated PE header.' }
    $sections=[BitConverter]::ToUInt16($bytes,$pe+6)
    $optionalSize=[BitConverter]::ToUInt16($bytes,$pe+20)
    $optional=$pe+24
    if ($optionalSize -lt 112 -or $optional+$optionalSize -gt $bytes.Length) { throw 'Truncated PE optional header.' }
    if ([BitConverter]::ToUInt16($bytes,$optional) -ne 0x10B) { throw 'Expected a 32-bit PE optional header.' }
    $table=$optional+$optionalSize
    if ($sections -gt 96 -or $table+40*$sections -gt $bytes.Length) { throw 'Invalid PE section table.' }
    $headers=[BitConverter]::ToUInt32($bytes,$optional+60)
    $convertRva = {
        param([uint32]$Rva)
        if ($Rva -lt $headers -and $Rva -lt $bytes.Length) { return [int]$Rva }
        for ($s=0;$s -lt $sections;$s++) {
            $section=$table+40*$s
            $address=[BitConverter]::ToUInt32($bytes,$section+12)
            $rawSize=[BitConverter]::ToUInt32($bytes,$section+16)
            $rawStart=[BitConverter]::ToUInt32($bytes,$section+20)
            if ([uint64]$Rva -ge $address -and [uint64]$Rva -lt [uint64]$address+$rawSize) {
                $offset=[uint64]$rawStart+$Rva-$address
                if ($offset -ge $bytes.Length) { throw 'PE RVA points outside the file.' }
                return [int]$offset
            }
        }
        throw 'PE RVA does not map to file data.'
    }
    if ([BitConverter]::ToUInt32($bytes,$optional+92) -lt 2) { return @() }
    $rva=[BitConverter]::ToUInt32($bytes,$optional+104)
    $size=[BitConverter]::ToUInt32($bytes,$optional+108)
    if (-not $rva -or -not $size) { return @() }
    $imports=@()
    for ($i=0;$i -lt [Math]::Min([Math]::Floor($size/20),4096);$i++) {
        $offset=& $convertRva ($rva+20*$i)
        if ($offset -gt $bytes.Length-20) { throw 'Truncated import descriptor.' }
        $nameRva=[BitConverter]::ToUInt32($bytes,$offset+12)
        if (-not $nameRva) { break }
        $nameOffset=& $convertRva $nameRva
        $end=$nameOffset
        while ($end -lt $bytes.Length -and $end-$nameOffset -lt 260 -and $bytes[$end]) { $end++ }
        if ($end -ge $bytes.Length -or $end-$nameOffset -ge 260) { throw 'Invalid imported DLL name.' }
        $imports += [Text.Encoding]::ASCII.GetString($bytes,$nameOffset,$end-$nameOffset).ToLowerInvariant()
    }
    return @($imports | Sort-Object -Unique)
}

function Get-GameTarget {
    param([string]$GameExe, [ValidateSet('Auto','D3D10','D3D11')][string]$Api='Auto')
    if ([string]::IsNullOrWhiteSpace($GameExe)) { throw 'Choose the actual 32-bit game .exe (not its launcher).' }
    $exe=[IO.Path]::GetFullPath($GameExe)
    $directory=[IO.Path]::GetDirectoryName($exe)
    $name=[IO.Path]::GetFileName($exe)
    $exe=Get-ContainedPath $directory $name
    if ([IO.Path]::GetExtension($exe) -ine '.exe' -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Choose an existing .exe file.' }
    if ((Get-PeMachine $exe) -ne 'x86') { throw 'This toolkit is for 32-bit (x86) games. The selected executable is 64-bit.' }
    $catalog=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\game-profiles.json') -Raw | ConvertFrom-Json
    if ($name -in $catalog.blockedExecutables) {
        throw 'This selected online-game executable is outside the offline single-player scope.'
    }
    foreach ($marker in @('EasyAntiCheat','EasyAntiCheat_EOS','BattlEye','GameGuard','EAAntiCheat','EAAntiCheat.GameServiceLauncher.exe')) {
        if (Test-Path -LiteralPath (Join-Path $directory $marker)) { throw "Anti-cheat marker found ($marker). This toolkit does not bypass anti-cheat." }
    }
    $imports=@(Get-PeImports $exe)
    $detected=if ($imports -contains 'd3d11.dll') { 'D3D11' }
              elseif ($imports -contains 'd3d10.dll' -or $imports -contains 'd3d10_1.dll') { 'D3D10' }
              else { 'Unknown' }
    if ($Api -eq 'Auto') {
        if ($detected -eq 'Unknown') { throw 'No DirectX 10/11 import was found. DX9, Vulkan and OpenGL are not automated by this release. For a game known to load DX10/11 dynamically, select -Api D3D10 or -Api D3D11 explicitly.' }
        $Api=$detected
    }
    $profiles=@($catalog.profiles | Where-Object { $_.executable -ieq $name -and $_.api -eq $Api })
    if ($profiles.Count -gt 1) { throw 'The profile catalog contains an ambiguous executable mapping.' }
    $example=if ($profiles.Count) { $profiles[0].name } else { $null }
    $steamId=if ($profiles.Count) { $profiles[0].steamAppId } else { $null }
    [pscustomobject]@{exe=$exe;directory=$directory;name=$name;api=$Api;detectedApi=$detected;imports=$imports;example=$example;steamAppId=$steamId}
}

function Open-AssetArchive {
    param([string]$Path, [switch]$Sfx)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not $Sfx) { return [IO.Compression.ZipFile]::OpenRead($Path) }
    # ReShade's installer carries an appended ZIP. Extract data; never run the installer.
    $bytes = [IO.File]::ReadAllBytes($Path)
    for ($i = 0; $i -le $bytes.Length - 30; $i += 512) {
        if ([BitConverter]::ToUInt32($bytes, $i) -ne 0x04034B50) { continue }
        $memory = New-Object IO.MemoryStream
        $memory.Write($bytes, $i, $bytes.Length - $i)
        $memory.Position = 0
        try {
            $archive = New-Object IO.Compression.ZipArchive($memory, [IO.Compression.ZipArchiveMode]::Read)
            if (@($archive.Entries | Where-Object FullName -eq 'ReShade32.dll').Count -ne 1) { throw 'Not the ReShade payload' }
            return $archive
        } catch { $memory.Dispose() }
    }
    throw "Cannot locate ReShade's embedded archive: $Path"
}

function Get-LockedDownload {
    param($Asset, [string]$CacheDirectory, [switch]$Offline)
    $path = Get-ContainedPath $CacheDirectory $Asset.file
    if (-not (Test-Path -LiteralPath $path)) {
        if ($Offline) { throw "Missing cached asset: $($Asset.file)" }
        $uri = [Uri]$Asset.url
        if ($uri.Scheme -ne 'https' -or $uri.Host -notin @('github.com','codeload.github.com','raw.githubusercontent.com','reshade.me')) {
            throw "Unsupported source URL: $uri"
        }
        [IO.Directory]::CreateDirectory($CacheDirectory) | Out-Null
        $part = $path + '.' + [guid]::NewGuid().ToString('N') + '.part'
        Write-Host "Downloading $($Asset.file)"
        $oldProgress = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $part -TimeoutSec 120
            Assert-Hash $part $Asset.sha256
            [IO.File]::Move($part, $path)
        } finally { $ProgressPreference = $oldProgress }
    }
    Assert-Hash $path $Asset.sha256
    return $path
}

function New-PreparedPackage {
    param([string]$Repository, [string]$OutputDirectory, [string]$CacheDirectory, [switch]$Offline)
    $lockPath = Join-Path $Repository 'components.lock.json'
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
    if ($lock.schema -ne 1) { throw 'Unsupported component lock schema.' }
    if (Test-Path -LiteralPath $OutputDirectory) {
        $existing = Test-PreparedPackage $OutputDirectory
        if ($existing.lockSha256 -ne (Get-Sha256 $lockPath)) { throw 'Package uses a different lock. Choose a new -PackageDirectory.' }
        foreach ($profile in @('ReShade.ini','DLSS5-32bit.ini','dlss5-feed.cfg','host-ReShade.ini')) {
            if ($existing.profileHashes.$profile -ne (Get-Sha256 (Join-Path $Repository "profiles\$profile"))) {
                throw 'Profiles changed. Choose a new -PackageDirectory.'
            }
        }
        return $existing
    }
    # An incomplete folder never receives package.json and cannot be installed.
    $payload = Get-ContainedPath $OutputDirectory 'payload'
    [IO.Directory]::CreateDirectory($payload) | Out-Null
    $files = New-Object Collections.ArrayList
    foreach ($asset in $lock.assets) {
        $download = Get-LockedDownload $asset $CacheDirectory -Offline:$Offline
        $archive = $null
        try {
            if ($asset.kind -ne 'file') { $archive = Open-AssetArchive $download -Sfx:($asset.kind -eq 'sfx') }
            foreach ($entry in $asset.entries) {
                $dest = Get-ContainedPath $payload $entry.target
                if (Test-Path -LiteralPath $dest) { throw "Duplicate package target: $($entry.target)" }
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
                if ($asset.kind -eq 'file') { [IO.File]::Copy($download, $dest) }
                else {
                    $matches = @($archive.Entries | Where-Object { $_.FullName.Replace('\','/') -ceq $entry.source })
                    if ($matches.Count -ne 1) { throw "Expected exactly one archive member: $($entry.source)" }
                    if ($matches[0].Length -gt 250MB) { throw 'Archive member exceeds the profile size limit.' }
                    $inputStream = $matches[0].Open()
                    $outputStream = [IO.File]::Create($dest)
                    try { $inputStream.CopyTo($outputStream) } finally { $inputStream.Dispose(); $outputStream.Dispose() }
                }
                if ($entry.PSObject.Properties['sha256']) { Assert-Hash $dest $entry.sha256 }
                if ($entry.PSObject.Properties['machine'] -and (Get-PeMachine $dest) -ne $entry.machine) {
                    throw "Architecture mismatch: $($entry.target)"
                }
                if ($entry.PSObject.Properties['signer']) {
                    $signature = Get-AuthenticodeSignature -LiteralPath $dest
                    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch ('(^|,\s*)CN=' + [regex]::Escape($entry.signer) + '(,|$)')) {
                        throw "Signature check failed: $($entry.target): $($signature.Status)"
                    }
                }
                $null = $files.Add([pscustomobject]@{path=$entry.target; sha256=(Get-Sha256 $dest); mutable=$false; component=$asset.id})
            }
        } finally { if ($archive) { $archive.Dispose() } }
    }
    $profileHashes = @{}
    foreach ($profile in @('ReShade.ini','DLSS5-32bit.ini','dlss5-feed.cfg','host-ReShade.ini')) {
        $source = Join-Path $Repository "profiles\$profile"
        $relative = if ($profile -eq 'host-ReShade.ini') { 'host64/ReShade.ini' } else { $profile }
        [IO.File]::Copy($source, (Get-ContainedPath $payload $relative))
        $profileHashes[$profile] = Get-Sha256 $source
        $null = $files.Add([pscustomobject]@{path=$relative; sha256=(Get-Sha256 $source); mutable=$true; component='profile'})
    }
    $manifest = [pscustomobject]@{schema=1; profile=$lock.profile; lockSha256=(Get-Sha256 $lockPath); profileHashes=$profileHashes; files=@($files)}
    Write-JsonFile (Join-Path $OutputDirectory 'package.json') $manifest
    return (Test-PreparedPackage $OutputDirectory)
}

function Test-PreparedPackage {
    param([string]$PackageDirectory)
    $manifestPath = Get-ContainedPath $PackageDirectory 'package.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or @($manifest.files).Count -eq 0) { throw 'Invalid package manifest.' }
    $seen = @{}
    foreach ($file in $manifest.files) {
        $top = ($file.path -split '[/\\]')[0]
        if ($top -notin @('dxgi.dll','dlss5-feed.addon32','dlss5-feed.cfg','ReShade.ini','DLSS5-32bit.ini','host64','dlss5-shaders')) {
            throw "Package would modify an unowned path: $($file.path)"
        }
        if ($seen.ContainsKey($file.path)) { throw 'Duplicate path in package manifest.' }
        $seen[$file.path] = $true
        Assert-Hash (Get-ContainedPath (Join-Path $PackageDirectory 'payload') $file.path) $file.sha256
    }
    foreach ($required in @('dxgi.dll','dlss5-feed.addon32','dlss5-feed.cfg','ReShade.ini','DLSS5-32bit.ini',
        'host64/dxgi.dll','host64/dlss5-feed-host64.exe','host64/renodx-dlss5.addon64','host64/nvngx_dlssnr.dll',
        'host64/nvngx_dlss.dll','host64/ReShade.ini','dlss5-shaders/Shaders/DLSS5_Feed.fx',
        'dlss5-shaders/Shaders/lumenite_Kernel.fx','dlss5-shaders/Shaders/DisplayDepth.fx')) {
        if (-not $seen.ContainsKey($required)) { throw "Package incomplete: $required" }
    }
    return $manifest
}

function Get-InstallationDirectory {
    param([string]$StateRoot, [string]$GameDirectory)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $id = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($GameDirectory.ToLowerInvariant())))).Replace('-','').Substring(0,20) }
    finally { $hasher.Dispose() }
    return (Get-ContainedPath $StateRoot $id)
}

function Read-Installation {
    param([string]$InstallDirectory)
    $state = Get-Content -LiteralPath (Get-ContainedPath $InstallDirectory 'installation.json') -Raw | ConvertFrom-Json
    if ($state.schema -ne 2 -or $state.status -notin @('disabled','enabled','moving')) { throw 'Invalid installation state.' }
    if ([IO.Path]::GetDirectoryName($state.gameExe) -ine $state.gameDirectory -or $state.api -notin @('D3D10','D3D11')) { throw 'Invalid game identity in installation state.' }
    $allowed = @('dxgi.dll','dlss5-feed.addon32','dlss5-feed.cfg','ReShade.ini','DLSS5-32bit.ini','host64','dlss5-shaders')
    if (@($state.topLevel).Count -ne $allowed.Count -or @($state.topLevel | Sort-Object -Unique).Count -ne $allowed.Count) { throw 'Invalid ownership manifest.' }
    foreach ($name in $state.topLevel) { if ($name -notin $allowed) { throw "Unrecognized owned path: $name" } }
    return $state
}

function Get-InjectionConflicts {
    param([string]$GameDirectory)
    $proxies = @('dxgi.dll','d3d11.dll','d3d10.dll','d3d9.dll','dinput8.dll','version.dll','winmm.dll','opengl32.dll')
    foreach ($item in Get-ChildItem -LiteralPath $GameDirectory -Force) {
        if ($item.Name -in $proxies -or $item.Name -match '\.addon(32|64)?$' -or
            $item.Name -in @('ReShade.ini','DLSS5-32bit.ini','dlss5-feed.cfg','host64','dlss5-shaders')) { $item.Name }
    }
}

function Install-ParkedPackage {
    param([string]$PackageDirectory, $GameTarget, [string]$InstallDirectory)
    $target=Get-GameTarget $GameTarget.exe -Api $GameTarget.api
    $game=$target.directory
    Assert-GameClosed $game
    $package = Test-PreparedPackage $PackageDirectory
    if (Test-Path -LiteralPath (Join-Path $InstallDirectory 'installation.json')) { throw 'An installation already exists. Use Status, Enable or Disable.' }
    if (Test-Path -LiteralPath (Join-Path $InstallDirectory 'parked')) { throw 'An incomplete parked payload already exists. Preserve it and inspect the earlier setup failure before retrying.' }
    $conflicts = @(Get-InjectionConflicts $game)
    if ($conflicts.Count) { throw ('Existing mod files were preserved. Move them aside before installing: ' + ($conflicts -join ', ')) }
    $parked = Get-ContainedPath $InstallDirectory 'parked'
    [IO.Directory]::CreateDirectory($parked) | Out-Null
    foreach ($file in $package.files) {
        $dest = Get-ContainedPath $parked $file.path
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
        [IO.File]::Copy((Get-ContainedPath (Join-Path $PackageDirectory 'payload') $file.path), $dest)
        Assert-Hash $dest $file.sha256
    }
    $state = [pscustomobject]@{
        schema=2; status='disabled'; gameDirectory=$game; gameExe=$target.exe; api=$target.api; steamAppId=$target.steamAppId; gameSha256=(Get-Sha256 $target.exe);
        installedAt=[DateTime]::UtcNow.ToString('o'); profile=$package.profile; mode='Neural'; files=$package.files;
        topLevel=@('dxgi.dll','dlss5-feed.addon32','dlss5-feed.cfg','ReShade.ini','DLSS5-32bit.ini','host64','dlss5-shaders');
        createdLogs=@('ReShade.log','dlss5-feed.log' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $game $_)) })
    }
    Write-JsonFile (Join-Path $InstallDirectory 'installation.json') $state
    return $state
}

function Move-OwnedItem {
    param([string]$SourceRoot, [string]$DestinationRoot, [string]$Relative)
    $source = Get-ContainedPath $SourceRoot $Relative
    $dest = Get-ContainedPath $DestinationRoot $Relative
    if (Test-Path -LiteralPath $dest) { throw "Destination already exists: $dest" }
    if ((Get-Item -LiteralPath $source -Force).PSIsContainer) { $null = @(Get-RegularFiles $source) }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
    Move-Item -LiteralPath $source -Destination $dest
}

function Set-InstallationEnabled {
    param([string]$InstallDirectory, [bool]$Enabled)
    $state = Read-Installation $InstallDirectory
    $game=$state.gameDirectory
    Assert-GameClosed $game
    if ($Enabled) { $null=Get-GameTarget $state.gameExe -Api $state.api }
    $wanted = if ($Enabled) { 'enabled' } else { 'disabled' }
    if ($state.status -eq $wanted) { return $state }
    if ($state.status -eq 'moving') { throw 'An earlier move was interrupted. Inspect installation.json and both folders before recovery.' }
    $parked = Get-ContainedPath $InstallDirectory 'parked'
    $sourceRoot = if ($Enabled) { $parked } else { $game }
    $destRoot = if ($Enabled) { $game } else { $parked }
    if ($Enabled) {
        $conflicts = @(Get-InjectionConflicts $game)
        if ($conflicts.Count) { throw ('Enable would overlap existing files: ' + ($conflicts -join ', ')) }
        foreach ($file in $state.files) {
            if (-not $file.mutable) { Assert-Hash (Get-ContainedPath $parked $file.path) $file.sha256 }
        }
    }
    $available=@()
    foreach ($name in $state.topLevel) {
        $source = Get-ContainedPath $sourceRoot $name
        $dest = Get-ContainedPath $destRoot $name
        if (-not (Test-Path -LiteralPath $source)) {
            if ($Enabled) { throw "Cannot enable: $name is missing from the parked payload." }
            continue # An absent owned file must not prevent removing the proxy and remaining files.
        }
        if (Test-Path -LiteralPath $dest) { throw "Cannot move $name; destination is occupied." }
        if ((Get-Item -LiteralPath $source).PSIsContainer) { $null = @(Get-RegularFiles $source) }
        $available += $name
    }
    $previous = $state.status
    $state.status = 'moving'
    Write-JsonFile (Join-Path $InstallDirectory 'installation.json') $state
    $moved = New-Object Collections.ArrayList
    try {
        # dxgi.dll is the activation point: install it last, remove it first.
        $order = if ($Enabled) { @($available | Where-Object { $_ -ne 'dxgi.dll' }) + @('dxgi.dll') } else { @($available) }
        foreach ($name in $order) { Move-OwnedItem $sourceRoot $destRoot $name; $null = $moved.Add($name) }
    } catch {
        $originalError = $_
        try {
            for ($i=$moved.Count-1; $i -ge 0; $i--) { Move-OwnedItem $destRoot $sourceRoot $moved[$i] }
            $state.status = $previous
            Write-JsonFile (Join-Path $InstallDirectory 'installation.json') $state
        } catch { throw "Move and rollback both failed. Keep the game closed and inspect $InstallDirectory. $($_.Exception.Message)" }
        throw $originalError
    }
    $state.status = $wanted
    Write-JsonFile (Join-Path $InstallDirectory 'installation.json') $state
    return $state
}

function Set-IniValue {
    param([string]$Path, [string]$Section, [string]$Key, [string]$Value)
    $lines = New-Object 'Collections.Generic.List[string]'
    foreach ($line in [IO.File]::ReadAllLines($Path)) { $lines.Add($line) }
    $current = ''; $insert = -1; $foundSection = ($Section -eq '')
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[([^\]]+)\]\s*$') {
            if ($current -eq $Section -and $insert -lt 0) { $insert = $i }
            $current = $Matches[1]
            if ($current -eq $Section) { $foundSection = $true; $insert = -1 }
        } elseif ($current -eq $Section -and $lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            $lines[$i] = $Key + '=' + $Value
            Write-Utf8 $Path (($lines -join "`r`n") + "`r`n")
            return
        }
    }
    if (-not $foundSection) { $lines.Add(''); $lines.Add('['+$Section+']'); $insert=$lines.Count }
    if ($insert -lt 0) { $insert=$lines.Count }
    $lines.Insert($insert, ($Key+'='+$Value))
    Write-Utf8 $Path (($lines -join "`r`n") + "`r`n")
}

function Set-ProfileMode {
    param([string]$InstallDirectory, [ValidateSet('Plain','Depth','Transport','Neural')][string]$Mode, [ValidateSet(-1,0,1)][int]$DepthReversed=-1)
    $state = Read-Installation $InstallDirectory
    Assert-GameClosed $state.gameDirectory
    if ($state.status -eq 'moving') { throw 'Installation has an interrupted move.' }
    $root = if ($state.status -eq 'enabled') { $state.gameDirectory } else { Join-Path $InstallDirectory 'parked' }
    $config = Get-ContainedPath $root 'dlss5-feed.cfg'
    $preset = Get-ContainedPath $root 'DLSS5-32bit.ini'
    $enabled = if ($Mode -in @('Transport','Neural')) { '1' } else { '0' }
    $number = if ($Mode -eq 'Transport') { '1' } else { '2' }
    $techniques = switch ($Mode) {
        'Plain' { '' }
        'Depth' { 'DisplayDepth@DisplayDepth.fx' }
        default { 'Lumenite_Kernel@lumenite_Kernel.fx,DLSS5_Feed@DLSS5_Feed.fx' }
    }
    Set-IniValue $config '' 'enabled' $enabled
    Set-IniValue $config '' 'mode' $number
    Set-IniValue $preset '' 'Techniques' $techniques
    if ($DepthReversed -ge 0) {
        $ini = Get-ContainedPath $root 'ReShade.ini'
        $text = [IO.File]::ReadAllText($ini)
        # Preserve every other ReShade definition, including user-tuned orientation.
        if ($text -match 'RESHADE_DEPTH_INPUT_IS_REVERSED=[01]') {
            Write-Utf8 $ini ([regex]::Replace($text, 'RESHADE_DEPTH_INPUT_IS_REVERSED=[01]', "RESHADE_DEPTH_INPUT_IS_REVERSED=$DepthReversed"))
        } else { throw 'Depth definition missing; set it through the ReShade overlay.' }
    }
    $state.mode = $Mode
    Write-JsonFile (Join-Path $InstallDirectory 'installation.json') $state
    return $state
}

function Get-LogEvidence {
    param([string]$Root, [DateTime]$Since=[DateTime]::MinValue, [string]$GameLogRoot, [string]$ExecutableName)
    $texts = @{}
    $timestamps = @{}
    foreach ($relative in @('ReShade.log','dlss5-feed.log','host64/ReShade.log','host64/dlss5-feed-host.log')) {
        $logRoot = if ($GameLogRoot -and -not $relative.StartsWith('host64/')) { $GameLogRoot } else { $Root }
        $path = Get-ContainedPath $logRoot $relative
        $texts[$relative] = ''
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path
            $timestamps[$relative] = $item.LastWriteTimeUtc.ToString('o')
            if ($item.LastWriteTimeUtc -ge $Since.ToUniversalTime()) { $texts[$relative] = [IO.File]::ReadAllText($path) }
        }
    }
    $game = $texts['ReShade.log']; $feed = $texts['dlss5-feed.log']
    $hostText = $texts['host64/dlss5-feed-host.log']; $neural = $texts['host64/ReShade.log']
    # A successful DLAA evaluate alone is not proof that neural feature 18 ran.
    [pscustomobject]@{
        source='most recent log files; timestamps must be checked against the intended session'
        logTimestamps=$timestamps
        reshade32Loaded=[bool]($game -match '\(32-bit\)' -and (-not $ExecutableName -or $game -match [regex]::Escape($ExecutableName)))
        d3d11DeviceObserved=[bool]($feed -match '\[feed32\] D3D11 multithread protection enabled')
        frameDelivered=[bool]($feed -match '\[feed32\] frame \d+ delivered')
        lumeniteSelected=[bool]($feed -match 'DLSS5_MV_PROVIDER=3.+Lumenite_Kernel \(enabled\)')
        hostDlaaReady=[bool]($hostText -match 'feature ready:.+DLAA')
        neuralFeatureCreated=[bool]($neural -match 'feature 18 created')
        neuralEvaluationSucceeded=[bool]($neural -match 'inline feature 18 evaluation succeeded')
        hostTest300=[bool]($hostText -match '--test finished: 300/300 evaluates succeeded')
        runtimeFaultObserved=[bool](($feed + $hostText + $neural) -match '### CRASH RECORDED ###|evaluate raised 0x|device removed[^\r\n]+0x887A|stopped: repeated failures')
        visualDepthVerified=$false
        visualMotionVerified=$false
        visualABVerified=$false
        gameplayStabilityVerified=$false
    }
}

function Get-ToolkitStatus {
    param($GameTarget, [string]$InstallDirectory)
    $game=$GameTarget.directory
    $manifest = Join-Path $InstallDirectory 'installation.json'
    $state = if (Test-Path -LiteralPath $manifest) { Read-Installation $InstallDirectory } else { $null }
    $root = if ($state -and $state.status -eq 'disabled') { Join-Path $InstallDirectory 'parked' } else { $game }
    $integrity = @()
    if ($state -and $state.status -ne 'moving') {
        foreach ($file in $state.files) {
            $path = Get-ContainedPath $root $file.path
            $exists = Test-Path -LiteralPath $path -PathType Leaf
            $match = if ($exists -and -not $file.mutable) { (Get-Sha256 $path) -eq $file.sha256 } else { $null }
            $integrity += [pscustomobject]@{path=$file.path; exists=$exists; hashMatches=$match; configuration=$file.mutable}
        }
    }
    $gpu = @(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion)
    [pscustomobject]@{
        gameDirectory=$game
        executable=$GameTarget.name
        architecture=(Get-PeMachine $GameTarget.exe)
        api=$GameTarget.api
        state=$(if ($state) { $state.status } else { 'not installed' })
        mode=$(if ($state) { $state.mode } else { $null })
        graphicsAdapters=$gpu
        files=$integrity
        gameFolderGraphicsFiles=@(Get-InjectionConflicts $game)
        evidence=(Get-LogEvidence $root -GameLogRoot $game -ExecutableName $GameTarget.name)
        compatibility='Eligible API/architecture is not a game compatibility guarantee. Depth, motion and visual quality need an in-game check.'
    }
}

function Copy-SessionLogs {
    param([string]$Root, [string]$OutputDirectory, [string]$GameLogRoot)
    [IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
    foreach ($name in @('ReShade.log','dlss5-feed.log','host64/ReShade.log','host64/dlss5-feed-host.log')) {
        $logRoot = if ($GameLogRoot -and -not $name.StartsWith('host64/')) { $GameLogRoot } else { $Root }
        $source = Get-ContainedPath $logRoot $name
        if (Test-Path -LiteralPath $source) {
            $dest = Get-ContainedPath $OutputDirectory $name
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
            [IO.File]::Copy($source, $dest, $false)
        }
    }
    Write-JsonFile (Join-Path $OutputDirectory 'evidence.json') (Get-LogEvidence $Root -GameLogRoot $GameLogRoot)
}

function Get-HostTestFingerprint {
    param([string]$InstallDirectory)
    $state = Read-Installation $InstallDirectory
    if ($state.status -eq 'moving') { throw 'Installation has an interrupted move.' }
    $root = if ($state.status -eq 'enabled') { $state.gameDirectory } else { Join-Path $InstallDirectory 'parked' }
    $parts = @('host-test-v1')
    foreach ($file in @($state.files | Where-Object { $_.path -like 'host64/*' } | Sort-Object path)) {
        $path = Get-ContainedPath $root $file.path
        if (-not $file.mutable) { Assert-Hash $path $file.sha256 }
        $parts += $file.path + '=' + (Get-Sha256 $path)
    }
    foreach ($gpu in @(Get-CimInstance Win32_VideoController | Sort-Object Name,DriverVersion)) {
        $parts += $gpu.Name + '=' + $gpu.DriverVersion
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($parts -join "`n")))).Replace('-','').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function Get-CachedHostTest {
    param([string]$InstallDirectory, [string]$Fingerprint)
    $cachePath = Get-ContainedPath $InstallDirectory 'last-host-test.json'
    if (-not (Test-Path -LiteralPath $cachePath)) { return $null }
    try {
        $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        if ($cache.fingerprint -ne $Fingerprint) { return $null }
        $report = Get-ContainedPath $InstallDirectory $cache.report
        $result = Get-Content -LiteralPath (Join-Path $report 'result.json') -Raw | ConvertFrom-Json
        $evidence = Get-LogEvidence $report
        if ($result.passed -and $result.exitCode -eq 0 -and $evidence.hostTest300 -and
            $evidence.neuralFeatureCreated -and $evidence.neuralEvaluationSucceeded -and -not $evidence.runtimeFaultObserved) {
            return $result
        }
    } catch { return $null }
    return $null
}

function Invoke-HostTest {
    param([string]$InstallDirectory, [switch]$UseCache)
    $state = Read-Installation $InstallDirectory
    Assert-GameClosed $state.gameDirectory
    $fingerprint = Get-HostTestFingerprint $InstallDirectory
    if ($UseCache) {
        $cached = Get-CachedHostTest $InstallDirectory $fingerprint
        if ($cached) {
            Write-Host 'Host test already passed for these host files, settings, GPU and driver.'
            return $cached
        }
    }
    $state = Read-Installation $InstallDirectory
    if ($state.status -eq 'moving') { throw 'Installation has an interrupted move.' }
    $sourceRoot = if ($state.status -eq 'enabled') { $state.gameDirectory } else { Join-Path $InstallDirectory 'parked' }
    # Always test in a new isolated directory: old success logs cannot pass this test,
    # and the synthetic test never overwrites evidence from a real game run.
    $report = Get-ContainedPath $InstallDirectory ('host-tests/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    foreach ($file in $state.files | Where-Object { $_.path -like 'host64/*' }) {
        $source = Get-ContainedPath $sourceRoot $file.path
        if (-not $file.mutable) { Assert-Hash $source $file.sha256 }
        $dest = Get-ContainedPath $report $file.path
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest)) | Out-Null
        [IO.File]::Copy($source, $dest)
    }
    $hostDir = Join-Path $report 'host64'
    $started = [DateTime]::UtcNow
    Write-Host 'Running the GPU host test (300 evaluations). No game is launched.'
    $process = Start-Process -FilePath (Join-Path $hostDir 'dlss5-feed-host64.exe') -ArgumentList '--test' -WorkingDirectory $hostDir -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(90000)) {
        # Do not kill an in-flight GPU workload: leave its logs and exact process ID.
        throw "Host test has not exited after 90 seconds (PID $($process.Id)). Logs: $report"
    }
    $evidence = Get-LogEvidence $report -Since $started
    $passed = $process.ExitCode -eq 0 -and $evidence.hostTest300 -and $evidence.neuralFeatureCreated -and $evidence.neuralEvaluationSucceeded -and -not $evidence.runtimeFaultObserved
    $result = [pscustomobject]@{passed=$passed; exitCode=$process.ExitCode; startedAt=$started.ToString('o'); reportDirectory=$report; evidence=$evidence}
    Write-JsonFile (Join-Path $report 'result.json') $result
    if ($passed) {
        $relativeReport = $report.Substring([IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\').Length+1).Replace('\','/')
        Write-JsonFile (Join-Path $InstallDirectory 'last-host-test.json') ([pscustomobject]@{fingerprint=$fingerprint;report=$relativeReport})
    }
    return $result
}

function Start-SelectedGame {
    param([string]$InstallDirectory, [string]$SteamExe)
    $state = Read-Installation $InstallDirectory
    Assert-GameClosed $state.gameDirectory
    if ($state.steamAppId -and -not $SteamExe) {
        $steamInfo = Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
        if ($steamInfo -and $steamInfo.PSObject.Properties['SteamExe']) { $SteamExe = $steamInfo.SteamExe }
        else { $SteamExe = Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe' }
    }
    if ($state.steamAppId -and -not (Test-Path -LiteralPath $SteamExe -PathType Leaf)) { throw 'Steam not found. Specify -SteamExe.' }
    $previouslyEnabled = $state.status -eq 'enabled'
    $null = Set-InstallationEnabled $InstallDirectory $true
    try {
        if ($state.steamAppId) {
            Write-Host "Launching selected game through Steam (AppID $($state.steamAppId)). Use Offline Mode for testing."
            Start-Process -FilePath $SteamExe -ArgumentList '-applaunch',([string]$state.steamAppId) -WindowStyle Hidden
        } else {
            Write-Host "Launching $([IO.Path]::GetFileName($state.gameExe))"
            $null=Start-Process -FilePath $state.gameExe -WorkingDirectory $state.gameDirectory -PassThru
        }
        $deadline = [DateTime]::UtcNow.AddMinutes(3)
        $gameProcess = $null
        while ([DateTime]::UtcNow -lt $deadline) {
            $gameProcess = Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($state.gameExe)) -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $state.gameExe } | Select-Object -First 1
            if ($gameProcess) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $gameProcess) { throw 'The selected game did not start within three minutes. If it needs a store launcher, use Enable only and launch it there.' }
        Write-Host 'Keep this launcher open. The mod will be parked after the game exits if this session enabled it.'
        $gameProcess.WaitForExit()
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ((Get-Process -Name dlss5-feed-host64 -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 500 }
        $report = Get-ContainedPath $InstallDirectory ('sessions/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
        Copy-SessionLogs $state.gameDirectory $report
        Write-Host "Session logs saved locally: $report"
    } finally {
        if (-not $previouslyEnabled) {
            try { $null = Set-InstallationEnabled $InstallDirectory $false; Write-Host 'Mod parked outside the game folder.' }
            catch { throw "Automatic parking could not finish: $($_.Exception.Message). Close the game/helper, then run Disable before launching other executables in this folder." }
        }
    }
}

Export-ModuleMember -Function *
