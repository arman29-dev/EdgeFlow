# Edge Flow

A small macOS menu-bar app (personal use). While media is playing:

- **Two fingers sliding up/down on the right edge** of the built-in trackpad → **volume**
- **Two fingers sliding up/down on the left edge** → **built-in display brightness**

Everywhere else the trackpad behaves normally. No account, no network, no telemetry.

> **Read this first: this code has not been compiled or run.**
> It was written on a Linux machine with no Swift toolchain, so nothing here has been built, type-checked or tested
> on a Mac. It is written carefully and the pure logic has unit tests, but expect that `swift build` may report a
> few compiler errors on the first try. If it does, the fixes are normally one-liners; paste the first errors back
> to me and I will correct them. The hardware parts (trackpad, brightness, haptics, media detection) also depend
> on undocumented Apple frameworks that have to be checked on your actual Mac: run the probe (below) first.

## Requirements

- Apple Silicon MacBook with a built-in trackpad, **macOS 14.2 or later**
- **Xcode 15.1 or later** (recommended; gives you the SDK and XCTest). The Command Line Tools alone can build, but may not be able to run the tests.

## Build and run (about 2 minutes)

```bash
unzip TrackpadEdgeGestures.zip
cd TrackpadEdgeGestures

# 1. Run the unit tests (pure logic, no hardware):
scripts/test.sh

# 2. Check the hardware parts on THIS Mac (touch the trackpad when asked):
scripts/probe.sh

# 3. Build the app and install it to ~/Applications:
scripts/build_app.sh --install
open ~/Applications/TrackpadEdgeGestures.app
```

Prefer Xcode? `open Package.swift`, choose the `TrackpadEdgeGestures` scheme, press Run. (Launch at Login only works from the built `.app`.)

A gesture icon appears in the menu bar (no Dock icon). Open **Settings…** from its menu.

### Stable signing (strongly recommended)

macOS ties Accessibility / Input Monitoring permissions to the app's code signature. The default build uses an
ad-hoc signature, which changes on every rebuild, so macOS would forget the permission each time.

1. Open **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `TrackpadEdgeGestures Dev`, Identity Type: *Self Signed Root*, Certificate Type: *Code Signing*, create it.
3. Build with it: `SIGN_IDENTITY="TrackpadEdgeGestures Dev" scripts/build_app.sh --install`

## What the probe tells you

`scripts/probe.sh` prints, for your Mac: whether trackpad contact data arrives (and whether `y` increases when fingers
move up, and `x` is near 1.0 on the right edge), whether brightness can be read and set (it nudges 1% and restores),
the default output device's volume capability, a haptic pulse, and which processes are producing audio.

Zero trackpad frames usually means macOS wants **Input Monitoring** for the process: add Terminal (for the probe) or the app
under System Settings → Privacy & Security → Input Monitoring.

If `y` decreased when you moved up, turn on **Settings → Gestures → Invert direction**.

## Using it

1. Play something: Music or Spotify (detected reliably), or any app producing audio for 2+ seconds (approximate).
2. Put two fingers on the right edge (outer 15%), slide up or down.
3. Nothing playing but you want it anyway? Menu bar icon → **Manual override** (15 min / 1 hour / until turned off).

Menu-bar icon states: *active*, *waiting for media*, *manually enabled*, *paused*, *missing permission*, *unsupported*.

### Permissions

| Permission | Needed for | If you decline |
|---|---|---|
| Accessibility | Stopping the page from scrolling while you adjust, and the modifier fallback mode | Turn off *Stop the page scrolling…* in Settings; everything else works |
| Input Monitoring | Only if the probe shows trackpad data does not arrive without it | — |

Never requested: microphone, camera, screen recording, network, automation.

### Known conflict: Notification Center

macOS opens Notification Center with a two-finger swipe in from the right edge. Gestures that start at the very edge and
move sideways can trigger it. If that bothers you: System Settings → Trackpad → More Gestures → *Notification Centre*: off.

## How it decides media is playing

macOS has **no universal "media is playing" signal.** This app uses, in order:

1. **Music and Spotify** play/pause notifications: reliable (*verified*).
2. **CoreAudio per-process output activity** for everything else: *approximate*. It cannot tell a paused session or a
   muted video from real playback, excludes known call apps (Zoom, Teams, FaceTime…) and anything while the microphone
   is in use, and ignores sounds shorter than 2 seconds.
3. **Manual override** from the menu.

If the state is unknown or unavailable, gestures stay **off**.

## Layout

```
Package.swift
Sources/TEGCore/               pure logic: settings, gesture state machine, media gate, haptic policy (unit tested)
Sources/TrackpadEdgeGestures/  the app: menu bar, settings UI, CoreAudio, private-framework adapters, HUD
Tests/TEGCoreTests/            unit tests
scripts/                       build_app.sh, probe.sh, test.sh
docs/                          design documents written before the code (see "Differences" below)
```

## Known limitations

- Uses two **undocumented** Apple frameworks (MultitouchSupport for touch positions, DisplayServices for brightness). A macOS update can break either; the affected feature then shows as unsupported and the app keeps running.
- The MultitouchSupport struct layout, touch-state values and y direction are from community documentation and **unverified on your Mac**: the probe checks them.
- A little scroll movement before a gesture is recognised can still reach the app in front.
- Haptics: the request is made, but macOS may skip it and software cannot tell whether you felt it.
- Some outputs (certain HDMI/DisplayPort displays, some USB devices) have no software volume; the app shows this and disables volume.
- Brightness: automatic brightness may adjust the level again after you change it.
- Not suitable for the Mac App Store.

## Uninstall

1. Menu bar icon → Quit. 2. Turn off *Launch at Login* first (menu or Settings). 3. Delete `~/Applications/TrackpadEdgeGestures.app`.
4. `defaults delete local.trackpadedgegestures` 5. Remove it from Privacy & Security → Accessibility / Input Monitoring.

## Tests

`scripts/test.sh` runs ~45 unit tests: settings validation and persistence, the gesture state machine with synthetic
touch sequences (zones, thresholds, dominance, third finger, cooldown, smoothing, caps, rate limiting), the media gate
(unknown stays closed, debounce, override), the CoreAudio activity rules, and haptic boundary logic.
The manual hardware checklist is `docs/TEST_PLAN.md`.

---
| Note: Windows and linux versions are coming soon
