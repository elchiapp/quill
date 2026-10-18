import assert from 'node:assert/strict'
import test from 'node:test'
import { parseSpeakerTurns } from './diarization.mjs'

test('accepts the actual Speech Fabric 0.10 clock response and clamps frame padding', () => {
  assert.deepEqual(parseSpeakerTurns('Speaker 0: 00:00:00.000 - 00:00:11.200', 11157), [
    { speaker: 'speaker_0', startMs: 0, endMs: 11157, confidence: 1 }
  ])
})
test('keeps legacy fractional seconds and multiple speakers', () => {
  assert.deepEqual(parseSpeakerTurns('Speaker 1: 0.25s - 2.5s\nSpeaker 2: 2.5s - 9.125s').map(
    ({ speaker, startMs, endMs }) => ({ speaker, startMs, endMs })
  ), [
    { speaker: 'speaker_1', startMs: 250, endMs: 2500 },
    { speaker: 'speaker_2', startMs: 2500, endMs: 9125 }
  ])
})
test('preserves hour-long offsets without accepting malformed or backwards times', () => {
  assert.equal(parseSpeakerTurns('Speaker 3: 01:02:03.456 - 01:02:05.789')[0].startMs, 3723456)
  assert.deepEqual(parseSpeakerTurns('Speaker 0: 00:99:01.000 - 00:99:02.000'), [])
  assert.deepEqual(parseSpeakerTurns('Speaker 0: 2s - 1s'), [])
  assert.deepEqual(parseSpeakerTurns('No speech detected'), [])
})
