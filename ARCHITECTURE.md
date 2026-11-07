# ARCHITECTURE.md
## 1. Component diagram

```
                        ┌──────────────────┐
                        │  AppCoordinator  │  lifecycle, wiring, power events
                        └───────┬──────────┘
        ┌───────────────┬───────┴────────┬──────────────────┬────────────────┐
        ▼               ▼                ▼                  ▼                ▼
┌───────────────┐ ┌──────────────┐ ┌────────────────┐ ┌─────────────────┐ ┌──────────────┐
│ TrackpadInput │ │ MediaPlayback│ │ SettingsManager│ │PermissionManager│ │ MenuBar/HUD  │
│ Provider (MT) │ │ Monitor      │ │ (UserDefaults) │ │ + LoginItem     │ │ Settings UI  │
└──────┬────────┘ └──────┬───────┘ └───────┬────────┘ └─────────────────┘ └──────▲───────┘
       │ TouchFrame      │ PlaybackState   │ AppSettings                         │ status
       ▼                 ▼                 ▼                                     │
┌────────────────────────────────────────────────┐                               │
│            GestureRecognitionEngine            │  (pure state machine)         │
│   idle → candidate → active(action) → cooldown │                               │
└──────┬──────────────────────────┬──────────────┘                               │
       │ GestureOutput(action,Δ)  │ gesture window                               │
       ▼                          ▼                                              │
┌──────────────┐  ┌───────────────────┐   ┌────────────────────┐                 │
│ Volume       │  │ Brightness        │   │ ScrollConflict     │                 │
│ Controller   │  │ Controller        │   │ Manager (CGEventTap)│                │
└──────┬───────┘  └────────┬──────────┘   └────────────────────┘                 │
       └─────────┬─────────┘                                                     │
                 ▼                                                               │
        HapticFeedbackController, HUDPanel ──────────────────────────────────────┘
                 DiagnosticsManager (collects status from all)
```

## 2. Data flow (one gesture)

1. `MultitouchSupportProvider` callback (framework thread) copies contact fields into a ring buffer; a serial `gestureQueue` drains it.
2. `GestureRecognitionEngine.process(frame)` consults the **gate** (`MediaGate` combining settings + `PlaybackState` + manual override) and settings snapshot; emits `GestureOutput(.volume|.brightness, deltaFraction)` only in `active`.
3. Output → rate limiter → controller `adjust(by:)` → CoreAudio / DisplayServices set. Controller returns new value.
4. Value crossing detector → `HapticFeedbackController`; value → `HUDPanel` (main thread, throttled) and menu status.
5. In parallel, `ScrollConflictManager` reads the engine's `isActive` flag (atomic) and drops continuous scroll events inside the gesture window.

Threading: provider callback thread → `gestureQueue` (serial, user-interactive QoS) → controllers (same queue; CoreAudio/DisplayServices calls are cheap) → UI via `MainActor`. Settings snapshot is an immutable struct swapped atomically.

## 3. Key protocols

```swift
protocol TrackpadInputProvider { var capability: Capability {get}; func start(); func stop(); var onFrame: ((TouchFrameBuffer)->Void)? {get set} }
protocol MediaPlaybackSource { var state: PlaybackState {get}; var onChange: ((PlaybackState)->Void)? {get set}; func start(); func stop() }
protocol VolumeController { var capability: Capability {get}; var current: Float? {get}; func adjust(by: Float) -> Float? }
protocol BrightnessController { same shape }
protocol HapticPerforming { func pulse() }
enum Capability { case available, degraded(String), unavailable(String) }
```

All hardware-facing types are injected, so the engine, gate, settings validation and haptic crossing logic are testable with mocks.

## 4. Private API isolation

- `MultitouchSupportProvider` and `DisplayServicesBrightnessController` are the only files touching private symbols, via `dlopen`/`dlsym` into typed function pointers (`@convention(c)`).
- If the library or any required symbol is missing: capability = `unavailable`, no crash, UI shows state.
- Optional `MediaRemoteAdapterSource` shells out to `/usr/bin/perl` with a pinned helper; strictly opt-in, removable, killed on app quit.

## 5. API decisions

| Need | Decision | Why |
|---|---|---|
| Contact positions | Private MultitouchSupport | Only way to get global contact coordinates |
| Scroll suppression | `CGEventTap` (active, session) | Public; needs Accessibility |
| Volume | CoreAudio properties | Public, native |
| Brightness | DisplayServices (private) | No supported API on Apple Silicon |
| Playback | Hybrid (see AGENTS §7) | No universal public API |
| Haptics | `NSHapticFeedbackManager` | Public |
| Login | `SMAppService.mainApp` | Modern, supported |
| UI | `NSStatusItem` + SwiftUI settings in `NSWindow` | Robust background utility |
| Persistence | `UserDefaults`, one versioned key | Simple, local |

## 6. Lifecycle and recovery

- `NSWorkspace` notifications: `willSleep`, `didWake`, `screensDidSleep/Wake`, session active/resign; distributed notifications for screen lock/unlock. On sleep/lock: cancel gesture, stop provider and tap. On wake/unlock: re-probe, re-enumerate devices, restart.
- CoreAudio listeners: default output device, device alive, process list/running-output.
- Observers registered and removed in matched start/stop pairs; all owned by `AppCoordinator`.
- Event tap health check on re-enable; permission check on app activation and on tap failure.

## 7. Resource strategy

Event-driven everywhere; the only timers are the gate close debounce (one-shot), HUD hide (one-shot), settings write debounce (one-shot), and a degraded-mode CoreAudio fallback poll (2 s, only while degraded and media-only is on). Provider keeps running while gestures are enabled but processing exits early when the gate is closed or fewer than two contacts are present.

## 8. Error handling

Errors are values (`Capability`, `Result`); each service fails independently; a bounded in-memory log feeds Diagnostics. No `fatalError` in runtime paths.
