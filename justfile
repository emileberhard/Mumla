# Mumla — macOS menu bar app, iOS app and keyboard extension in Mumla.xcodeproj.

# The Xcode that .xcode-version names, as CI and the release use; callers may explicitly override it.
export DEVELOPER_DIR := shell('if [ -n "${DEVELOPER_DIR:-}" ]; then echo "$DEVELOPER_DIR"; else scripts/select-xcode; fi')

iOS_scheme := "MumlaiOS"
mac_scheme := "MumlaMac"
device := ""
delivery := "auto"
simulator := "iPhone 17 Pro"
simulator_id := ""
keyboard_state := "start"
keyboard_states := "start idle recording processing error"
keyboard_important_states := "start recording processing"
keyboard_preview_appearances := "light dark"

default:
    @just --list

# Check out GrantKit at the revision in scripts/GrantKit.revision.
packages:
    scripts/prepare-packages

# Build a signed checkpoint and deliver it to the iPhone.
install-iphone:
    scripts/iphone-iteration --delivery "{{ delivery }}" --device "{{ device }}"

build-iphone:
    scripts/iphone-iteration --build-only

deliver-iphone $app_path:
    scripts/iphone-iteration --app-path "$app_path" --delivery "{{ delivery }}" --device "{{ device }}"

# Build the iOS app for the simulator (compile check).
build-sim: packages
    xcodebuild -project Mumla.xcodeproj -scheme {{ iOS_scheme }} \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath /tmp/wcios-dd build

# Run isolated keyboard lifecycle and delivery regressions without providers or a simulator.
test-keyboard: packages
    xcodebuild -project Mumla.xcodeproj -scheme MumlaKeyboardTests \
        -destination 'platform=macOS' -quiet test CODE_SIGNING_ALLOWED=NO

# Live access acceptance from the signed Debug app: native CloudKit enrollment, proof replay, Transcribe Again and paced progressive uploads to the 110 s bound; spends about four minutes of the signed-in account's allowance.
test-access-live: packages
    #!/usr/bin/env bash
    set -euo pipefail
    just _build-mac-signed /tmp/mumla-access-probe-dd
    receipt="$(mktemp -d /tmp/mumla-access-probe.XXXXXX)/receipt.json"
    status=0
    MUMLA_ACCESS_PROBE=1 \
        MUMLA_ACCESS_PROBE_FIXTURE="$PWD/Evaluations/RealtimeTranscription/fixtures/en-short-technical.wav" \
        MUMLA_ACCESS_PROBE_RECEIPT="$receipt" \
        "/tmp/mumla-access-probe-dd/Build/Products/Debug/Mumla Dev.app/Contents/MacOS/Mumla Dev" || status=$?
    cat "$receipt"
    exit "$status"

# Build, launch, and capture a real-host forced-state keyboard screenshot.
keyboard-layout-preview-sim: packages
    #!/usr/bin/env bash
    set -euo pipefail
    simulator_args=()
    device="{{ simulator_id }}"
    if [[ -n "$device" ]]; then
        simulator_args+=(--simulator-id "$device")
    else
        simulator_args+=(--simulator-name "{{ simulator }}" --use-latest-os)
    fi

    xcodebuildmcp simulator build-and-run \
        --project-path Mumla.xcodeproj \
        --scheme "{{ iOS_scheme }}" \
        --configuration Debug \
        --derived-data-path /tmp/wc-keyboard-preview-dd \
        "${simulator_args[@]}"

    if [[ -z "$device" ]]; then
        device="$(xcrun simctl list devices available -j | jq -r --arg name "{{ simulator }}" '[.devices[][] | select(.name == $name and .isAvailable == true and .state == "Booted")][0].udid // empty')"
    fi
    if [[ -z "$device" ]]; then
        echo "Could not resolve a booted {{ simulator }} simulator UDID." >&2
        exit 1
    fi

    ./scripts/open-keyboard-preview-url-sim \
        "$device" \
        "mumla://debug/keyboard-host-test?state={{ keyboard_state }}"
    screenshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/mumla-keyboard-preview.XXXXXX")"
    screenshot="$screenshot_dir/{{ keyboard_state }}.png"
    xcrun simctl io "$device" screenshot "$screenshot" >/dev/null 2>&1
    echo "Screenshot: $screenshot"

# Reuses the currently installed simulator app; run keyboard-layout-preview-sim after code changes.

