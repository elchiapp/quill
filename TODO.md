# Quill TODO

This file is the product and engineering backlog. Keep it current as work lands.

## Legal blocker

- [ ] Obtain an explicit license or written commercial-use permission from
  Digimata. The upstream `digimata/quill` repository has no detected license,
  so public visibility and GitHub forking do not grant general commercial-use,
  redistribution, or sublicensing rights.
- [ ] After upstream permission is resolved, choose and add a license for the
  original Quill work owned by this fork's contributors.

## Current iteration

- [x] Diarize remote/system audio into stable `Speaker 1`, `Speaker 2`, …
  labels while keeping the microphone track labeled `You`.
- [x] Store diarization provenance in the canonical transcript.
- [x] Attach structured source fragments to every transcript-grounded answer.
- [x] Make each source open the corresponding recording and transcript
  timestamp.
- [x] Show separate retrieval and local-model generation loading states.
- [x] Package and validate the updated app.
- [ ] Push the work to the `elchiapp/quill` GitHub fork.

## Product backlog

- [ ] Let users rename detected speakers and remember voice profiles across
  meetings.
- [ ] Add synchronized audio playback that follows transcript timestamps.
- [ ] Add semantic embedding retrieval alongside the current local lexical
  ranking.
- [ ] Add streamed local-model responses and cancellation.
- [ ] Add generated meeting summaries, decisions, and action-item views.
- [ ] Add multilingual transcription.
- [ ] Add import/export for existing audio and transcript files.
