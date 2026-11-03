# Third-party components

The public GitHub source repository excludes the FFmpeg/FFprobe executable files. The ready-to-run portable bundle contains them separately. Do not add those binaries to this repository unless the corresponding GPL source and build materials are also provided.

## FFmpeg / FFprobe

- Tested version: `9.0.2-essentials_build-www.gyan.dev`, Windows x64 static build. Its SHA-256 values are recorded in `tools/manifest.json`.
- Publisher/build provider: https://www.gyan.dev/ffmpeg/builds/
- Download page: https://www.gyan.dev/ffmpeg/builds/ (select the matching 9.0.2 Essentials x64 archive)
- Upstream source commit stated by the build provider: https://github.com/FFmpeg/FFmpeg/commit/946fcce07b
- License: GNU GPL version 3 or later. Full license: `tools/LICENSE`.
- Original build README/configuration: `tools/FFmpeg-README.txt`.
- Binary SHA-256 values expected by setup: `tools/manifest.json`.
- No modifications were made to these executables. They are invoked as separate processes. Setup downloads missing tools directly from Gyan. Conversion runs offline.

Retain these notices and the license with copied bundles. For redistribution beyond the user's own machines, obtain the complete corresponding source and build/dependency materials required by the GPL from the build provider; a link to upstream FFmpeg alone is not a complete source bundle.

## Milestone / VideoOS

The converter does **not** redistribute or decompile Milestone software in its distributable package. It uses `VideoOS.Toolkit.dll` and its dependencies from the complete original recording export selected by the user. The original Player binaries remain subject to Milestone's terms. Keep that export intact when moving it to another authorized machine.

Tested export's Client product version: 11.2.3116.1; its Toolkit is x86 and has no file version resource. Other exported Player versions are checked per job but require testing. No SDK installer or server connection is used.

Reference: https://doc.developer.milestonesys.com/mipsdk/gettingstarted/intro_analytics.html

