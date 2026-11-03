# V3 validation — 2 November 2026

## Passed checks

- 45 existing regression checks and 25 v3 checks (70 total).
- H.264 and H.265 canonical packet hashing; decoded sample comparisons; byte mutation in an actual video; changed hashes, removed/reordered packets and modified timestamps are rejected.
- Duration splitting across keyframes and recording gaps, including H.265 B-frame timing. Unsupported fast codecs require explicit detailed-mode selection.
- Fast merged verification reuses packet caches; detailed merged verification reuses decoded caches. Both verify the final output.
- Windows PowerShell 5.1 readiness check loads Toolkit and reads a real database record without installing the SDK. Native Thai UI preview and syntax checks passed.
- Source XML/index SHA-256 checksums remained unchanged. Current output codec, dimensions, color/aspect metadata were checked against the source export.

## Actual 10-minute 1080p benchmark

Measured sequential verification modes on the same machine and local disk, using 14,998 packets:

| Verification mode | Seconds |
|---|---:|
| All compressed packets + decoded sample windows | 8.34 |
| Every decoded frame | 260.61 |

Fast verification used 3.2% of detailed verification time, meeting the <=25% target. This measures verification, not total conversion. Results depend on storage and hardware.

## Full-duration sample

One local two-hour sample was freshly scanned and exported through Toolkit, remuxed to a single MP4, and verified in stream_sample mode. The recording, output, report, and recording-specific hashes/metadata are not included in this public repository.

- Final status: verified.
- All canonical packet hashes and presentation/decoding timestamps matched.
- Sampled decoded frames from the beginning, middle, end, and around recording gaps matched between source and output.

| Stage | Seconds |
|---|---:|
| Database timeline scan | 47.73 |
| Toolkit export | 494.26 |
| Packet inspection | 52.50 |
| MP4 remux/write | 262.38 |
| Canonical packet verification + decoded samples | 115.22 |
| **Total** | **972.12** |

The full test took about 16.2 minutes on the test machine. Toolkit export and MP4 writing remain substantial costs. The original recording and its reports remain local and are excluded from this repository and distribution ZIPs.

## Limits

Fast mode does not decode every frame; it proves compressed packet preservation and validates selected decoded windows. Full decoded verification remains available. No second physical machine, another real export version/period, or vehicle-counting application was available here, so compatibility with those environments is not claimed.
