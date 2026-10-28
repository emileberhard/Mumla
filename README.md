# Mumla

Mumla is dictation for Mac and iPhone. On a Mac, hold the Globe key, speak,
and the text appears in the app you were typing in. On an iPhone, start a
session in the app once, then dictate into any text field from the Mumla
keyboard. Mumla transcribes with Microsoft's MAI-Transcribe-2 while you
speak, guided by your own dictionary of names and terms.
Your transcripts, dictionary and original recordings follow you between
devices through your private iCloud database.

## Get it

The Mac app is a notarized download at <https://mumla.esmadil.se/>, which also
shows when the iPhone app is available. There is no Mac App Store version: its
sandbox rules out the global key and automatic paste that Mumla relies on.

Every iCloud account gets 60 free minutes of transcription a month, shared by
its Macs and iPhones, with nothing to sign up for. The apps prove which iCloud
account they belong to through CloudKit; Mumla's access service, which the
maintainer operates, meters the minutes and forwards each recording to the
speech model. The apps contain no provider credentials.

## How it works

- **Mac.** A menu bar app. Hold the Globe or Fn key to talk, or press it once
  to start and again to stop. Mumla puts the transcript on the clipboard and
  pastes it, and can press Return for you. A setup wizard walks through the
  Microphone, Input Monitoring and Accessibility permissions.
- **iPhone.** iOS does not let a keyboard use the microphone, so the app
  records and the keyboard only starts, stops and inserts. The app keeps a
  session ready in the background; the keyboard signals it through the shared
  App Group and inserts the text when it arrives. The keyboard carries
  dictation controls and special characters; switch to your usual keyboard
  for letters.
- **Library.** Every dictation keeps its original audio, so a failed or poor
  transcription can be transcribed again. History, the dictionary
  and recordings sync through CloudKit, and settings through iCloud key-value
  storage.

[PRIVACY.md](PRIVACY.md) describes exactly what goes where.

## Build it yourself

You need a Mac with the Xcode version in `.xcode-version` and
[just](https://just.systems).

```bash
just                # list every recipe
just build-mac      # compile the Mac app without signing
just build-sim      # compile the iPhone app and keyboard for the simulator
just test-keyboard  # keyboard delivery tests
```

`just packages`, which these run first, anonymously checks out public GrantKit
at the revision in `scripts/GrantKit.revision` into `.local/GrantKit`. Other packages
resolve only to the versions in the committed `Package.resolved`. CI compiles
both apps unsigned and runs the keyboard and shared tests.

To run Mumla on your own devices, replace the maintainer's values with yours.
Put `DEVELOPMENT_TEAM = <your team ID>` in `Apple/Config/Local.xcconfig`, which
git ignores and the shared build settings include last. Change the rest in the
files themselves: the bundle identifiers, App Group and iCloud container in
`Mumla.xcodeproj/project.xcproj` and the entitlement files; the Debug
configurations' manual signing with the provisioning profiles `Mumla Mac
Development`, `Mumla iOS Development` and `Mumla Keyboard Development`, also in
the project, which a local configuration file cannot override; the access
service origin, `MumlaAccessOrigin`, in `Apple/Config/MumlaMac-Info.plist` and
`Apple/Config/MumlaiOS-Info.plist`; and the Sentry DSN in
`Mumla/Services/AppDiagnostics.swift` and `ios/Shared/CrashReporting.swift`, or
your build's crash reports go to the maintainer's project. Transcription needs
your own access service from `services/access/`, whose README covers its
configuration, and a CloudKit API token for your container as
`MUMLA_CLOUDKIT_API_TOKEN` in `Local.xcconfig`.

[AGENTS.md](AGENTS.md) covers the code's ownership, invariants and commands,
and `docs/` holds the design records.

## License and security

Mumla is source-available under [PolyForm Shield 1.0.0](LICENSE): you may read,
run, change, self-host and share it for any purpose except providing a product
that competes with it. The license covers the code, not the Mumla name or
icon, which stay reserved: a fork you distribute needs its own.
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists the components Mumla
includes and their licenses.

Report vulnerabilities privately through
[GitHub security advisories](https://github.com/emileberhard/Mumla/security/advisories/new),
not in a public issue.
