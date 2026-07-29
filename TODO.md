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

- [x] Keep conversation selection visibly active while the composer has focus.
- [x] Add confirmed deletion for conversations and Trash-based deletion for
  recordings.
- [x] Pulse the menu-bar Dropsift mark subtly while a recording is active.
- [x] Add crash-safe, iCloud-synced live notes while recording.

## Product backlog

- [ ] Introduce a first-class knowledge-item model shared by recordings,
  notes, screenshots, images, PDFs, imported audio, and text files.
- [ ] Add drag-and-drop and file-picker ingestion with visible extraction,
  indexing, and failure states.
- [ ] Add a global screenshot shortcut with screen-permission onboarding,
  region/window capture, OCR, and a local visual description.
- [ ] Replace plain live notes with a WYSIWYG Markdown editor supporting
  headings, lists, checkboxes, links, images, and attachment drops.
- [ ] Index notes and imported items alongside transcripts so every chat can
  search the entire knowledge base.
- [ ] Make source cards open the exact PDF page, image region, note block, or
  transcript timestamp used in an answer.
- [ ] Let users rename detected speakers and remember voice profiles across
  meetings.
- [ ] Add synchronized audio playback that follows transcript timestamps.
- [ ] Add semantic embedding retrieval alongside the current local lexical
  ranking.
- [ ] Add streamed local-model responses and cancellation.
- [ ] Add generated meeting summaries, decisions, and action-item views.
- [x] Add automatic multilingual transcription for 25 European languages with
  Parakeet TDT v3 and persist the detected dominant language.
- [ ] Add import/export for existing audio and transcript files.
