# BáchCut Studio

Native iOS video editing MVP built in SwiftUI and AVFoundation.

Features: import videos from Files, reorder, trim, playback preview, MP4 export, responsive portrait / landscape timeline.

## Build unsigned IPA
GitHub Actions → `Build BáchCut Studio IPA` → Run workflow. The workflow installs XcodeGen, builds iOS on macOS and uploads unsigned IPA as artifact. Sign before installation using your own signing certificate.

**Status:** Work-in-progress MVP; full CapCut-style multi-track editing and AI functions are not yet implemented.

## Public Actions build
Repository visibility was changed to public. This commit triggers a fresh push build to test macOS runner availability and compilation.
