# Advanced commands

Most users only need `DLSS5-32bit.cmd`. These commands are for diagnostics, unusual install locations, and development. Run them from the extracted toolkit folder; the examples use a placeholder executable path.

```powershell
.\DLSS5-32bit.ps1 -Action Prepare
.\DLSS5-32bit.ps1 -Action Install -GameExe 'D:\Games\Example\Game.exe'
.\DLSS5-32bit.ps1 -Action HostTest -GameExe 'D:\Games\Example\Game.exe'
.\DLSS5-32bit.ps1 -Action Launch -GameExe 'D:\Games\Example\Game.exe'
```

If script execution is restricted, prefix a command with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`. The shipped CMD launcher applies that process-local option; it does not alter machine-wide execution policy.

| Action | Result |
| --- | --- |
| Prepare | Download/cache the pinned components and build a verified private payload. `-Offline` uses cached downloads only. |
| Install | Park that payload outside the selected game. Does not activate or launch it. |
| Status | Emit JSON describing files, API/architecture, GPU/driver, and timestamps/observations from the latest logs. |
| Enable / Disable | Physically move owned components into/out of the game directory. Original game data is untouched. |
| Mode | Choose Plain, Depth, Transport, or Neural; requires the game/helper closed. |
| HostTest | Run a fresh synthetic GPU test. `-UseCachedHostTest` allows reuse for matching host files/settings/GPU/driver. |
| Launch | Activate and launch the selected executable (or its known catalog launch target); save logs and restore disabled state after exit if applicable. The raw CLI does not implicitly run HostTest. |
| CollectLogs | Copy four logs into a new local report directory. Nothing is transmitted. |

The friendly menu's **Play game** does run or reuse the host test before launching.

## Depth and transport

```powershell
.\DLSS5-32bit.ps1 -Action Mode -Mode Depth -GameExe 'D:\Games\Example\Game.exe'
.\DLSS5-32bit.ps1 -Action Mode -Mode Depth -DepthReversed 0 -GameExe 'D:\Games\Example\Game.exe'
.\DLSS5-32bit.ps1 -Action Mode -Mode Transport -GameExe 'D:\Games\Example\Game.exe'
.\DLSS5-32bit.ps1 -Action Mode -Mode Neural -GameExe 'D:\Games\Example\Game.exe'
```

Mode changes do not automatically launch the game. Transport mode returns a deliberate half-black image as its round-trip proof. Plain mode disables the Feeder and all effects while keeping ReShade loaded.

## Dynamic API loading

Static import inspection cannot identify every renderer. If you independently know the game is using D3D11 or D3D10, specify `-Api D3D11` or `-Api D3D10`. The override does not translate DX9/Vulkan/OpenGL into a supported API.

```powershell
.\DLSS5-32bit.ps1 -Action Install -GameExe 'D:\Games\Example\Game.exe' -Api D3D11
.\tools\Open-Menu.ps1 -GameExe 'D:\Games\Example\Game.exe' -Api D3D11
```

## Data locations and recovery

- Prepared payload: `.local\generic-package` in this checkout.
- Download cache: `.cache\downloads`.
- Per-game state, parked files, test results and logs: `%LOCALAPPDATA%\DLSS5-32bit\installations\`.
- `-PackageDirectory`, `-CacheDirectory`, and `-StateRoot` allow custom locations.
- One setup owns a graphics directory. Selecting a second executable in the same directory does not create an independent injector scope.

Normal move failures roll back. If the process or machine stops during a move, `installation.json` may say `moving`. Keep the game closed and inspect that state, the game directory, and the parked directory. The toolkit refuses further activation instead of guessing which files to overwrite.

Disabled installations retain inert root log files for troubleshooting. Unrelated mod files are never deleted. Disabling can fail while a game/helper still has files open; close it and retry.
