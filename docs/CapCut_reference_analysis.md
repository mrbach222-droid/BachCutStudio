# BáchCut Studio — CapCut 12.6.0 reference analysis

> Engineering notes for clean-room, native implementation. The reference package is used to inventory *types* of functionality and performance requirements. Do not import its executable code, shaders, proprietary effects, copyrighted UI assets, or in-app branding.

## Inspected package (metadata only)

- Supplied archive: `CapCut PRO_12.6.0_1736747890(1).ipa`.
- Container: iOS app `Payload/CapCut.app`; Info.plist advertises version **12.6.0**, bundle identifier `com.lemon.lvoverseas`.
- Archive: ~147.5 MB compressed, ~299 MB uncompressed, ~4,344 archive entries.
- Bundles including `LVEditor`, `LVEditorCommon`, `LVExport`, `LVMaskEditor`, `Retouch` and `VEMetalBinary_iOS` indicate a broad editor, export, masking, retouch and Metal resource stack. These are **name-based clues**, not proof of any internal algorithms.
- Resources include .metallib, .frag, .vert, .xshader, .lua, .json, .scene and many image assets. Metal resource names mention HDR/SDR color-space conversion and Lanczos texture filtering.
- **Security:** additional dylibs named `iOSGods`, `SatellaJailed`, `libsubstrate`, `patcher` appear in this supplied package. Treat it as an **untrusted, modified build**. No binaries were executed; this file must not be used as a runtime dependency.

## Feature mapping and implementation status

| Capability | BáchCut 0.6.0 baseline | Target |
| --- | --- | --- |
| Centered vertical playhead, inertial scrub | Implemented | Stable, frame-accurate seek with cached filmstrip |
| Clip reorder by long-press | Implemented | Smooth autoscroll, preserve playhead, precise drop target |
| Sequential filmstrip thumbnails | Implemented (up to 20 frames/clip) | Adaptive density, async cache, reduced memory overhead |
| Timeline timecode + magnetic cut snapping | PR #1 implementation, awaiting CI | User setting, tactile confirmation and precise scrub |
| Multi-track composition | Main video, overlay and audio supported | Arbitrary multi-layer clips, editable track positions and trimming |
| Transitions and keyframes | Missing | AVFoundation/Core Animation/Metal clean-room rendering |
| Text, subtitles and captions | Missing | Native text tracks and timed captions, later speech recognition |
| Fast preview | Simple composition direct playback; composed preview rendered to temporary file | Incremental preview, Metal-backed real-time compositor for interactive edits |
| Export | MP4/MOV H.264/AAC and GIF | Capability-tested HEVC/H.264, 480p–4K, variable fps/bitrate, GPU support when available |
| Landscape Pro | Available | Multi-track gestures and per-orientation editing layout |
| Save and undo | Available | Crash-recovery journals and media garbage collection |

## Performance and correctness requirements

1. Time to first displayed preview frame, median and p95 for 1080p/4K input.
2. Scrub-to-preview latency, p95 under sustained finger drag; do not claim CapCut parity without measurements.
3. Reorder from beginning to end with >20 clips, no media loss or unexpected playhead jumps.
4. Export end-to-end: frame count, frame presentation timestamps, audio presence, final duration, device compatibility and cancellation cleanup.
5. Measure iPhone memory, thermal throttling and rendering performance before calling builds stable.
6. Keep unsigned IPA releases gated on green XCTests and UI tests; signing and device installation require the user's own certificate.

## Clean-room implementation rule

This note records feature categories and visible interaction targets only. Reimplement in Swift/SwiftUI, AVFoundation, Core Animation and documented Metal APIs using original code. Do not redistribute any portion of the supplied IPA or extract proprietary code/assets for reuse.
