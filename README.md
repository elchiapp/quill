# Dropsift

A private, local-first macOS meeting workspace. Dropsift records microphone and
system audio as separate tracks, transcribes both on-device, presents a
speaker-tagged transcript library, and lets you chat with one or all meetings
through a local LLM. Audio, transcripts, and chat threads sync through the
user's iCloud Drive; inference never leaves the Mac.

**Drop anything in. Pull the exact source out.**

## Install

Build a signed, double-clickable app bundle and a distributable disk image:

```sh
scripts/package-macos.sh
open dist/Dropsift.dmg
```

The generated artifacts are `dist/Dropsift.app.zip` and `dist/Dropsift.dmg`. By
default, the app is ad-hoc signed for local use. Set `SIGN_IDENTITY` to a
Developer ID or Apple Development signing identity when a persistent identity
is required.

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension) on an Apple-silicon Mac.

## How to use

1. Open `Dropsift.app` and click **New recording**. First use prompts for
   microphone and System Audio Recording permissions.
2. Stop from the window or Dropsift menu-bar item. Dropsift transcribes the two
   tracks locally and adds the speaker-tagged result to the library.
3. Open **Ask Dropsift**, start a conversation, and choose either **All
   recordings** or one meeting as its scope. Dropsift starts with the compact
   Qwen3.5 2B model and offers a stronger model when the detected hardware can
   run one safely. On the first question, Dropsift downloads the selected model;
   subsequent inference is offline.
   Numbered source cards beneath an answer open the cited recording at the
   matching transcript timestamp.

While recording, the main window shows a live notes editor above the current
detail view. Notes autosave into the recording's `notes.md` in iCloud Drive,
so they survive a crash and remain visible with the finished recording. The
menu-bar Dropsift mark turns red and pulses gently until recording stops.

Each session lands in
`iCloud Drive/Dropsift/Recordings/<yyyy.MM.dd-HHmm>/` by default:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `notes.md` | your autosaved notes, available while the recording is still running |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and the microphone is a trusted `me` channel. Dropsift runs local speaker
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

## Local AI

Inference is part of Dropsift itself. It uses Apple's
[MLX Swift](https://github.com/ml-explore/mlx-swift) runtime and current
Qwen3.5/Qwen3.6 models directly in the app process. The conservative default is
`Qwen3.5 2B` at 4-bit. Dropsift detects the chip, CPU count, and unified memory,
then offers a stronger 4B, 9B, 27B, or 35B-A3B model when appropriate.

For every model, Dropsift:

- caps MLX at 50% of total unified memory;
- calculates the largest context window that fits that limit, up to the
  model's native 262K tokens;
- shows download progress, in-memory loading, failures, and the active model;
- downloads weights into `~/Library/Caches/Dropsift/Models` only after the user
  selects the model or asks the first question.

There is no LM Studio, llama server, localhost API, Python runtime, terminal
command, or separate application.

Chat never uploads a transcript. Dropsift chunks and ranks transcript passages
locally, shows distinct retrieval, model-download/loading, and generation
states, and passes only relevant excerpts to its in-process model. Structured
source fragments are saved on each assistant message and link back to the
closest transcript segment. Threads persist in
`iCloud Drive/Dropsift/Threads/threads.json`.

Existing Quill users are handled conservatively: if a Dropsift library,
config, or model cache does not exist yet, the app reuses the corresponding
Quill location. Recordings, threads, settings, and downloaded weights are not
stranded by the rename.

## Config

Optional, at `~/.config/dropsift/config.json`:

```json
{
  "recordings_dir": "~/Library/Mobile Documents/com~apple~CloudDocs/Dropsift/Recordings",
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
- **SwiftUI + AppKit** — recording library, transcript reader, and chat threads
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
- iCloud Drive storage uses the visible `Dropsift` folder, not a hidden app
  container, so recordings remain directly accessible in Finder.

## License status

The original upstream Quill repository currently has no explicit software license. Public
GitHub visibility permits viewing and forking through GitHub, but does not
grant general commercial-use or redistribution rights. See
[`LICENSE_STATUS.md`](LICENSE_STATUS.md) and resolve the legal blocker in
[`TODO.md`](TODO.md) before commercial use.
