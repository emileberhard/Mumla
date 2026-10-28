# Keyboard previews

Keyboard UI changes are normally checked on a physical iPhone. These recipes
let an agent check the keyboard's visuals itself on the simulator, inside the
real keyboard extension host.

```bash
just keyboard-preview-important-sim
just keyboard-preview-important-fast-sim
just keyboard-preview-sim
just keyboard-preview-fast-sim
```

They open `mumla://debug/keyboard-host-test`, a focused text view that uses
the installed keyboard extension, and capture simulator screenshots.
`keyboard-preview-important-sim` rebuilds and installs the app, then captures
the real extension-host view and the forced `recording` and `processing`
states in that host, in light and dark appearance; use it after UI code
changes. The `fast` variants reuse the installed build. The single-screenshot
recipes suit checks where one real-host state is enough.

If the system keyboard appears, press Globe to cycle to Mumla; do not add or
remove keyboards for routine checks. In the accessibility tree both the system
Globe and Mumla's Globe are labeled "Next keyboard", and the button's value
names the keyboard a tap switches to, so tap while the value reads "Mumla",
then stop and confirm with a screenshot, not the tree. If the focused text view
shows no keyboard, turn off Simulator's **I/O > Keyboard > Connect Hardware
Keyboard**; a hidden software keyboard otherwise produces blank captures that
still report success. The start-state label is the Full Access acceptance
check: it must say **Start Session**, not **Full Access**.

For forced-state layout iteration:

```bash
just keyboard-layout-preview-sim
just keyboard_state=recording keyboard-layout-preview-fast-sim
just keyboard_state=recording keyboard-layout-preview-sim
just keyboard-layout-preview-states-sim
just keyboard-layout-preview-states-fast-sim
```

The non-fast commands build and run `MumlaiOS` on the configured simulator
(`iPhone 17 Pro` with the latest available iOS 26 or later runtime by default);
the fast commands reuse the installed app. They open
`mumla://debug/keyboard-host-test?state=...`: the containing app writes the
requested debug state into the App Group bridge and posts the normal Darwin
state-change notification, so screenshots still come from the installed
keyboard extension inside the real iOS keyboard host.

`mumla://debug/keyboard-test?state=...` hosts the keyboard view directly and
suits only SwiftUI layout debugging where host chrome does not matter. Never
use it to accept spacing, safe areas, the gap below the host or the bottom
Globe/Dictation strip, and do not add synthetic padding or insets to make it
resemble the system host.

For a screen recording, reuse the installed preview build, record with
`xcrun simctl io <device> recordVideo` while switching
`mumla://debug/keyboard-host-test?state=...` URLs, and check the MP4 with a
contact sheet before sharing it.

When validation is done, run `xcrun simctl shutdown all` and quit Simulator.
