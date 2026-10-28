# Third-party notices

Mumla's [license](LICENSE) applies to its own code. The components below keep
their own licenses, copyright notices and source rights. The Mumla name and
app icon are reserved; no trademark license is granted. Provider names
identify the speech services Mumla can use; they belong to their owners, which
do not sponsor or endorse Mumla.

| Distribution | Component | License and notices |
| --- | --- | --- |
| macOS and iOS apps, keyboard extension | [Sentry Cocoa SDK 9.17.1](https://github.com/getsentry/sentry-cocoa/tree/9.17.1) | MIT; [license](LICENSES/sentry-cocoa.txt) and [Sentry's third-party notices](LICENSES/sentry-cocoa-THIRD_PARTY_NOTICES.md) for KSCrash (MIT), Yandex LLC code (MIT), fishhook (BSD-3-Clause) and Apple Original Code (APSL 2.0) |
| macOS and iOS apps | [SpeechKit 0.2.0](https://github.com/emileberhard/SpeechKit/tree/de8b611d27df9d040f3d34e78af71da4d7e9d458), including its `DictationLibrary` product | MIT; [license](LICENSES/SpeechKit.txt) |
| macOS and iOS apps | [GrantKit 0.1.1](https://github.com/emileberhard/GrantKit/tree/411a0d3df2779171185abf9d359e199aa04b98e3) | MIT; [license](LICENSES/GrantKit.txt) |

## Apple Public Source License source availability

The Sentry Cocoa SDK's SentryCrash component contains Apple Original Code that
is subject to the Apple Public Source License 2.0, including structures and
constants derived from Apple's objc4 and CoreFoundation. Mumla's apps include
it, unmodified, in executable form. The source code of that covered code is
available under the terms of the APSL 2.0 at
<https://github.com/getsentry/sentry-cocoa/tree/9.17.1>, in particular
[`SentryCrashObjCApple.h`](https://github.com/getsentry/sentry-cocoa/blob/9.17.1/Sources/SentryCrash/Recording/Tools/SentryCrashObjCApple.h)
and
[`SentryCrashMach-O.c`](https://github.com/getsentry/sentry-cocoa/blob/9.17.1/Sources/SentryCrash/Recording/Tools/SentryCrashMach-O.c).
The full APSL 2.0 text is in
[Sentry's third-party notices](LICENSES/sentry-cocoa-THIRD_PARTY_NOTICES.md).

## System components

Opus audio encoding and every other audio, networking, iCloud and user
interface framework Mumla uses come from Apple's operating systems. Mumla
bundles no copy of them.

Keep this file and the `LICENSES` directory together in any distribution.
