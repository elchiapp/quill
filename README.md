# DropSift

A private, local-first memory workspace for macOS. DropSift captures notes,
documents, images, existing audio, microphone audio, and system audio in one
timeline. It extracts searchable text locally, transcribes and diarizes speech
on-device, and lets you ask questions across the entire library through its
built-in local LLM. Knowledge items, recordings, transcripts, notes, and chat
threads sync through the user's iCloud Drive; inference never leaves the Mac.

**Drop anything in. Pull the exact source out.**

## Install

Build a signed, double-clickable app bundle and a distributable disk image:

```sh
scripts/package-macos.sh
open dist/DropSift.dmg
```

The generated artifacts are `dist/DropSift.app.zip` and `dist/DropSift.dmg`. By
default, the app is ad-hoc signed for local use. Set `SIGN_IDENTITY` to a
Developer ID or Apple Development signing identity when a persistent identity
is required.

Every distributable update uses the same semantic version and build number on
macOS, iPhone, and Apple Watch. Before packaging a new update, run:

```sh
scripts/bump-version.sh
```

This increments the patch version, creates a monotonically increasing dated
build number, and updates the desktop and generated Xcode project metadata.
The exact `version (build)` is visible in desktop Settings, iPhone Organize,
and at the bottom of the Watch capture screen.

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension) on an Apple-silicon Mac.

## iPhone and Apple Watch

The native iPhone and Apple Watch apps live in
`Mobile/DropsiftMobile.xcodeproj`. Open that project in Xcode, select your
Apple Development team if it is different from the configured team, choose
your paired iPhone, and press Run. The companion Watch app is embedded in the
iPhone app and can also be installed from the Watch app on iPhone.

On first launch, tap **Choose iCloud folder** and select the existing
`iCloud Drive/DropSift` folder. The iPhone then
reads and writes the exact same `Items/` and `Recordings/` folders as the Mac.
Any captures made before connecting are copied into the selected library.

The Watch app is deliberately one tap: record, stop, and the AAC voice message
is queued to the paired iPhone using background Watch Connectivity. The phone
adopts it into the shared recording schema, attempts on-device transcription,
and leaves it for the Mac's multilingual Parakeet queue if Apple Speech is
unavailable. Watch transfers survive either app being temporarily offline.

The iPhone app includes the same Capture, Timeline, and Ask flow. It imports
notes, documents, images with local OCR, existing audio, and phone voice
messages; filters and previews the shared timeline; and searches everything.
On iOS 26 with Apple Intelligence available, answers are generated locally
with Foundation Models. The model control at the top of Ask shows the engine
actually in use and lets you choose Automatic, Apple Intelligence, or
retrieval-only Local source search. Other devices get an extractive local
answer with the same source cards. Transcript cards jump to and highlight the
cited timestamp; PDF cards open the cited page.

See [`Mobile/README.md`](Mobile/README.md) for build, signing, device-test, and
TestFlight/archive instructions.

## How to use

1. Open `DropSift.app` on **Capture**. The uncluttered capture canvas provides
   five actions: **Add note**, **Add doc**, **Add image**, **Add recording**,
   and **Record**. Files can also be dropped directly onto the canvas.
2. Use **Timeline** to browse everything by date. Its multi-select filter can
   show any combination of notes, documents, images, and recordings. Each type
   has its own preview, and every imported item can carry additional notes.
3. Open **Ask DropSift** to start a conversation across the full knowledge
   base. DropSift starts with the compact Qwen3.5 2B model and offers a stronger
   model when the detected hardware can run one safely. On the first question,
   DropSift downloads the selected model; subsequent inference is offline.
   Numbered source cards beneath an answer open the cited transcript timestamp,
   PDF page, or knowledge item.

Notes use a Markdown write/preview editor with shortcuts for headings,
emphasis, lists, checkboxes, and links. PDF text is extracted by page, common
text and rich-document formats are converted locally, and images are OCRed
with Apple's Vision framework. Imported audio enters the same on-device
transcription and diarization queue as a new recording.

