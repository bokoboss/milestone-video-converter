# Local FFmpeg tools

This public source repository does not include the FFmpeg/FFprobe executables. To run a source checkout, obtain the Windows x64 Essentials build matching `manifest.json`, place `ffmpeg.exe` and `ffprobe.exe` in this directory, and run `setup.bat`. Setup checks the exact SHA-256 hashes and will reject different builds.

The tested build is FFmpeg 9.0.2 Essentials x64 from [Gyan's build page](https://www.gyan.dev/ffmpeg/builds/). FFmpeg binaries are GPL-3.0-or-later; see the included `LICENSE` and `FFmpeg-README.txt`. The complete portable converter bundle is distributed separately and includes these files.
