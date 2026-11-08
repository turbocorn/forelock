# Live Surface Core — 0.5.3

This document describes the accepted 0.5.3 core. Real device sources, enabled device/battery slots and content-driven widths were added in [0.5.4](DEVICES-LIVE-EVENTS.md). The current installed 0.5.4 is Release; the Debug-only examples below remain development tools.

`feature/live-surface-core`, based on accepted 0.5.2 (`c865d33`). The existing NotchState still owns Hover, Overview, Shelf, Mini Shelf, Quick Look and Settings. Live Surface only selects a presentation while the workspace is closed. One NSPanel, the existing outline, screen-top anchor and interruptible SurfaceSpring remain responsible for geometry. Reduced Motion uses the existing immediate geometry path.

## Presentation

- **Silent**: no painted surface outside the hardware notch.
- **Ambient**: static camera-safe shoulder indicators; no per-frame playback animation. Auto uses real current activity, with one music indicator for the selected playing source. Empty second slots stay empty.
- **Stretch**: horizontal expansion for 2.5 seconds at hardware-notch height; returns to the current ambient state.
- **Peek**: compact downward expansion with actual event details/action. Six seconds, held while engaged, always bounded by the event TTL. Close dismisses the current event. Opening Shelf enters the normal pinned workspace.
- **Workspace**: the existing explicit interaction states, never replaced by an automatic event.

Settings provide each shoulder with Auto / Music / Files / Activities / Devices / Nothing. Files uses the actual shelf count only when explicitly selected; existing stored files do not create background activity in Auto. Activities can show Forelock's real error attention, not unconnected agents or timers. Devices is labelled unavailable and disabled. Duplicate choices never duplicate an event. Both Nothing disables ambient indicators; explicit workspace remains available.

## Arbitration

P0 (workspace, real incoming drag, Mini, Quick Look, shelf operation and outgoing drag) is context, not a queued event. It suppresses expansion immediately. P1 reactions preempt P2 information. P3 activity only occupies ambient slots. A P1 event suppressed by P0 can retain compact attention until expiry; P2 is discarded rather than replayed after closing the workspace. Entering fullscreen also suppresses Stretch/Peek by default, with a separate opt-in setting.

Events carry source, stable key, priority, creation/expiry, strategy, category and optional action. Same source/key coalesces, without restarting its display time. Maximum eight stored events, three pending transients, 120-second maximum TTL. No persisted queue or music metadata. Expired/oversized/invalid events are rejected. Music heartbeats replace the same selected-source event; stale, paused, stopped or missing snapshots remove it. No source selection or commands are added here.

## Real vs diagnostic

Production input is only the existing MusicCoordinator and ShelfModel. Track/source changes update Ambient without Stretch. Shelf operation completion reaches the engine but is marked already handled by Workspace/Mini; errors become bounded attention while the existing shelf continues to show the actual error. No additional completion banner overlays Mini Shelf.

Stretch and Peek mechanisms can be exercised from the status menu **Live Surface · диагностика** only in a Debug build. Titles explicitly say “Тест”; these are isolated diagnostic events, not simulated product integrations. Available cases: Stretch, Peek with Open Shelf, P1 over P2, three duplicate events, attention, clear. The same Debug-only events are exposed as named accessibility actions for native acceptance tools when the surface has a container; no new visible diagnostic controls or window are added. Release builds have neither this menu nor diagnostic entry points. There are no production device/agent/timer notifications in this version.

```sh
# Default, no diagnostic events
./chelka-lab/native/scripts/build.sh
# Local acceptance build, labelled Debug in its status menu
./chelka-lab/native/scripts/build.sh --debug
```

The installed local 0.5.3 acceptance bundle is Debug so these modes can be tested before additional sources exist. A separately built Release bundle remains in ignored `native/artifacts/0.5.3/release/Forelock.app` on this Mac.

## Input and resource limits

Ambient and Stretch are informational and remain click-through outside the accepted hardware activation region. Peek accepts input only within its actually painted silhouette, excluding the camera and rounded corner voids. It does not enlarge the invisible capture canvas. The File Drop 2.0 temporary native destination and its real NSDraggingInfo validation are unchanged. No global pasteboard detection was introduced.

UI payload excludes heartbeat timestamps and position. Identical snapshots do not publish a new presentation. Expiry arbitration is deadline-driven within the existing controller timer; no additional perpetual timer, animation or window is created. Fullscreen detection uses the existing public window bounds heuristic and retains its limitations. Automatic events are not system notifications and are not persisted.

## Rollback

Quit Forelock through its status menu, run `./chelka-lab/native/scripts/rollback-0.5.2.sh`, then open `~/Applications/Forelock.app`. The script verifies the preserved accepted bundle and refuses to replace a running app. Storage format and existing files are unchanged. The backup is local/ignored: `native/artifacts/rollback-0.5.2/Forelock.app`. A fresh machine can build accepted `feature/shelf-multi-selection` at `c865d33` in a separate checkout.

See the [actual acceptance matrix](../chelka-lab/native/ACCEPTANCE.md) for observed vs still-manual scenarios. Tests and renders are not a substitute for a physical Finder gesture.