Recording details keep the transcript as the default workspace. Summary and
extracted tasks/entities live in dedicated **Summary** and **Insights** tabs,
while saved notes use a full-height inspector that starts collapsed when empty.
The header keeps Ask and Resume/Stop visible; regeneration, speaker naming,
audio files, Finder, and deletion are grouped under **Actions**. Timeline search
stays inside the Timeline column, and narrow windows collapse navigation to an
icon rail before compressing content.

Documents and images use the same hierarchy with **Preview**, **Extracted
text**, and **Insights** tabs plus the adaptive notes inspector. Notes use a
focused **Note** editor with a separate **Insights** tab and intentionally omit
the redundant additional-notes drawer.

DropSift generates concise titles locally from note headings, extracted
document/image text, recording notes, and transcripts. Generated titles can
improve as more content arrives; once you type a title yourself, DropSift keeps
it unchanged.

While recording, the main window shows a live notes editor above the current
detail view. Notes autosave into the recording's `notes.md` in iCloud Drive,
so they survive a crash and remain visible with the finished recording. Tiny
live waveforms show actual microphone and system-audio signal independently,
making a silent or disconnected source immediately visible. The menu-bar
DropSift mark turns red and pulses gently until recording stops.

If speaker playback leaks into the microphone, DropSift compares both
transcripts by timing and fuzzy text similarity, removes high-confidence
duplicates from the “You” track, and keeps the cleaner diarized system segment.
The same non-destructive filter is applied when older recordings are opened.

Transcript terminology can also be corrected without rewriting the source.
Select a word or phrase, open its context menu, and choose **Correct throughout
recording**. DropSift saves the recording-scoped mapping in `terminology.json`
and applies it to every whole-word occurrence in the transcript, title,
description, summary, semantic extraction, library search, and Ask DropSift.
Both the corrected term and its original alias remain searchable.

DropSift watches locally for known conferencing apps using a microphone. When
it detects a likely Zoom, Teams, Webex, FaceTime, Slack, Discord, Skype, Lark,
or browser meeting, it presents an actionable notification asking whether to
record. It never starts recording without confirmation, and the heuristic can
be disabled in Settings.

The knowledge library lives in `iCloud Drive/DropSift/` by default:

- `Items/<uuid>/` contains an imported asset or Markdown note, extracted text,
  metadata, and optional additional notes.
- `Recordings/<yyyy.MM.dd-HHmm>/` contains captured or imported audio,
  transcript data, and recording notes.
- `Threads/threads.json` contains local-AI conversations and their source
  cards.

Each captured recording contains:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `terminology.json` | recording-scoped corrections applied across display, search, and AI |
| `notes.md` | your autosaved notes, available while the recording is still running |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and the microphone is a trusted `me` channel. DropSift runs local speaker
diarization on the system track, labeling remote voices as `speaker_1`,
`speaker_2`, and so on. CAF on purpose: unlike m4a, it needs no finalization
pass — if the process dies mid-meeting, everything already written is still
readable.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v3**
via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port.
It automatically recognizes 25 European languages, including English,
Italian, French, German, Spanish, Portuguese, Dutch, Polish, Russian, and
Ukrainian. Models (~600 MB) download once on first transcription, with
download and Core ML compilation progress visible in the app. `dropsift doctor`
tells you whether they're already cached.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The recording detail view groups **Regenerate transcript**, **Regenerate title
& description**, and **Regenerate summary** in one menu. Re-transcription is
non-destructive: the existing transcript remains available until the complete
replacement is written, and a pending marker resumes the job after a restart.
While it runs, the toolbar shows a labeled **Processing transcript** indicator
with the detailed stage on hover. Completion and failure use native DropSift
notifications; a successful manual run reports **Transcript regenerated** with
the recording title.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Speaker diarization

Completed system-audio tracks run through FluidAudio's offline
Pyannote/WeSpeaker/VBx pipeline. It determines speaker count automatically and
aligns its voice turns with Parakeet's timed transcript segments. The
microphone track always remains `You`; only remote/system audio is clustered.

