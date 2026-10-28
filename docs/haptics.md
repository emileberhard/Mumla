# Haptic Design Guide

How iOS haptics are represented and how Mumla designs them. Grounded in
Core Haptics documentation, the WWDC sessions "Introducing Core Haptics"
(2019/520) and "Practice audio haptic design" (2021/10278), and Apple's
design-team pattern assets (HapticRicochet, HapticSampler, game-controller
samples, and the Apple.CoreHaptics Unity plug-in).

## The representation model

Core Haptics is an event-based synthesizer for the Taptic Engine. Four layers:

- **Engine** (`CHHapticEngine`): the connection to the actuator. One per
  process is enough. `playsHapticsOnly = true` for haptic-only use,
  `isAutoShutdownEnabled = true` to release hardware when idle. Set
  `stoppedHandler`/`resetHandler`; after a server reset every player is dead
  and must be recreated.
- **Pattern** (`CHHapticPattern`): a timeline of events plus optional
  automation. Built from Swift arrays, a dictionary, or an AHAP file.
- **Player**: `makePlayer` is fire-and-forget; `makeAdvancedPlayer` adds
  `loopEnabled`, `loopEnd`, `playbackRate`, pause/resume/seek, and `isMuted`.
  Looping restarts the pattern at `loopEnd` (defaults to pattern duration).
- **Event** (`CHHapticEvent`): the atom. Types:
  - `hapticTransient` — a momentary tap/impulse (the Flashlight-button feel).
  - `hapticContinuous` — sustained vibration with a duration (max 30 s).
  - `audioCustom`/`audioContinuous` — synchronized audio; unused in the
    keyboard (dictation must stay silent).

Events overlap and mix, but haptics do not blend like audio: two simultaneous
events of the same type are hard to tell apart. Layering different feels
(different sharpness, transient over continuous) does work and is an Apple
idiom.

### The two design axes

- **Intensity** (0–1): output energy. Perceptual floor for continuous events
  is around 0.1–0.2; below that the actuator produces nothing feelable.
- **Sharpness** (0–1): the perceptual character axis. 0 is round, soft,
  organic (low-frequency rumble); 1 is crisp, precise, mechanical. There is
  no physical unit; think material, not pitch.

Envelope shaping exists per event (`attackTime`, `decayTime`, `releaseTime`,
`sustained`) but most Apple patterns leave them at defaults.

### Changing a pattern while it plays

- **Event parameters** are fixed at authoring time.
- **Dynamic parameters** (`CHHapticDynamicParameter`) apply to the whole
  player at a point in time: `hapticIntensityControl` *multiplies* authored
  intensities, `hapticSharpnessControl` *adds* to authored sharpness. Send
  with `sendParameters(_:atTime:)` for live modulation (HapticRicochet drives
  texture intensity from ball speed this way).
- **Parameter curves** (`CHHapticParameterCurve`) are the scheduled version:
  control points interpolated linearly, authored inside the pattern or
  scheduled on a player. Curves and live-sent dynamic parameters fight over
  the same control value — use one mechanism per parameter ID.

### AHAP files

AHAP is a JSON dictionary form of the same model (`Pattern` array holding
`Event`, `Parameter`, `ParameterCurve` entries) that can be bundled and
QuickLook-previewed on macOS (select in Finder, press Space). Missing keys get
defaults, out-of-range values are clamped, unknown keys are ignored. Apple's
own AHAP assets contain trailing commas — Core Haptics parses them, strict
JSON tools do not. Mumla defines patterns in Swift instead of AHAP: the
keyboard already builds its start haptic in code, patterns stay type-checked,
and no resource pipeline is involved.

## Texture recipes from Apple's assets

Decoded from the shipped design-team patterns; these are the proven idioms
for sustained, feelable-but-subtle textures:

- **Granular texture** (HapticRicochet `Texture.ahap`, the WWDC21 rolling
  texture): ~100 pure transients over 2.0 s at irregular 10–30 ms gaps,
  intensities alternating 0.7/1.0, sharpness 0.0–0.2. Looped with an advanced
  player; runtime `hapticIntensityControl` scales it way down (authoring at
  full scale keeps modulation headroom). All-transient patterns loop
  seamlessly because there is no sustained body to seam.
- **Mechanical rumble** (`Rumble.ahap`): 39 transients at a metronomic 40 ms
  (25 Hz) with an intensity curve — regularity reads as machine, not noise.
- **Layered continuous body** (`Spin.ahap`, `Oscillate.ahap`): two
  overlapping `hapticContinuous` events with the same intensity but different
  sharpness (e.g. 0.0 and 0.075) beat against each other into a richer hum
  than any single event; parameter curves then sweep intensity or sharpness
  to make it evolve.
- **Signature accent** (`Heartbeats.ahap`): paired transients ~13 ms apart
  merge into one "thick" tick — the lub-dub idiom for a characterful pulse
  inside a longer loop.

## Design rules (HIG + WWDC, applied to Mumla)

- **Causality, harmony, utility.** The user must know what caused the
  haptic, it must match what they see and hear, and it must carry meaning.
  The dictation texture exists to answer "is it still listening?" without
  looking.
