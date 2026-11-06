# UI preview suite

`just ui-previews` renders every `CaptureScreen` in
`ios/MumlaiOS/Sources/Capture.swift`; pass IDs to render a subset. An unknown
ID fails with the valid list. The app reaches screens through its real root,
waits for stable frames and signals the driver to take real Simulator
screenshots, with the status bar pinned to 9:41 and the Dynamic Island and
corners masked. Previews default to dark; App Store captures use light.

```bash
just ui-previews
just ui-previews transcripts account keyboard
just ui-previews --appearance light transcripts account
just ui-previews-stop
```

The command builds incrementally into `.local/screenshot-build`, installs into
the shared warm `iPhone 18 Pro` simulator recorded under
`~/Library/Caches/ui-previews/`, and writes `*.png`, `jpg/*.jpg`, `sheet.jpg`,
`console.log` and `manifest.json` into `.local/ui-previews`. Keyboard frames
are synthetic composites; use the [real-host keyboard recipes](keyboard-previews.md)
and a physical iPhone to accept extension-host spacing, safe areas and the
system Globe/Dictation bar. `onboarding-dictate` shows the field unfocused,
without a keyboard. Run `just ui-previews-stop` when the shared simulator is no
longer in use.

The separate driver screenshot captures the actual Dynamic Island and home
indicator, unlike the template's in-app rendering; this is needed for App
Store slides and makes previews match that capture path. The slide compositor
adds a home indicator because the Simulator capture may omit it.

## Interactive dictation in the Simulator

Debug Simulator builds can dictate without a microphone or the access service,
so a screen recording can check the dictation sheet, strip, timer and landing
transcript end to end:

```bash
SIMCTL_CHILD_MUMLA_FAKE_MIC_WAV=/path/to/speech-16k-mono.wav \
SIMCTL_CHILD_MUMLA_FAKE_TRANSCRIPT="Synthetic transcript text." \
  xcrun simctl launch <udid> emileberhard.WisprClone.ios
xcrun simctl io <udid> recordVideo --codec=h264 --force flow.mov
```

The WAV (16 kHz mono PCM16 with a 44-byte header) loops as microphone input and
drives the level meter; Stop returns the given transcript. Without
`MUMLA_FAKE_TRANSCRIPT` the app uses the real access service. Device builds
compile neither seam, and the transcript seam exists only in Debug.
