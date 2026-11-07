# SPEC.md — Functional and Behavioral Specification
## 1. Product

Menu-bar utility (no Dock icon). Two-finger vertical gestures on the built-in trackpad's left/right edges control internal-display brightness and output volume, only while media is playing or manually overridden.

## 2. Zones

| Zone | Normalized x | Action |
|---|---|---|
| Left | 0 … leftWidth (default 0.15) | Brightness |
| Center | between | Untouched |
| Right | 1 − rightWidth (default 0.15) … 1 | Volume |

Limits: each width 0.08–0.30; leftWidth + rightWidth ≤ 0.60.

## 3. Settings and defaults

| Group | Setting | Default | Range / options |
|---|---|---|---|
| General | Gestures enabled | on | on/off |
| General | Launch at Login | on (registered once at first run) | on/off, reflects system status |
| General | Media-only activation | on | on/off |
| General | Manual override duration | 1 hour | 15 min / 1 h / until off |
| General | Auto-deactivate after media stops | on (1.0 s grace) | on/off |
| Gestures | Left zone width | 15% | 8–30% |
| Gestures | Right zone width | 15% | 8–30% |
| Gestures | Sensitivity | 1.2 | 0.5–3.0 |
| Gestures | Minimum movement | 0.025 pad height | 0.01–0.08 |
| Gestures | Smoothing | Medium (alpha 0.35) | Low 0.6 / Medium 0.35 / High 0.2 |
| Gestures | Activation method | Edge zones | Edge zones / Modifier |
| Gestures | Modifier (fallback) | Control+Option | selectable |
| Gestures | Scroll conflict behavior | Suppress during gesture (becomes Don't suppress if Accessibility missing or testing shows leaks) | Suppress / Don't suppress |
| Volume | Enabled | on | |
| Volume | Sensitivity multiplier | 1.0 | 0.5–2.0 |
| Brightness | Enabled | on | |
| Brightness | Sensitivity multiplier | 1.0 | 0.5–2.0 |
| Haptics | Enabled | on | |
| Haptics | Interval | 10 points | 5 / 10 / 20 |
| Haptics | Pulse at limits | on | |
| Media | Allow approximate detection (CoreAudio tier) | on | |
| Media | Music/Spotify signals | on | |
| Media | Now Playing adapter | off | only offered if adapter test passes |
| Feedback | Show HUD | on | |
| Diagnostics | Live contact display | off | resets to off on restart |

"Vertical direction": physical (up = increase) by default, with an "Invert" toggle.

## 4. Gesture behavior

See AGENTS.md section 6 for the state machine and numeric defaults. Behavior contract:

- Two-finger vertical movement with both fingers starting in the right zone adjusts volume; left zone adjusts brightness.
- Up increases, down decreases; proportional and smooth (no fixed 5% steps).
- Action locks at recognition; ends on finger lift, third finger, device invalidation, sleep, lock, or disable.
- Values clamp: volume 0–1; brightness 0.02–1.
- Output rate limits: volume ≤ 60 Hz, brightness ≤ 30 Hz; per-update cap 3% of range.
- Center-zone and all other gestures are never intercepted.

## 5. Media gating

Gate open conditions and source hierarchy are in AGENTS.md section 7. Contract:

- Playing (verified, or approximate if allowed) → open. Paused/stopped/none → closed after 1.0 s.
- Unknown/unavailable → closed.
- Manual override → open for the chosen duration, visibly labeled "Manually enabled", cancellable.
- Settings text must state: detection is approximate for apps without a direct signal; it cannot tell a paused audio session or a muted video from real playback; calls are excluded on a best-effort basis.

## 6. Volume

Default output device only. Capability detection per device; unsupported → feature disabled with status. Muted: up unmutes+raises, down no-op. No amplification.

## 7. Brightness

Built-in display only via the DisplayServices adapter. Unsupported → disabled with status. Minimum 0.02. Automatic brightness not controlled.

## 8. Haptics

`.levelChange` pulse when crossing interval boundaries; ≥ 80 ms apart; optional pulse at limits; none outside active gestures.

## 9. Menu bar

Items: status line (symbol + text), Enable gestures, media state, Manual override ▸, Volume %, Brightness %, Settings…, Launch at Login, Quit. States: Gestures active; Waiting for media; Manually enabled; Paused by user; Missing permission; Unsupported feature; Error requiring attention.

## 10. Settings window sections

General · Gestures · Volume · Brightness · Haptics · Media Detection · Diagnostics. Diagnostics lists: trackpad detection, gesture monitoring, playback detection (and which tier), volume API, brightness API, haptic support (call issued, not "felt"), permissions needed and granted, last 50 non-sensitive errors; plus an opt-in live view of normalized contacts and recognizer state (memory only).

## 11. HUD

Optional, non-activating panel, icon + level bar, auto-hide 1.2 s, no keyboard focus, user-disableable. No simulated media keys.

## 12. Permissions

Accessibility (event tap) with in-app explanation first; Input Monitoring only if the probe proves it necessary; Automation (Music/Spotify) only if enabled. No microphone, screen recording, camera, network.

## 13. Performance targets (until measured)

Idle CPU ≈ 0%; memory tens of MB; no idle timers; no polling; no GPU; no continuous disk writes.

## 14. Edge-case behavior (summary of the 30 required cases)

Default for any ambiguity: change nothing. Failures disable only the affected feature. Specific rules:

- Media transitions (1–6, 28): handled by the debounced gate; rapid toggles cannot flap the gate faster than the 1.0 s close grace.
- Silent/muted video (7): not distinguishable by CoreAudio tier; documented limitation; manual override available.
- Detection unavailable (8): gate closed.
- Output device change/disconnect (9, 10): rebuild volume capability on device-change listener; no crash.
- Non-controllable volume (11): disabled with status.
- Auto-brightness (12): not fought.
- Touch interruptions, extra finger, boundary crossing, horizontal drift (13–16): per AGENTS.md section 6.
- Sleep/wake, lock (17, 18): stop provider and tap, cancel gestures, restart on wake/unlock.
- Crash/restart (19): launch is idempotent; settings reload; login item status re-read.
- Permission revoked (20): detect via `AXIsProcessTrusted` on activation and on tap failure; show "Missing permission"; stop suppression.
- Private API missing (21): feature-level `unavailable`; app continues.
- Disabled from menu (22): provider keeps listening cheaply or stops; gestures never act.
- Zone width change mid-gesture (23) and option changes (24): apply from next gesture / next state evaluation.
- Fullscreen (25): HUD must not take focus; the status-bar-level panel may not appear over some fullscreen spaces: acceptable, verify and document.
- External mouse/trackpad (26): only the built-in device is used.
- Login before services ready (27): retry probes with backoff up to 30 s, status "Starting…".
- At limit (29): clamp, optional limit pulse once per gesture.
- Ordinary scrolling near an edge (30): never suppressed unless a gesture is recognized.
