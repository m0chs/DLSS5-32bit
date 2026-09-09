# Credits and component provenance

This repository contains a general installation/launch/validation toolkit. The neural-rendering bridge and rendering components are upstream work.

| Project / author | Contribution | Source |
| --- | --- | --- |
| crosire / ReShade | x86/x64 graphics injection and effect framework | [ReShade](https://reshade.me/), [source](https://github.com/crosire/reshade) |
| ReShade shader contributors | Framework headers and DisplayDepth | [Pinned shader tree](https://github.com/crosire/reshade-shaders/tree/6db142b4b1a05c764222e5b0bd9a644b7ccfe1dc) |
| Jean-Laurent Rouzies / DLSS5-Feeder | x86 client, shared-resource/IPC bridge, x64 helper and guide shader; MIT | [Project](https://github.com/jlrouzies-fr/DLSS5-Feeder), [matched release](https://github.com/jlrouzies-fr/DLSS5-Feeder/releases/tag/v0.14.0-beta.5) |
| Afzaal (Kaidō) / LumeniteFX | Optical flow and confidence; AGNYA | [Pinned source](https://github.com/umar-afzaal/LumeniteFX/tree/f8cbbb4eccfcb7adf0d74bb358ba349272e3c1e9), [license](https://github.com/umar-afzaal/LumeniteFX/blob/f8cbbb4eccfcb7adf0d74bb358ba349272e3c1e9/LICENSE.md) |
| RenoDX DLSS5 authors / community | Neural consumer, classic 4.55 binary | [Community release source](https://github.com/RankFTW/rhi-repo/releases/tag/renodx-dlss5-4.55) |
| NVIDIA | Original 310.8.0 NR/SR runtimes and model | [NR asset](https://github.com/RankFTW/rhi-repo/releases/tag/dlssnr-310.8.0), [SR asset](https://github.com/RankFTW/rhi-repo/releases/tag/dlss-310.8.0) |
| Faisal Kindi / DLSS5oneclick | Reference installer and related setup work | [Project](https://github.com/faisalkindi/DLSS5oneclick) |

The extraction approach and host layout were developed with reference to DLSS5-Feeder's MIT-licensed installer. Its notice is retained in [licenses/DLSS5-Feeder-MIT.txt](licenses/DLSS5-Feeder-MIT.txt).

The toolkit's MIT license covers its own source, not the downloaded components. LumeniteFX is fetched unchanged from its author's repository with its LICENSE.md and NOTICE accompanying the private installed copy. NVIDIA/RenoDX binaries and third-party shader implementations are excluded from the public source ZIP.

The NVIDIA files are original signed builds retrieved from the linked community release mirror. Signatures and hashes establish file identity; this is not an official NVIDIA distribution or game-developer integration. The toolkit does not patch GPU restrictions, modify game code, or bypass DRM/anti-cheat.