# Fast real-host forced-state keyboard screenshot.
keyboard-layout-preview-fast-sim:
    #!/usr/bin/env bash
    set -euo pipefail
    device="{{ simulator_id }}"
    if [[ -z "$device" ]]; then
        device="$(xcrun simctl list devices available -j | jq -r --arg name "{{ simulator }}" '[.devices[][] | select(.name == $name and .isAvailable == true and .state == "Booted")][0].udid // empty')"
    fi
    if [[ -z "$device" ]]; then
        echo "Could not resolve a booted {{ simulator }} simulator UDID. Run keyboard-layout-preview-sim first." >&2
        exit 1
    fi

    ./scripts/open-keyboard-preview-url-sim \
        "$device" \
        "mumla://debug/keyboard-host-test?state={{ keyboard_state }}"
    screenshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/mumla-keyboard-preview.XXXXXX")"
    screenshot="$screenshot_dir/{{ keyboard_state }}.png"
    xcrun simctl io "$device" screenshot "$screenshot" >/dev/null 2>&1
    echo "Screenshot: $screenshot"

# Build once, then screenshot every real-host keyboard preview state.
keyboard-layout-preview-states-sim: packages
    #!/usr/bin/env bash
    set -euo pipefail
    simulator_args=()
    device="{{ simulator_id }}"
    if [[ -n "$device" ]]; then
        simulator_args+=(--simulator-id "$device")
    else
        simulator_args+=(--simulator-name "{{ simulator }}" --use-latest-os)
    fi

    xcodebuildmcp simulator build-and-run \
        --project-path Mumla.xcodeproj \
        --scheme "{{ iOS_scheme }}" \
        --configuration Debug \
        --derived-data-path /tmp/wc-keyboard-preview-dd \
        "${simulator_args[@]}"

    if [[ -z "$device" ]]; then
        device="$(xcrun simctl list devices available -j | jq -r --arg name "{{ simulator }}" '[.devices[][] | select(.name == $name and .isAvailable == true and .state == "Booted")][0].udid // empty')"
    fi
    if [[ -z "$device" ]]; then
        echo "Could not resolve a booted {{ simulator }} simulator UDID." >&2
        exit 1
    fi

    for state in {{ keyboard_states }}; do
        ./scripts/open-keyboard-preview-url-sim \
            "$device" \
            "mumla://debug/keyboard-host-test?state=$state"
        screenshot_dir="${screenshot_dir:-$(mktemp -d "${TMPDIR:-/tmp}/mumla-keyboard-preview.XXXXXX")}"
        screenshot="$screenshot_dir/$state.png"
        xcrun simctl io "$device" screenshot "$screenshot" >/dev/null 2>&1
        echo "Keyboard preview state: $state"
        echo "Screenshot: $screenshot"
    done

# Reuses the currently installed simulator app; run keyboard-layout-preview-states-sim after code changes.

# Fast real-host forced-state keyboard screenshots.
keyboard-layout-preview-states-fast-sim:
    #!/usr/bin/env bash
    set -euo pipefail
    device="{{ simulator_id }}"
    if [[ -z "$device" ]]; then
        device="$(xcrun simctl list devices available -j | jq -r --arg name "{{ simulator }}" '[.devices[][] | select(.name == $name and .isAvailable == true and .state == "Booted")][0].udid // empty')"
    fi
    if [[ -z "$device" ]]; then
        echo "Could not resolve a booted {{ simulator }} simulator UDID. Run keyboard-layout-preview-states-sim first." >&2
        exit 1
    fi

    for state in {{ keyboard_states }}; do
        ./scripts/open-keyboard-preview-url-sim \
            "$device" \
            "mumla://debug/keyboard-host-test?state=$state"
        screenshot_dir="${screenshot_dir:-$(mktemp -d "${TMPDIR:-/tmp}/mumla-keyboard-preview.XXXXXX")}"
        screenshot="$screenshot_dir/$state.png"
        xcrun simctl io "$device" screenshot "$screenshot" >/dev/null 2>&1
        echo "Keyboard preview state: $state"
        echo "Screenshot: $screenshot"
    done

