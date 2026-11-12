# Privacy

Last updated: 2026-11-11

Mumla turns your speech into text on Mac and iPhone. It has no sign-up or
advertising, does not track you across other apps or websites, and sells no
data. This policy describes
the official builds: the App Store, TestFlight and Developer ID download. Their
controller is Emil Eberhard, Sweden; send privacy questions and requests to
[eberhard.emil@gmail.com](mailto:eberhard.emil@gmail.com). A build you make
yourself uses the access service, iCloud container and crash-reporting
project its builder configures, and that builder is responsible for them.

## Recording

Mumla uses the microphone only while you dictate: while you hold the
dictation key on Mac, or from one press to the next, and on iPhone between your
start and stop taps. On iPhone, a session you start
keeps the microphone open in the background so the keyboard can start
dictating at once, and iOS shows its microphone indicator for as long as the
session runs; Mumla keeps no audio from outside a dictation.

Before transcribing, Mumla saves the original audio of every dictation on your
device, including dictations that fail, are very short or are canceled, so a
failed transcription can be retried.

## Transcription

Mumla sends each dictation to Microsoft's MAI-Transcribe-2 speech model on
Azure. Microsoft receives the audio while you speak, together with your
dictation languages and dictionary terms, which help it recognize names and
words. If that fails, and when you use Transcribe Again, Mumla sends the saved
recording again. Mumla never captures your screen.

The official builds send each recording to Mumla's access service, which the
maintainer operates, over an encrypted connection through Cloudflare's network. The service
checks your free minutes and forwards the recording through a router that
holds Microsoft's credential. For each request the router records metadata
under the service's own key: path, response status, byte counts, timing and
model. For each dictation the service logs a random identifier, the result,
the length of the audio and how long each step took, without your account or
network address. Neither stores audio, transcripts or dictionary terms. Microsoft handles
what it receives under its own terms and retention policies, which this policy
cannot change.

## Your voice

With **Voices** set to **Only Mine**, the default, Mumla learns your voice so it
can leave other people's words out of your dictations. On each device signed in
to iCloud, a speaker model built into the app turns your speech from dictations
in which it hears only one voice, including earlier recordings still on that
device, into a voice profile: numbers that describe how
your voice sounds, not what you said. The profile stays on that device. It is
not synced to iCloud, not included in device backups and never sent anywhere,
so each of your devices learns your voice on its own.

While you dictate, Mumla compares the voices it hears with each other and,
once learned, with your voice profile on the device. Once Mumla has learned
your voice, the access service keeps each dictation's audio in memory until a
few seconds after its transcript. When Mumla detects possible other voices,
it asks the service to have Microsoft also tell the speakers apart, with the
timing of each word; when you transcribe a
saved recording again, it asks for the speakers in the same request. Mumla then
compares each speaker with your profile on the device and leaves out the words
of voices that are not yours. The full transcript, with everyone's words, stays
in History on that device, where **Show Everyone** shows it; it is not synced to
iCloud.

## Your free minutes

Every iCloud account gets free transcription minutes each month, shared by its
devices. To count them, the app asks iCloud for a one-time proof of your
account, and the access service exchanges it with Apple for your account's
CloudKit user identifier for Mumla, ignoring names and contact details. The
service stores a hash of that identifier mapped to a random account number,
hashes of the sessions it issued to your devices, and the seconds of audio you
used each month, for the current and previous two months. To understand how
Mumla is used, it also keeps, for each day your account uses Mumla on iPhone or
Mac, how many times its devices signed in and dictated, the seconds of audio
and whether you used up your free minutes, for 13 months, and the day your
account first signed in and first dictated. It counts sign-ins
per network address in memory only, to limit abuse, and keeps no request log
with your address. Each device keeps its own session in its Keychain, where it
does not sync.

## Mumla Pro

Mumla Pro is an App Store subscription you buy on iPhone or iPad. Apple handles
the payment; Mumla never sees your payment details or Apple Account. The
purchase carries your random account number so the access service can credit
Pro to your iCloud account on all its devices. The app sends the service
Apple's signed record of each purchase, and Apple's servers tell it about
renewals, cancellations and refunds. For each subscription the service stores
its transaction identifiers, its purchase, expiry and refund dates, and the
account it belongs to, for as long as the service runs. TestFlight purchases,
which cost nothing, are stored the same way.

## Delivering text

