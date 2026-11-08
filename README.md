# Forelock

Native macOS notch interface, SwiftUI + AppKit. Stable baseline: **0.3.2**, tagged `v0.3.2-stable`.

The existing project remains in `chelka-lab/` to preserve its working paths. There is one Git repository, at this directory. The React motion prototype is archived reference material; the native application lives in `chelka-lab/native/`.

```sh
./chelka-lab/native/scripts/build.sh
./chelka-lab/native/scripts/test.sh
```

Requires macOS 14+ and Xcode with Swift 6. Build products, diagnostic captures, local Finder fixtures, browser profiles, shelf files and signing credentials are excluded from Git. Historical verification documents may refer to captures kept only on the original development Mac.

Music integration is developed separately on `feature/music-providers`. The stable tag preserves the accepted notch geometry, hover policy and file shelf.