Diarization is enabled by default and downloads its Core ML models once on
first use. If model preparation or diarization fails, transcription still
finishes with the fallback `them` label and records the failure in
`transcribe.log`.

## Local AI backends

Inference is part of DropSift itself. Desktop Settings has a persistent,
hot-swappable **AI backend** control:

- **Apple native** runs current Qwen3.5/Qwen3.6 models with MLX Swift,
  multilingual Parakeet transcription with FluidAudio, offline VBx speaker
  diarization, and Apple Vision OCR.
- **QVAC** runs Qwen through QVAC's llama.cpp plugin, multilingual Parakeet
  TDT transcription through Metal, Sortformer speaker diarization, and QVAC OCR.
  DropSift starts and stops its packaged Bare/QVAC child runtime itself; no
  terminal command, localhost server, or separately installed QVAC app is
  required.

The backend selected when a transcription job starts stays attached to that
job, while new chat and ingestion work switches immediately. This makes it safe
to change providers while the background queue is finishing an earlier item.
Models for each backend use separate caches and download on first use.

The conservative language-model default is `Qwen3.5 2B` at 4-bit. DropSift
detects the chip, CPU count, and unified memory, then offers a stronger 4B, 9B,
27B, or 35B-A3B model when appropriate.

For every model, DropSift:

- caps the selected runtime at 50% of total unified memory;
- calculates the largest context window that fits that limit, up to the
  model's native 262K tokens;
- shows download progress, in-memory loading, failures, and the active model;
- downloads Apple-native weights into `~/Library/Caches/Dropsift/Models` and
  QVAC weights into `~/Library/Caches/Dropsift/QVAC/Models` only after the user
  selects the model or asks the first question.

There is no LM Studio, llama server, localhost API, Python runtime, terminal
command, or separate application for either backend.

Chat never uploads knowledge. DropSift chunks and ranks transcript passages,
recording notes, document pages, OCR text, note content, and imported-item
notes locally. It shows distinct retrieval, model-download/loading, and
generation states, and passes only relevant excerpts to its in-process model.
Structured source fragments are saved on each assistant message and link back
to their source location.

On launch, an older iCloud library is renamed in place to `DropSift`, preserving
recordings, threads, and notes without duplicating their data. Existing config
and model-cache locations remain compatible so settings and downloaded weights
are not stranded by the product rename.

## Config

Optional, at `~/.config/dropsift/config.json`:

```json
{
  "recordings_dir": "~/Library/Mobile Documents/com~apple~CloudDocs/DropSift/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "diarization": { "enabled": true, "engine": "offline-vbx" },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > iCloud Drive when available > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `diarization.enabled` — set `false` to keep the original two-channel
  `me`/`them` labeling without remote-speaker detection.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
dropsift                        # open the desktop app (^C to quit when run here)
dropsift run --out <dir>        # open with a custom recordings root
dropsift doctor                 # check permissions, recordings folder, models
dropsift install --launch-at-login
dropsift install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **MLX Swift LM / Qwen3.5 + Qwen3.6 4-bit** — hardware-aware, in-process local inference
- **PDFKit + Vision** — page-aware PDF extraction and local image OCR
- **SwiftUI + AppKit** — capture canvas, unified timeline, previews, and chat
- **NSStatusItem** — quick recording controls alongside the full window

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v3 supports 25 European languages automatically. Mandarin,
  Japanese, Arabic, and other languages outside that set still need a future
  transcription engine.
- iCloud Drive storage uses the visible `DropSift` folder, not a hidden app
  container, so knowledge items and recordings remain directly accessible in
  Finder.
- Meeting detection is deliberately a local heuristic. A browser using its
  microphone may be a call or something else; the notification asks first and
  can be turned off.

## License status

The original upstream Quill repository currently has no explicit software license. Public
GitHub visibility permits viewing and forking through GitHub, but does not
grant general commercial-use or redistribution rights. See
[`LICENSE_STATUS.md`](LICENSE_STATUS.md) and resolve the legal blocker in
[`TODO.md`](TODO.md) before commercial use.
