# Devices & Real Events — Forelock 0.5.4

Branch `feature/devices-live-events`, based on accepted 0.5.3 / `856061d`. The installed local build is Release: device acceptance uses actual system state and physical actions, not diagnostic events.

## Evidence and public APIs

**PowerSourceMonitor** reads only the internal battery from `IOPSCopyPowerSourcesInfo`, `IOPSCopyPowerSourcesList` and `IOPSGetPowerSourceDescription`. Percentage is current/max capacity, validated before display. `kIOPSPowerSourceStateKey`, `kIOPSIsChargingKey` and `IOPSCopyExternalPowerAdapterDetails` are distinct evidence: external power is not automatically called charging. Missing/invalid fields stay unknown. An `IOPSNotificationCreateRunLoopSource` on the main run loop updates on system notifications; no periodic power polling is introduced.

**AudioDeviceMonitor** enumerates live Core Audio devices with output streams, names and stable UIDs. The default media output comes from `kAudioHardwarePropertyDefaultOutputDevice`. Property listener blocks observe the system device list/default output, device liveness, output streams and names. In the existing Settings, selecting an output revalidates the UID and the property's settable status, then calls `AudioObjectSetPropertyData`. This changes the default media output, not a separate alert-sound route or an app's explicit per-app override.

Classic Bluetooth evidence is separate: public `IOBluetoothDevice.pairedDevices`, audio device class, cached name and `isConnected`. Public connect and per-device disconnect notifications trigger a fresh snapshot. There is no discovery, pairing, connection request, BLE scan, audio capture or remote name request. Denied/restricted Bluetooth access produces unknown connection evidence; Core Audio output tracking remains independent. Addresses are only in-memory identity tokens, never labels, persistent preferences or diagnostic logs. A missing name/class/permission may prevent connection-specific events; a confirmed Core Audio change can still truthfully say “Аудиовыход”.

Core Audio output changes **never** imply a Bluetooth connection. If both arrive in the same settled update, the output wording wins rather than issuing duplicate messages. If Bluetooth connection changes without a route change, the separate verified connection wording is used. AirPods' name does not authenticate a particular hardware model.

**AirPods charge is disabled.** The supported paths above do not provide a reliable public per-ear/case percentage. No private selectors, undocumented power-source accessory keys, private frameworks, injected code or guessed percentages were added. This is a limitation of this implementation's verified APIs, not a claim that macOS itself cannot display AirPods charge.

Primary references: [IOPS notifications](https://developer.apple.com/documentation/iokit/1523868-iopsnotificationcreaterunloopsou), [Core Audio property listeners](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:)), [IOBluetoothDevice](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice). Implementation was also checked against the public macOS SDK headers `IOPowerSources.h`, `IOPSKeys.h`, `AudioHardware.h`, `AudioHardwareBase.h`, and `objc/IOBluetoothDevice.h` in Xcode 16.3.

## DeviceEventAdapter and presentation

The adapter compares settled normalized snapshots and feeds the existing LiveSurfaceEngine. Monitor callbacks settle for 0.2 s (audio); a 0.65 s adapter debounce groups nearby power/audio changes into one Stretch. Changes after the grouping window queue normally: equal-priority P2 events do not preempt the current Stretch. New state replaces a pending event of the same kind without restarting its display deadline. TTL is eight seconds; existing queue/capacity bounds still apply.

First data, recovery from unknown data, and a two-second startup settle establish baselines without connect events. Sleep cancels pending events, clears device indicators and resets comparison state. Wake resynchronizes for three seconds; the final asynchronous audio read is also explicitly a baseline. These are bounded startup/wake reads, not perpetual polling. All listener blocks, Bluetooth notifications, run-loop sources, workspace observers and delayed work are cancelled/unregistered on stop. Late asynchronous results have a generation guard.

Low-charge crossings at 20% and 10% produce P1 warning Stretch. Normal percentage or charging-flag changes only update current data. Hysteresis prevents repeated warnings near a threshold; returning to external-supply mode or recovery to 25% rearms them. Returning to battery while already below a threshold also warns. An attached but insufficient adapter never hides a genuinely low discharging battery. Starting already low leaves real compact attention without a fabricated threshold-crossing Stretch. Clearing the low state removes its retained attention.

P0 Workspace/Mini/Quick Look/file drag remains unconditional. Suppression is remembered at receipt, so closing a workspace before the debounce expires does not replay the event. P1 may retain compact attention, P2 is discarded. Fullscreen automatic expansions retain the existing default-off policy. Explicit output selection inside Settings also suppresses its delayed automatic reaction.

Stretch uses measured text widths, equal camera-safe shoulders and the existing fixed top-center anchor, with a bounded width and single-line truncation for unusually long names. It lasts 2.5 seconds and returns to the **current** Ambient. No new window, tabs or Peek-based device notifications are introduced. NotchGeometry, SurfaceSpring, hover policy, file handling and music providers remain unchanged.

## Ambient and settings

Auto does not fill slots with an idle battery or the mere existence of a speaker. Playing music remains the first background activity. Real low-charge attention can appear automatically. Explicit **Батарея MacBook** pins the actual percentage/status. **Текущий аудиовыход** pins the current known output's name/icon, including internal speakers if selected. Unavailable data leaves the slot empty and disables its setting option. Duplicate slots never show the same battery/music/device category twice. Both Auto with no activity returns to Silent.

Settings remain in the existing surface's scrollable left column. There are actual power data, an output selector and confirmed Bluetooth audio connections. No additional player or device window is created. Old raw slot preferences are compatible; user data formats are unchanged.

## Acceptance and rollback

See the [actual verification matrix](../chelka-lab/native/ACCEPTANCE.md); unit fixtures are explicitly separate from real hardware acceptance. Cable attachment, real AirPods connection, sleep/wake and system Finder gestures require a person where the automation tool cannot reproduce them.

The accepted installed 0.5.3 bundle is preserved locally at `chelka-lab/native/artifacts/rollback-0.5.3/Forelock.app`. Quit Forelock, run `./chelka-lab/native/scripts/rollback-0.5.3.sh`, then open `~/Applications/Forelock.app`. The script verifies the backup and refuses to replace a running app. Shelf storage is untouched. On another Mac, build `feature/live-surface-core` at `856061d` in a separate checkout.
