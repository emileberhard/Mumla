---
name: mumla-local-install
description: Build and replace the locally installed `/Applications/Mumla Dev.app` with a fresh Debug build of this checkout, then relaunch it and verify the installed binary is running. Use when asked to update, replace, install, refresh or relaunch the local Mumla dev app on this Mac after code changes. Not for TestFlight, App Store or Developer ID distribution, or for compile-only builds.
---

# Mumla Local Install

The macOS target has two identities:

- Debug is the local dev app: bundle ID `emileberhard.WisprClone`, named
  "Mumla Dev", unsandboxed, Apple Development signing.
- Release is the TestFlight and App Store app: bundle ID
  `emileberhard.WisprClone.ios`, named "Mumla", sandboxed. Never install a
  Release build with this skill.

## Workflow

```bash
just install-mac
```

The recipe checks out GrantKit, installs the "Mumla Mac Development"
provisioning profile, builds a signed Debug `MumlaMac` into `/tmp/wcmac-dd`
stamped with the latest version tag, and runs
`scripts/install-local-mumla.sh`. That script quits the running dev app,
replaces `/Applications/Mumla Dev.app` with the new build, installs the
`mumla` CLI in `~/.local/bin`, relaunches the app and prints the running
binary and its timestamp.

Verify the installed app is the one running:

```bash
ps -axo pid=,command= | grep -F "/Applications/Mumla Dev.app/Contents/MacOS/"
```

## Gotchas

- The recipe uses the maintainer's signing tooling, team and provisioning
  profile, which the router key's Keychain access group depends on. With
  another team, set it in the ignored `Apple/Config/Local.xcconfig`, change
  the identifiers and Debug profiles as the README describes, and build in
  Xcode.
- `just build-mac` disables signing and only proves the code compiles.
- The dev app keeps bundle ID `emileberhard.WisprClone` so its Microphone,
  Input Monitoring and Accessibility grants, UserDefaults and Keychain router
  key carry over between installs.
- The sandboxed `/Applications/Mumla.app` from TestFlight coexists with the
  dev app; leave it alone.
- Replace the app through the helper script rather than retyping copy and move
  steps.