# Build, launch, and capture the start state in the real extension host.
keyboard-preview-sim: packages
    #!/usr/bin/env bash
    set -euo pipefail
    simulator_args=()
    device="{{ simulator_id }}"
    if [[ -n "$device" ]]; then
        simulator_args+=(--simulator-id "$device")
    else
        simulator_args+=(--simulator-name "{{ simulator }}" --use-latest-os)
    fi

    xcodebuildmcp simulator build-and-run \
        --project-path Mumla.xcodeproj \
        --scheme "{{ iOS_scheme }}" \
        --configuration Debug \
        --derived-data-path /tmp/wc-keyboard-preview-dd \
        "${simulator_args[@]}"

    if [[ -z "$device" ]]; then
        device="$(xcrun simctl list devices available -j | jq -r --arg name "{{ simulator }}" '[.devices[][] | select(.name == $name and .isAvailable == true and .state == "Booted")][0].udid // empty')"
    fi
    if [[ -z "$device" ]]; then
        echo "Could not resolve a booted {{ simulator }} simulator UDID." >&2
        exit 1
    fi

    ./scripts/open-keyboard-preview-url-sim \
        "$device" \
        "mumla://debug/keyboard-host-test?state=start"
    screenshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/mumla-keyboard-preview.XXXXXX")"
    screenshot="$screenshot_dir/start.png"
    xcrun simctl io "$device" screenshot "$screenshot" >/dev/null 2>&1
    echo "Screenshot: $screenshot"

# Reuses the currently installed simulator app; run keyboard-preview-sim after code changes.

# Fast start-state screenshot in the real extension host.
keyboard-preview-fast-sim:
    #!/usr/bin/env bash
    set -euo pipefail
    device="{{ simulator_id }}"
    if [[ -z "$device" ]]; then
        device="$(xcrun simctl list devices available -j | jq -r --arg name "{{ simulator }}" '[.devices[][] | select(.name == $name and .isAvailable == true and .state == "Booted")][0].udid // empty')"
    fi
    if [[ -z "$device" ]]; then
        echo "Could not resolve a booted {{ simulator }} simulator UDID. Run keyboard-preview-sim first." >&2
        exit 1
    fi

    ./scripts/open-keyboard-preview-url-sim \
        "$device" \
        "mumla://debug/keyboard-host-test?state=start"
    screenshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/mumla-keyboard-preview.XXXXXX")"
    screenshot="$screenshot_dir/start.png"
    xcrun simctl io "$device" screenshot "$screenshot" >/dev/null 2>&1
    echo "Screenshot: $screenshot"

# Build once, then capture the most important real-host states in light and dark mode.
keyboard-preview-important-sim: packages
    #!/usr/bin/env bash
    set -euo pipefail
    simulator_args=()
    device="{{ simulator_id }}"
    if [[ -n "$device" ]]; then
        simulator_args+=(--simulator-id "$device")
    else
        simulator_args+=(--simulator-name "{{ simulator }}" --use-latest-os)
    fi

    xcodebuildmcp simulator build-and-run \
        --project-path Mumla.xcodeproj \
        --scheme "{{ iOS_scheme }}" \
        --configuration Debug \
        --derived-data-path /tmp/wc-keyboard-preview-dd \
        "${simulator_args[@]}"

    if [[ -z "$device" ]]; then
        device="$(xcrun simctl list devices available -j | jq -r --arg name "{{ simulator }}" '[.devices[][] | select(.name == $name and .isAvailable == true and .state == "Booted")][0].udid // empty')"
    fi
    if [[ -z "$device" ]]; then
        echo "Could not resolve a booted {{ simulator }} simulator UDID." >&2
        exit 1
    fi
    screenshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/mumla-keyboard-preview.XXXXXX")"
    echo "Keyboard screenshots: $screenshot_dir"
    trap 'xcrun simctl ui "$device" appearance light >/dev/null 2>&1 || true' EXIT

    for appearance in {{ keyboard_preview_appearances }}; do
        xcrun simctl ui "$device" appearance "$appearance"
        for state in {{ keyboard_important_states }}; do
            ./scripts/open-keyboard-preview-url-sim \
                "$device" \
                "mumla://debug/keyboard-host-test?state=$state"
            screenshot="$screenshot_dir/$appearance-$state.png"
            xcrun simctl io "$device" screenshot "$screenshot" >/dev/null 2>&1
            echo "Keyboard real-host preview: $appearance $state"
            echo "Screenshot: $screenshot"
        done
    done

