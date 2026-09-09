# First run and troubleshooting

## 1. Check the host

The menu's Play option first runs a short synthetic GPU test, unless the same host files/settings/GPU/driver already passed. Success requires all 300 evaluations, neural feature-18 creation and evaluation, exit code 0, and no recognized runtime fault. A successful DLAA pass alone does not pass the neural check.

To force a fresh test, use `DLSS5-32bit.ps1 -Action HostTest -GameExe 'D:\Games\Example\Game.exe'`. Results are saved locally. A test timeout reports the helper PID and leaves it untouched; wait for it to exit before retrying.

## 2. Verify depth in an actual scene

Turn MSAA off. Start at native output resolution, in SDR, using windowed or borderless mode. In ReShade's Home tab, enable DisplayDepth temporarily. On Add-ons, expand Generic Depth and select a full-resolution buffer tracking scene geometry.

The depth image should cover the scene and update as the camera moves. If needed, test copy-before-clear/fullscreen options one at a time. Correct the global reversed/upside-down depth definitions; DisplayDepth's presentation controls alone do not correct the guide sent to the Feeder.

The shipped reversed-depth definition is **1 as an initial default**, not a measured value for every game. Feeder's Depth inverted: Auto follows that definition. A menu-only or frozen depth buffer does not pass.

Disable DisplayDepth after the check. Keep Kernel before DLSS5 Feed in the effect list. Use the CLI Depth mode if you prefer to change modes with the game closed.

## 3. Verify the image reaches the helper and comes back

Transport mode intentionally produces a half-black image. It makes the shared-resource round trip observable without invoking NGX for the frames. This is a diagnostic mode, not a visual preset.

In normal Neural mode, the provider status should identify **DLSS5_MV_PROVIDER=3 → Lumenite_Kernel (enabled)**, and the frame counter should advance. Use DLSS5_Feed_Debug briefly to inspect motion and depth guides; a provider name alone does not prove they are accurate.

## 4. Tune the neural effect

Press Home → Add-ons, expand **DLSS 5 Feed**, and scroll to the host's neural-rendering settings. Numbered NR Presets and the Natural/Cinematic NR Style are different controls. Their numbers are not quality levels.

The mirrored panel applies settings by restarting the helper when **Apply to the DLSS 5 host** is clicked. Allow its initialization to finish. **Show as texture (fullscreen too)** displays the helper's actual panel for live changes.

Start near the defaults: neural rendering on, neural upscaling off, 100% work resolution, masks/UI correction on, motion scales 1, reset-every-frame off, pipelined handoff on. Leave version-specific controls at defaults; for the classic 4.55 consumer, the Global Tone and Diffuse White controls labeled for 4.7+ do not apply.

For lower GPU cost after the image is stable, try 75% work resolution with FSR 1 expand-back. This processes a smaller copy of the finished game frame; it is not native game DLSS Quality mode.

Compare a fixed view with F10, then inspect fast turns, weapon/hand animation, faces, thin geometry, particles, HUD text, and cutscenes. A good still image is not enough to establish temporal quality.

## Common problems

| Symptom | First thing to check |
| --- | --- |
| No DX10/11 import detected | Pick the real game executable. For a known dynamically loaded DX10/11 renderer, use the explicit API override. |
| Existing mod files reported | Preserve and move the old graphics mod aside. This toolkit does not merge an unknown injector stack. |
| No ReShade banner/log | Correct executable directory, enabled state and x86 proxy. Some games block injection. |
| Black/stale/partial depth | MSAA, selected depth surface, clear timing, and global depth convention. |
| Shader compile error | ReShade log and complete include files; verify package integrity. |
| 300/300 but feature 18 absent | DLAA ran, but neural rendering did not. Inspect the host's ReShade log. |
| Host works, game does not | Game-side depth, shaders, API and transport still require validation. |
| Frame counter advances but visible warping | Inspect motion/depth guides and compare styles/intensity; optical flow has limits. |
| Low FPS | Compare 100% with 75% work resolution. Do not assume an FPS improvement over the unmodded game. |
| Store launcher required | Use Enable only, launch through the store, then Disable after exiting. |
| Automatic disable failed | Close the game and helper, then choose Disable. Do not start another executable in that folder while the proxy remains. |

Check setup and CollectLogs produce local reports only. Review paths/account identifiers before attaching logs to a public issue.