On Mac, Mumla puts the transcript on the clipboard, replacing what was there,
and pastes it into the frontmost app by simulating Command-V; with Auto-send
on, it then presses Return. The transcript stays on the clipboard afterwards,
where other apps can read it and, with Handoff on, your other Apple devices can
paste it through Universal Clipboard. Mumla watches modifier keys for the
dictation key and, while recording, key presses for Escape and Space; it does
not record or send what you type.

On iPhone, the app copies each transcript to the clipboard without an
expiration, where other apps can read it and Universal Clipboard can share it,
and hands it to the Mumla keyboard through a container the app and keyboard
share on the device. That container keeps the latest transcript and the five
most recent ones for the keyboard. The keyboard needs Full Access to reach that
container. It does not read the text around the cursor or what you type with
other keyboards. It remembers which app it is typing in, so that Mumla can
return you there after starting a session. The shared container also keeps the
latest start, stop and cancel command, each with a random ID and timestamp,
and the ID the app last acted on, to authenticate the keyboard’s dictation
requests; these records stay on the device.

## History, dictionary and recordings

Mumla keeps your transcripts, with their time, provider and the name of the
device they were made on, your dictionary and your recordings on your device.
When you are signed in to iCloud, it syncs them to the private database of your
iCloud account, so your Mac and iPhone share them; nobody else, including the
maintainer, can read that database. Transcripts, dictionary terms and recording
details are stored in CloudKit's encrypted fields, which your device encrypts
with keys from your iCloud Keychain before uploading; recordings are stored as
CloudKit assets, which iCloud encrypts. With Advanced Data Protection on, only
your devices hold these keys. Settings such as your languages sync through
iCloud key-value storage.

Mumla never deletes recordings on its own. Deleting or clearing transcripts in
History removes them from your devices and iCloud and keeps their recordings;
transcripts another app saved to the shared library are only hidden, on the
device you deleted them on.
Once iCloud holds a recording, its local copy moves to a cache folder the system
may clear, and Mumla downloads it again when you play, export or transcribe it.
On Mac, **Keep all originals on this Mac** keeps full local copies instead.
Other apps from the same developer that use this
iCloud library, such as RemoteCoder and AgenTTY, can save their dictations to
it and use your shared dictation settings and dictionary; their own privacy
policies describe them. To delete everything, delete Mumla's transcripts in
History, remove its data from iCloud in your device's iCloud storage settings
and delete the app.

On Mac, the `mumla` command-line tool reads your history and exports
recordings through the running app, on the Mac or on an iPhone connected to it.
These requests stay on your devices.

## Diagnostics

The official builds send crash and error reports to Sentry, in its European
Union data region, so that problems can be fixed. Reports cover crashes, app
hangs, errors and warnings, such as a dictation that took long to arrive, with
how long each step took; on Mac, timing for a sample of operations; and
on iPhone, a running log of the app's and keyboard's state changes, such as
sessions starting and transcripts being inserted. They include the app
version, the device model and system version, the app's state, the type of
microphone and audio route, the network connection type, the model, your
dictation languages, counts and durations, such as how many speakers a
dictation had and how many were left out, the address, status and size of the
app's recent requests to the access service, a random identifier of a
dictation that the access service's log also has, the random identifiers of up
to three recordings that could not be uploaded to your iCloud dictation library,
and on iPhone the identifier of the app the keyboard is typing in. An error is
reported as a fixed description of what failed plus the error's type, domain
and numeric code, such as an HTTP status; the text of error messages, including
any a provider returned, is left out.
From iOS 27 and macOS 27, the apps also forward the system's own reports of
crashes, hangs, slow launches and terminations for exceeding memory or time
limits, the keyboard's included: the system's termination reason, call stacks
of code addresses, and the type of an uncaught exception, without its message.
Diagnostics are built to leave out transcripts, dictionary terms and audio. Sentry, like any server, sees the network address a report comes
from.

The Mac app also keeps the same events in a log in your Library's Logs folder
for 48 hours, which **Copy Diagnostics** copies to the clipboard, and both
apps write them to the system log on the device.

## Your choices

You can revoke the microphone, Input Monitoring,
Accessibility or keyboard Full Access permissions, sign out of iCloud to keep
everything on one device, and build Mumla yourself with your own services.
Set **Voices** to **Everyone** to keep every voice and stop learning yours.
**Forget My Voice** deletes your voice profile on all your devices, which learn
it again from your next dictations. Deleting the iPhone app also deletes it; on
a Mac, use Forget My Voice before deleting the app.
Turning something off stops its future use; it does not delete what providers,
iCloud or Sentry already received. To have the access service forget your
account, its usage and its purchases, email the address above.