- The best haptic is one people are not conscious of but miss when it is
  turned off. That is the calibration target for anything continuous.
- Haptics physically shake the device. The HIG explicitly warns about the
  microphone: a dictation app playing continuous haptics while recording must
  keep intensity low and verify transcription quality is unaffected.
- Keyboard specifics (see AGENTS.md): transcript insertion never triggers
  feedback, `KeyboardFeedback` owns all haptics, and haptics require Full
  Access (without it the bridge never reports `.recording`, so state-driven
  haptics stay off by construction).

## The dictaphone dictation texture

Goal: while dictation is actively recording, the keyboard should feel like a
vintage handheld dictaphone with its cassette turning — subtle enough to run
for a whole dictation, present enough to be missed when absent. No prior art
exists (GitHub has no tape/motor/cassette AHAPs); the design composes the
Apple idioms above:

- **Motor hum**: two full-loop `hapticContinuous` layers, intensity 0.20 at
  sharpness 0.10 plus intensity 0.12 at sharpness 0.38 — a soft rumble with a
  faint electric edge, like a small DC motor through a plastic shell.
- **Gear ticks**: a ~7 Hz transient train with hand-authored ±15 ms jitter
  and alternating intensities around 0.22–0.32 at sharpness ≈ 0.35 — the
  tape transport, quasi-regular the way real mechanisms are.
- **Flutter accent**: once per loop a heavier double-tick (the worn spot on
  the reel), borrowing the Heartbeats idiom.
- **Wow**: a `hapticIntensityControl` curve breathing the whole mechanism
  between 0.85 and 1.0 twice per loop with unequal dip depths. The curve
  starts and ends at 1.0 so the loop seam stays smooth regardless of whether
  curve automation re-triggers per loop iteration.
- **Loop**: 2.4 s pattern on a `CHHapticAdvancedPatternPlayer` with
  `loopEnabled`; the last tick sits one grid gap before the seam so the
  cadence never stutters.

The pattern is built in `DictaphoneTexture.swift` (keyboard extension) with
two tuning knobs: `intensityScale` multiplies every authored intensity
(overall subtlety), and `playbackRate` time-stretches the whole mechanism on
the player (reel speed) without changing how each event feels. The visual
counterpart is `CassetteMotifView` (`ios/Shared/CassetteMotif.swift`): while
recording, two identical spoked wheels set into the pill's rounded ends drive
a dashed tape band running as an inner border — motor-style spin-up, frozen
under Reduce Motion. The loop is state-driven: it starts when the
keyboard-visible bridge phase becomes `.recording` and stops on any other
phase, keyboard disappearance, or deactivation. The existing automatic-start
haptic plays first (the "record button clunk"), then the reels spin.

Interruption behavior: if the haptic server resets or the engine stops while
dictation is still recording, `KeyboardFeedback` re-establishes the loop from
its should-be-playing state. Bind the loop to observed state, never to the
event that started it.

The observed state must itself be trustworthy: an app killed mid-dictation
leaves a stale `recording` phase in shared defaults, so
`KeyboardBridgeClient` reports `.idle` whenever the app heartbeat is stale.
Without that gate, the texture (and recording UI) would run on an idle
keyboard until the app next launches.

## The start/stop accents

One-shot patterns in `DictaphoneAccents.swift` bracket the texture with the
cassette popping in and out of the same vintage recorder. Pure transients,
all at 0.8–1.0 intensity, spaced ~55–70 ms apart — the tightest gap where
each click still reads as its own snap (a 13 ms pair merges into one thick
hit; that pair is used only for the heavy clack in each pattern). No
continuous bodies anywhere: sustained material smears the mechanism, and
the motor is the texture loop's job. Two earlier drafts were rejected for
feeling diffuse — a smooth motor surge/coast-down, then wide 80–110 ms
click spacing with sub-0.6 intensities and mass bodies under the clacks:

- **Start (cassette in, ~0.13 s)**: click-click-CLACK — two crisp latch
  clicks (0.85/0.9 at sharpness 0.8/0.7) climbing into the heavy
  seat-and-lock (1.0 at sharpness 0.45).
- **Stop (cassette out, ~0.13 s)**: snick-CLACK-click — the stop key's
  crisp snick (0.9 at sharpness 0.8), the heavy eject pop (1.0 at
  sharpness 0.4), then the shell popping up (0.85 at sharpness 0.6).

Start climbs into its clack, stop leads with it, so the grammars stay
distinguishable blind.

Both accents are state-driven from the same phase `onChange` that toggles
the texture, with three gates that keep them honest:

- The keyboard controller drops transitions while the view is off screen
  (`bridge.deactivate()` publishes a synthetic `.idle` on disappearance that
  must not click the mechanism; recording continuing in the app is not a
  stop).
- A flip to `.recording` whose shared `recordingStartTimestamp` is older
  than ~2 s is the keyboard re-observing an already-running mechanism, not
  an engage — no start accent on reopening mid-recording.
- The automatic-start handoff (`automaticDictationStarted`) plays the same
  start pattern through its own durable path; a debounce window lets
  whichever path runs first win, never both.

The stop accent fires on any `.recording` exit — finish, cancel, error, or
app death — because in every case the mechanism really stopped.
