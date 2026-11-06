# Localization

Mumla ships in English, the source language, and Swedish. Both are complete in
every app surface and in the App Store listing.

## Catalogs

| Catalog | Covers |
| --- | --- |
| `Shared/Localization/Localizable.xcstrings` | Every string in the macOS app, the iOS app and the keyboard extension |
| `Mumla/InfoPlist.xcstrings` | The macOS microphone prompt and copyright |
| `ios/MumlaiOS/Resources/InfoPlist.xcstrings` | The iOS microphone prompt |
| GrantKit's `Sources/GrantKit/Localizable.xcstrings` | Permission names and GrantKit's own controls, looked up in GrantKit's bundle |

SwiftUI literals are `LocalizedStringKey`s. Types that carry user-facing text
outside a view use `LocalizedStringResource`; values resolved at once, such as
error descriptions and status messages, use `String(localized:)`. A `String`
passed to `Text` is shown verbatim, so never route user-facing text through
one. Diagnostics, logs, the `mumla` CLI and agent output stay English and out
of the catalog. Format counts, dates, sizes and durations with format styles,
and give count strings plural variants in both languages.

Errors from SpeechKit (`SpeechKitError`, `DictationLibraryError`) still reach
the UI in English; they need a localized SpeechKit release.

## Adding or changing a string

Xcode's IDE build adds new keys to the catalog. From the command line,
`SWIFT_EMIT_LOC_STRINGS` makes every compile emit `.stringsdata`; after clean
builds of `MumlaMac` and `MumlaiOS` (which builds the keyboard), sync them:

```bash
xcrun xcstringstool sync Shared/Localization/Localizable.xcstrings \
  --stringsdata <every MumlaMac, MumlaiOS and MumlaKeyboard .stringsdata>
```

An incremental build emits only the files it recompiled, and a sync from it
drops every other key. Build the screenshot configuration
(`MUMLA_SCREENSHOTS`) too when its strings matter. Add the Swedish value, and
the plural variants, in the same change.

Check Swedish screens with `just ui-previews --locale sv`.

## Terminology

| English | Swedish |
| --- | --- |
| transcript, transcription | transkription |
| dictate, dictation | diktera, diktering |
| Dictionary | Ordlista |
| recording, original audio | inspelning, originalljud |
| session | session |
| Full Access, Allow Full Access | full åtkomst, Tillåt full åtkomst |
| Settings, System Settings | Inställningar, Systeminställningar |
| Set Up | Konfigurera |
| subscription, Restore Purchases | prenumeration, Återställ köp |
| minutes reset | minuterna fylls på |

## App Store

`Apple/AppStore/listing/<locale>/` holds each locale's name, subtitle,
keywords and description; `primary_locale.txt` and the URL files apply to all.
`Apple/AppStore/capture app-store` captures and composes slides for every
listing locale into `.local/screenshots/<locale>/<display>`, with headlines in
`Apple/AppStore/compose.swift` and sample content in `CaptureContent`. A new
locale needs all three, plus its launch arguments in the capture script's
`LOCALES`.

The release tag message lists the English changes first, then one section per
other listing locale, opened by a line with the locale alone:

```text
Mumla is available in Swedish.

[sv]
Mumla finns nu på svenska.
```

Admission rejects a message without exactly one non-empty section for each
locale. The English lines become What to Test and the GitHub release notes,
and each section becomes its locale's What's New.
