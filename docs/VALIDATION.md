# Compatibility and validation

Record date: 2026-09-09 UTC. Public draft: 0.2.0-beta.1.

## Eligible routes versus tested games

| Route / game | Current evidence |
| --- | --- |
| Generic x86 D3D11 executable | Import detection and reversible setup tested with synthetic fixtures |
| Generic x86 D3D10 executable | Import detection tested; upstream Feeder supports this backend; no local game test yet |
| Black Ops II campaign, x86 D3D11 | Actual ReShade/Feeder/NGX/NR path ran; details below |
| Other titles | No local end-to-end claim |
| DX9 / Vulkan / OpenGL | Not automated by this toolkit |
| x64 game executables | Refused; this toolkit targets x86 games |

## Black Ops II bring-up

Hardware: RTX 5060 Ti, 16,311 MiB reported VRAM, driver 616.56. Components match the locked rendering stack: ReShade 6.8.0, Feeder 0.14.0-beta.5, classic RenoDX 4.55, original NVIDIA 310.8.0 NR/SR.

Confirmed from local files/logs:

- The standalone host completed **300/300** evaluations and separately logged feature-18 creation and successful neural evaluation.
- ReShade loaded as **32-bit into t6sp.exe**, using D3D11.
- Kernel, DisplayDepth, and the matching Feeder shader compiled.
- The game selected **Lumenite Kernel / provider 3**, connected to the 64-bit helper, and delivered frames.
- The helper logged feature-18 creation and successful evaluation at **2560×1440**.
- The session reached **118,800 delivered/evaluated frames**. About 54 minutes elapsed between initial ReShade initialization and game exit, with settings changes and host restarts during that period.
- The launch wrapper collected the session logs and parked the mod after exit. The original executable hash remained unchanged.
- No fault matched the toolkit's explicit crash/device-removal/evaluation-failure patterns in the inspected session logs.

This was **not a controlled benchmark**. Late-session samples reported approximately 33–36 fps and roughly 22 ms of host DLSS GPU work at 100% work resolution. Scenes/settings changed, so those samples are not a predicted frame rate for other users.

Still unverified: correct gameplay depth/orientation, a controlled motion-guide test, split-frame transport visualization, matched-camera A/B captures, and representative visual-quality/stability assessment. An earlier screenshot showed the useful scene depth was multisampled; that is why MSAA-off and depth verification remain part of first-run setup.

The BO2 bring-up used the earlier prototype's directory/profile names. The generalized public launcher and its D3D10 path have file-level tests, not a new live game test. We do not relabel prototype evidence as a test of the new menu.

## Tooling checks

The Windows tests use synthetic PE files and isolated dummy game directories. They cover x86/x64 recognition, DX10/11 imports, unknown/unsupported API rejection, malformed PE data, path/junction containment, conflicts, corrupted components, enable/disable, modified-config preservation, rollback, fresh/stale log evidence, CLI setup, and host-test cache invalidation.

The rendering dependencies' hashes and NVIDIA signatures were verified locally. The source archive is built from an explicit allowlist and excludes binaries/models, downloaded shaders, game files, saves, raw logs, and personal paths.

Raw session logs remain local. Only these limited observations are prepared for publication; no private log or screenshot has been posted.
