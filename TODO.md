# Dropsift TODO

This file is the product and engineering backlog. Keep it current as work lands.

## Legal blocker

- [ ] Obtain an explicit license or written commercial-use permission from
  Digimata. The upstream `digimata/quill` repository has no detected license,
  so public visibility and GitHub forking do not grant general commercial-use,
  redistribution, or sublicensing rights.
- [ ] After upstream permission is resolved, choose and add a license for the
  new Dropsift work owned by this fork's contributors.

## Dropsift product foundation

- [x] Rename the app, executable, bundle identity, assistant persona, package,
  documentation, and menu-bar identity to Dropsift.
- [x] Replace the Quill feather with a funnel-to-pinpoint Dropsift mark.
- [x] Keep existing Quill recordings, threads, config, model cache, and
  launch-agent cleanup compatible after the rename.
- [ ] Rename the GitHub repository after downstream links and release
  automation are ready to move.

## Current iteration

- [x] Diarize remote/system audio into stable `Speaker 1`, `Speaker 2`, …
  labels while keeping the microphone track labeled `You`.
- [x] Store diarization provenance in the canonical transcript.
- [x] Attach structured source fragments to every transcript-grounded answer.
- [x] Make each source open the corresponding recording and transcript
  timestamp.
- [x] Show separate retrieval and local-model generation loading states.
- [x] Package and validate the updated app.
- [x] Push the work to the `elchiapp/quill` GitHub fork.

## Built-in inference iteration

- [x] Replace all external local-server integration with in-process MLX
  inference.
- [x] Download and manage model weights entirely inside Dropsift.
- [x] Show model download and loading progress in chat and Settings.
- [x] Validate transcript-grounded generation with the built-in model.
- [x] Rebuild, sign, and install the standalone app update.
- [x] Push the standalone app update to the fork.

## Hardware-aware local models

- [x] Detect the Apple chip, CPU count, and unified memory.
- [x] Make Qwen3.5 2B 4-bit the conservative default.
- [x] Recommend current Qwen3.5/Qwen3.6 models from device capabilities.
- [x] Ask before downloading a stronger recommended model.
- [x] Enforce a hard 50% unified-memory limit for MLX.
- [x] Maximize context within that limit, up to the native 262K window.
- [x] Show model download, in-memory loading, ready, and failure states.
- [x] Validate, package, install, and push the hardware-aware update.

## Desktop interaction polish

- [x] Restore the standard macOS application menu, including Settings and
  Cmd+Q termination.
- [x] Keep conversation selection visibly active while the composer has focus.
- [x] Add confirmed deletion for conversations and Trash-based deletion for
  recordings.
- [x] Pulse the menu-bar Dropsift mark subtly while a recording is active.
- [x] Add crash-safe, iCloud-synced live notes while recording.

## Universal capture and timeline

- [x] Add one clean Capture view with large actions for notes, documents,
  images, existing recordings, and live recording.
- [x] Add file-picker and drag-and-drop ingestion with visible extraction and
  import states.
- [x] Add iCloud-synced note, document, and image storage with extracted text
  and optional additional notes.
- [x] Import existing audio into the normal transcription and diarization
  queue.
- [x] Add one chronological Timeline with searchable, multi-select type
  filters and type-specific previews.
- [x] Index notes, document text, image OCR, imported-item notes, and
  transcripts in the same chat retrieval flow.
- [x] Link answer sources to transcript timestamps, PDF pages, and knowledge
  items.
- [x] Detect likely meetings locally and ask through an actionable
  notification before recording.

## iPhone and Apple Watch

- [x] Add a native iPhone Capture, Timeline, preview/edit, deletion, and Ask
  experience.
- [x] Reuse the Mac's visible iCloud Drive library through a persistent
  user-granted folder bookmark.
- [x] Add one-tap phone voice messages and on-device Apple Speech
  transcription with automatic Mac/Parakeet fallback.
- [x] Add a native Watch voice recorder with durable background transfer to
  the paired iPhone.
- [x] Adopt Watch audio into the existing desktop recording schema and refresh
  the Mac library/transcription queue automatically.
- [x] Preserve source cards and deep-link phone answers to transcript
  timestamps and PDF pages.
- [x] Add shared-schema regression tests plus physical-device build targets.
- [x] Pin mobile signing to the intended personal Apple team and add the
  App Store export-compliance declaration.
- [ ] Sign into the intended personal Apple Account in Xcode, create the
  matching App Store Connect record, archive, and upload the first TestFlight
  build.
- [ ] Run the paired-device delivery checklist on the release iPhone and Apple
  Watch before the first TestFlight upload. Simulator runtimes do not exercise
  Watch Connectivity file transfers.

## Product backlog

- [ ] Migrate recordings into the same on-disk first-class item schema now
  used by notes, images, and documents. The UI already presents all of them as
  a shared timeline item.
- [ ] Add a global screenshot shortcut with screen-permission onboarding,
  region/window capture, OCR, and a local visual description.
- [ ] Upgrade the Markdown write/preview editor into true rich-text WYSIWYG
  editing with inline images and attachment drops.
- [ ] Extend source navigation from the current transcript timestamp/PDF
  page/item links to exact image regions and note-block highlighting.
- [ ] Let users rename detected speakers and remember voice profiles across
  meetings.
- [ ] Add synchronized audio playback that follows transcript timestamps.
- [ ] Add semantic embedding retrieval alongside the current local lexical
  ranking.
- [ ] Add streamed local-model responses and cancellation.
- [ ] Add generated meeting summaries, decisions, and action-item views.
- [x] Add automatic multilingual transcription for 25 European languages with
  Parakeet TDT v3 and persist the detected dominant language.
- [ ] Add transcript-file import and complete knowledge-base export. Existing
  audio import is implemented.
