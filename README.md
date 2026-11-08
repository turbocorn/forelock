# Forelock

Native macOS notch interface, SwiftUI + AppKit. **0.5.5 — Live Surface UX & Motion**, developed on `feature/live-surface-polish` from accepted `feature/devices-live-events` (`1bb43b0`). The 0.4.1 MediaRemote providers are retained. The accepted 0.3.2 baseline is preserved on `main` and tagged `v0.3.2-stable`.

The existing project remains in `chelka-lab/` to preserve its working paths. There is one Git repository, at this directory. The React motion prototype is archived reference material; the native application lives in `chelka-lab/native/`.

```sh
./chelka-lab/native/scripts/build.sh
./chelka-lab/native/scripts/test.sh
ditto chelka-lab/native/build/Forelock.app "$HOME/Applications/Forelock.app"
open "$HOME/Applications/Forelock.app"
```

Requires macOS 14+ and Xcode with Swift 6. Build products, diagnostic captures, local Finder fixtures, browser profiles, shelf files and signing credentials are excluded from Git. Historical verification documents may refer to captures kept only on the original development Mac.

Quit the running Forelock before replacing its bundle. Keep only one running copy: the bundle identifier and existing shelf data location are retained from «Чёлка».

Apple Music uses public Apple Events addressed to an already running Music.app; Forelock never launches Music. Yandex Music and Zvuk in Chrome use the local MV3 extension and Native Messaging helper. Yandex Desktop uses an explicitly authorized, local-only MediaRemote experiment in an isolated Perl child. It appears only while the confirmed system source is `ru.yandex.desktop.music`; global commands retain a non-atomic source-switch race. Zvuk has been verified with real guest previews; full authenticated playback remains unverified.

- [Live Surface composition and motion polish](docs/LIVE-SURFACE-POLISH.md)
- [Real device events, evidence and limitations](docs/DEVICES-LIVE-EVENTS.md)
- [Live Surface: presentation, real inputs and Debug diagnostics](docs/LIVE-SURFACE.md)
- [Shelf multi-selection and group drag-out](docs/SHELF-SELECTION.md)
- [Mini shelf: preview, drag-out and return](docs/MINI-SHELF.md)
- [File Drop 2.0: activation and limits](docs/FILE-DROP-2.md)
- [Product foundations: Clipboard/Shelf, Media, Live Activities](docs/PRODUCT-FOUNDATIONS.md)
- [Native app, geometry and file shelf](chelka-lab/README.md)
- [Chrome extension installation](docs/CHROME-INSTALL.md)
- [Provider architecture and limitations](docs/MUSIC-PROVIDERS.md)
- [Actual 0.5.5 verification matrix](chelka-lab/native/ACCEPTANCE.md)
- [Yandex Desktop experiment and rollback](docs/YANDEX-DESKTOP-EXPERIMENT.md)
- [Preserved 0.4.0 verification](chelka-lab/native/ACCEPTANCE-0.4.0.md)

The stable top geometry, hover policy, storage and Finder drag-out code are retained; incoming file drop now uses a temporary wider destination. Music metadata is never substituted with demo tracks. No backend is used. The private MediaRemote dependency is pinned and confined to a disposable helper; this build is not ready for public distribution. Disable it in Settings, or quit Forelock and run `./chelka-lab/native/scripts/rollback-0.5.4.sh` to restore the preserved local 0.5.4 app.

File Drop 2.0 temporarily enlarges the existing panel’s native destination during an observed mouse drag near the notch; only file URLs from NSDraggingInfo reveal the visible drop surface. Clipboard, Live Activities and a new Expanded layout are not implemented. Device power/audio events are documented separately. The working local 0.4.1 bundle is preserved in `chelka-lab/native/artifacts/rollback-0.4.1/Forelock.app`.

Successful drops now show actual newly imported Shelf items in the same compact surface. Up to four are visible (three plus +N for larger batches). Click for existing Quick Look, drag out through the existing native source, or choose All Files for the pinned Shelf. The result remains while hovered/interacting; leaving for 0.8 seconds restores a previous pinned context or collapses.

Full and mini Shelf now support Command-click selection, scoped Command-A, Escape to clear first, and native multi-item copy drag-out. Shift-click selects a range in the full Shelf. Normal clicks retain Quick Look. Selection is transient; storage and original Finder files are unchanged.

Live Surface is an independent presentation layer: Silent / Ambient / Stretch / Peek / Workspace. Selected real playing music supplies a static camera-safe Ambient indicator. Workspace, Mini Shelf and native drag have unconditional priority; file completion is already shown by Mini and is not duplicated. Fullscreen automatic expansion is off by default. Slots are configurable without inventing unconnected device data.

The installed 0.5.5 app is Release. IOKit power notifications and Core Audio/IOBluetooth listeners supply real events; no diagnostic event is used for device acceptance. Debug builds still retain the isolated 0.5.3 diagnostics for development. Release excludes them. Battery and current audio output can be pinned in the existing slot settings; normal percentage updates do not expand the surface. AirPods/case battery percentages remain unavailable and disabled.

0.5.5 measures the two painted shoulders independently while retaining the camera-centred panel anchor. A single Ambient indicator adds only one visible shoulder. Stretch keeps the physical notch height; Peek is content-sized with one action. Existing event arbitration and inputs are unchanged. Captures and manual/automatic evidence are separated in the current acceptance report; final visual acceptance belongs to the user.

Accessory battery 0.5.6 is being validated on `feature/accessory-battery` from `aab4517`; 0.5.5 remains the accepted baseline. AirPods L/R and Magic Mouse have real evidence, but the final installed candidate is awaiting a Bluetooth authorization/readiness check. See [research and limitations](docs/ACCESSORY-BATTERY.md) and the [current verification report](chelka-lab/native/ACCEPTANCE.md). It is not declared accepted.
