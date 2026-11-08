# Forelock

Native macOS notch interface, SwiftUI + AppKit. **0.4.0 — Music Integration**, developed on `feature/music-providers`. The accepted 0.3.2 baseline is preserved on `main` and tagged `v0.3.2-stable`.

The existing project remains in `chelka-lab/` to preserve its working paths. There is one Git repository, at this directory. The React motion prototype is archived reference material; the native application lives in `chelka-lab/native/`.

```sh
./chelka-lab/native/scripts/build.sh
./chelka-lab/native/scripts/test.sh
ditto chelka-lab/native/build/Forelock.app "$HOME/Applications/Forelock.app"
open "$HOME/Applications/Forelock.app"
```

Requires macOS 14+ and Xcode with Swift 6. Build products, diagnostic captures, local Finder fixtures, browser profiles, shelf files and signing credentials are excluded from Git. Historical verification documents may refer to captures kept only on the original development Mac.

Quit the running Forelock before replacing its bundle. Keep only one running copy: the bundle identifier and existing shelf data location are retained from «Чёлка».

Apple Music uses public Apple Events addressed to an already running Music.app; Forelock never launches Music. Yandex Music and Zvuk in Chrome use the local MV3 extension and Native Messaging helper. The Yandex desktop app is not connected. Zvuk has been verified with real guest previews; full authenticated playback remains unverified.

- [Native app, geometry and file shelf](chelka-lab/README.md)
- [Chrome extension installation](docs/CHROME-INSTALL.md)
- [Provider architecture and limitations](docs/MUSIC-PROVIDERS.md)
- [Actual 0.4 verification matrix](chelka-lab/native/ACCEPTANCE.md)
- [Desktop Yandex research for 0.4.1 — not released](docs/YANDEX-DESKTOP-RESEARCH.md)

The stable geometry, hover policy and Finder drag code are retained. Music metadata is never substituted with demo tracks. No backend or private MediaRemote API is used.
