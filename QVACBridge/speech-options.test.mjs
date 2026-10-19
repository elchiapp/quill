import test from 'node:test'
import assert from 'node:assert/strict'
import { speechOptions, speechConfiguration, speechFingerprint, pcmSummary, directSegments, speechStatsDelta, speechDiagnostics, configureSpeechEnvironment } from './speech-options.mjs'

test('speech defaults preserve the SDK Parakeet Metal route', () => {
  const value = speechOptions()
  assert.equal(value.route, 'sdk'); assert.equal(value.model, 'parakeet'); assert.equal(value.acceleration, 'metal')
})
test('CPU never requests GPU and Core ML is explicit', () => {
  assert.equal(speechConfiguration(speechOptions({ speechAcceleration: 'cpu' })).useGPU, false)
  assert.equal(speechConfiguration(speechOptions({ speechAcceleration: 'coreml' })).useGPU, false)
  assert.equal(speechConfiguration(speechOptions()).useGPU, true)
})
test('Core ML removes the presence-based native disable flag, including a stale zero value', () => {
  const env = { PARAKEET_COREML_DISABLE: '0' }
  configureSpeechEnvironment(env, speechOptions({speechAcceleration:'coreml'}))
  assert.equal('PARAKEET_COREML_DISABLE' in env, false)
  assert.equal(env.PARAKEET_COREML_COMPUTE_UNITS, 'cpu_and_ane')
  configureSpeechEnvironment(env, speechOptions({speechAcceleration:'cpu'}))
  assert.equal(env.PARAKEET_COREML_DISABLE, '1')
  configureSpeechEnvironment(env, speechOptions({speechAcceleration:'coreml'}))
  assert.equal('PARAKEET_COREML_DISABLE' in env, false)
})
test('Core ML handles bare-env unset semantics without a strict-mode proxy error', () => {
  const target = { PARAKEET_COREML_DISABLE: '1' }
  const env = new Proxy(target, { deleteProperty(object, key) { delete object[key] } })
  configureSpeechEnvironment(env, speechOptions({speechAcceleration:'coreml'}))
  assert.equal('PARAKEET_COREML_DISABLE' in target, false)
})
test('invalid and unsupported selections fail rather than silently falling back', () => {
  for (const value of [{speechRoute:'invalid'}, {speechModel:'whisper'}, {speechAcceleration:'npu'}, {speechModel:'transcribepsy',speechAcceleration:'coreml'}]) {
    assert.throws(() => speechOptions(value))
  }
})
test('changing route/model/compute changes the cache identity', () => {
  const base = speechFingerprint(speechOptions())
  for (const value of [{speechRoute:'fabricDirect'}, {speechModel:'transcribepsy'}, {speechAcceleration:'cpu'}]) {
    assert.notEqual(speechFingerprint(speechOptions(value)), base)
  }
})
test('digital silence and invalid PCM are distinguished', () => {
  assert.deepEqual(pcmSummary(new Uint8Array(32000)), {samples:16000,durationMs:1000,silent:true})
  assert.equal(pcmSummary(new Uint8Array([1,0])).silent, false)
  assert.throws(() => pcmSummary(new Uint8Array([1])))
  assert.throws(() => pcmSummary(new TextEncoder().encode('RIFF')))
})
test('direct timestamps are seconds converted once and bounded to the chunk', () => {
  assert.deepEqual(directSegments({text:'test',start:0.25,end:1.5},1000), [{text:'test',startMs:250,endMs:1000}])
})
test('fractional-millisecond AAC normalization still emits integer protocol timestamps', () => {
  const [segment] = directSegments({text:'AAC',start:0,end:15},14880.75)
  assert.equal(Number.isInteger(segment.endMs), true)
  assert.equal(segment.endMs, 14880)
})
test('native no-speech markers do not become transcript or knowledge-base content', () => {
  assert.deepEqual(directSegments({text:'[No speech detected]',start:0,end:1},1000), [])
})
test('model-lifetime native counters become per-request values', () => {
  assert.deepEqual(speechStatsDelta({totalSamples:32000,totalTime:50,encoderUsedCoreml:1,modelLoadMs:20},
    {totalSamples:16000,totalTime:30}), {totalSamples:16000,totalTime:20,encoderUsedCoreml:1,modelLoadMs:0})
  assert.equal(speechStatsDelta({totalTime:5},{totalTime:20}).totalTime, 5)
})
test('Core ML encoder routing is distinct from the ggml CPU decoder and never proves NPU hardware', () => {
  const value = speechDiagnostics({encoderUsedCoreml:1,backendId:0},{selectedBackend:'cpu',requestedAcceleration:'coreml'})
  assert.equal(value.selectedBackend, 'coreml')
  assert.equal(value.npuHardwareVerified, false)
  assert.equal(speechDiagnostics({encoderUsedCoreml:0},{selectedBackend:'cpu'}).selectedBackend, 'cpu')
})