# Reuses the installed app for the most important real-host states in light and dark mode.
keyboard-preview-important-fast-sim:
    #!/usr/bin/env bash
    set -euo pipefail
    device="{{ simulator_id }}"
    if [[ -z "$device" ]]; then
        device="$(xcrun simctl list devices available -j | jq -r --arg name "{{ simulator }}" '[.devices[][] | select(.name == $name and .isAvailable == true and .state == "Booted")][0].udid // empty')"
    fi
    if [[ -z "$device" ]]; then
        echo "Could not resolve a booted {{ simulator }} simulator UDID. Run keyboard-preview-sim first." >&2
        exit 1
    fi
    screenshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/mumla-keyboard-preview.XXXXXX")"
    echo "Keyboard screenshots: $screenshot_dir"
    trap 'xcrun simctl ui "$device" appearance light >/dev/null 2>&1 || true' EXIT

    for appearance in {{ keyboard_preview_appearances }}; do
        xcrun simctl ui "$device" appearance "$appearance"
        for state in {{ keyboard_important_states }}; do
            ./scripts/open-keyboard-preview-url-sim \
                "$device" \
                "mumla://debug/keyboard-host-test?state=$state"
            screenshot="$screenshot_dir/$appearance-$state.png"
            xcrun simctl io "$device" screenshot "$screenshot" >/dev/null 2>&1
            echo "Keyboard real-host preview: $appearance $state"
            echo "Screenshot: $screenshot"
        done
    done

# Build the macOS menu bar app.
build-mac: packages
    xcodebuild -project Mumla.xcodeproj -scheme {{ mac_scheme }} \
        -configuration Debug \
        -derivedDataPath /tmp/wcmac-dd \
        CODE_SIGNING_ALLOWED=NO \
        build

# Generate any missing realtime transcription evaluation fixtures in parallel.
realtime-eval-fixtures *args:
    Evaluations/RealtimeTranscription/scripts/generate_fixtures.py {{ args }}

# Run or resume the realtime transcription provider matrix.
realtime-eval *args:
    Evaluations/RealtimeTranscription/scripts/run_evaluation.py {{ args }}

# Run the offline tests for evaluation manifests, analysis, resume, and concurrency.
test-realtime-eval:
    uv run --with pytest pytest Evaluations/RealtimeTranscription/tests

# Build a signed Debug macOS app and install it as "/Applications/Mumla Dev.app".
install-mac launch="1": packages
    just _build-mac-signed /tmp/wcmac-dd
    MUMLA_INSTALL_LAUNCH="{{ launch }}" ./scripts/install-local-mumla.sh

_build-mac-signed derived_data:
    #!/usr/bin/env bash
    set -euo pipefail
    apple_devops_scripts="$HOME/configs/skills/apple-devops/scripts"
    version="${MARKETING_VERSION:-$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*')}"
    set +u
    set -a
    source "$HOME/configs/shared-env.sh"
    set +a
    set -u
    "$apple_devops_scripts/ensure-signing-keychain"
    uv run "$apple_devops_scripts/asc_api.py" install-profile \
        --name "Mumla Mac Development" \
        --type MAC_APP_DEVELOPMENT \
        --bundle-id emileberhard.WisprClone
    xcodebuild -project Mumla.xcodeproj -scheme {{ mac_scheme }} \
        -configuration Debug \
        -derivedDataPath "{{ derived_data }}" \
        MARKETING_VERSION="$version" \
        build

# Safely bootstrap Development CloudKit schema without a normal app launch.
bootstrap-cloudkit-schema:
    #!/usr/bin/env bash
    set -euo pipefail
    environment="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' Mumla/MumlaDev.entitlements)"
    if [[ "$environment" != "Development" ]]; then
        echo "MumlaDev.entitlements must be temporarily pinned to Development." >&2
        exit 1
    fi
    just install-mac 0
    MUMLA_INIT_CLOUDKIT_SCHEMA=1 \
        '/Applications/Mumla Dev.app/Contents/MacOS/Mumla Dev'

# Build, notarize, and package the Developer ID macOS app as dist/Mumla-<version>.dmg.
build-dmg: packages
    ./scripts/build-developer-id-dmg.sh

# Publish page-only changes without uploading or deleting the current DMG and manifest.
publish-page:
    ark push \
        --preserve Mumla.dmg \
        --preserve latest.json \
        distribution/mumla-mbag

# Quit every running macOS Mumla instance (prod and dev).
kill-mac:
    -pkill -f "/Applications/Mumla.app/Contents/MacOS/"
    -pkill -f "/Applications/Mumla Dev.app/Contents/MacOS/"

# Reset all TCC permissions for the macOS app. Run while an app is still installed.
reset-permissions-mac:
    tccutil reset All emileberhard.WisprClone

# Simulate a brand-new user: kill, reset permissions, wipe defaults and the router key, delete installs.
fresh-user-mac:
    ./scripts/mac-fresh-user.sh

# Delete built DMGs (dist/ and any Mumla-*.dmg on the Desktop).
clean-dmgs:
    rm -rf dist
    rm -f ~/Desktop/Mumla-*.dmg
