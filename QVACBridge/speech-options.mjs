export const TRANSCRIBEPSY_SOURCE = Object.freeze({
  src: 'https://huggingface.co/qvac/TranscribePsy-250M-EU-sub-gguf/resolve/92460e0a8e7dc20f2fb126198bdd9eebb9ba2dc7/transcribepsy-250m-eu-sub.gguf',
  name: 'DropSift TranscribePsy 250M EU-sub Q8_0',
  engine: 'parakeet', addon: 'parakeet', expectedSize: 304879584,
  sha256Checksum: 'a93ef324d38e410b5e49389db95d06364eddbb890b74a69f311e482d2fda6f4b'
})

export function speechOptions(params = {}) {
  const route = params.speechRoute ?? 'sdk'
  const model = params.speechModel ?? 'parakeet'
  const acceleration = params.speechAcceleration ?? (params.speechCoreML ? 'coreml' : 'metal')
  if (!['sdk', 'fabricDirect'].includes(route)) throw new Error('Unknown QVAC speech route')
  if (!['parakeet', 'transcribepsy'].includes(model)) throw new Error('Unknown QVAC speech model')
  if (!['cpu', 'metal', 'coreml'].includes(acceleration)) throw new Error('Unknown QVAC speech acceleration')
  if (model === 'transcribepsy' && acceleration === 'coreml') {
    throw new Error('TranscribePsy Core ML is not available in this Fabric Speech addon. Use CPU or Metal. The standalone Core ML engine is a separate benchmark lane.')
  }
  return { route, model, acceleration,
    maxThreads: Math.max(1, Math.min(8, Math.trunc(params.speechThreads ?? 8))),
    // Explicit local weights are used for reproducible benchmark parity.
    modelPath: params.speechModelPath ?? null }
}

export function speechConfiguration(options) {
  return { useGPU: options.acceleration === 'metal', maxThreads: options.maxThreads,
    timestampsEnabled: true, streaming: false, seed: 0 }
}

export function configureSpeechEnvironment(env, options) {
  // Native code tests presence, not truthiness. Even the string "0" disables
  // Core ML. Remove the key completely when selecting its encoder.
  if (options.acceleration === 'coreml') {
    // bare-env performs unsetEnv but its proxy trap returns undefined. Reflect
    // avoids strict-mode delete throwing after a successful native unset.
    Reflect.deleteProperty(env, 'PARAKEET_COREML_DISABLE')
    if ('PARAKEET_COREML_DISABLE' in env) throw new Error('Could not enable the Core ML encoder environment')
  }
  else env.PARAKEET_COREML_DISABLE = '1'
  env.PARAKEET_COREML_COMPUTE_UNITS = 'cpu_and_ane'
}

export function speechFingerprint(options) { return JSON.stringify(options) }

// The native addon reports model-lifetime counters. Convert counters once at
// the bridge boundary, otherwise every chunk appears to include earlier work.
export function speechStatsDelta(current, previous) {
  if (!current) return current
  const value = { ...current }
  const counters = ['totalTime', 'totalWallMs', 'audioDuration', 'audioDurationMs', 'totalSamples', 'totalTokens',
    'processCalls', 'totalTranscriptions', 'totalEncodedFrames', 'encoderTime', 'decoderTime', 'melSpecTime',
    'encoderMs', 'decoderMs', 'melSpecMs']
  for (const key of counters) {
    if (typeof current[key] !== 'number') continue
    const before = previous?.[key] ?? 0
    value[key] = current[key] >= before ? current[key] - before : current[key]
  }
  if (previous && 'modelLoadMs' in value) value.modelLoadMs = 0
  return value
}

export function speechDiagnostics(stats, diagnostics = {}) {
  // backendId describes ggml (including the CPU decoder in a hybrid run).
  // Per-call encoderUsedCoreml is the authoritative encoder-routing flag.
  if (stats?.encoderUsedCoreml === 1) return { ...diagnostics,
    selectedBackend: 'coreml', selectedDevice: 'coreml-cpu-ne-eligible', npuHardwareVerified: false }
  return { ...diagnostics, npuHardwareVerified: false }
}

export function pcmSummary(bytes) {
  if (bytes.byteLength % 2 !== 0) throw new Error('Speech PCM must contain complete signed 16-bit samples')
  if (bytes.length >= 4 && String.fromCharCode(...bytes.subarray(0, 4)) === 'RIFF') {
    throw new Error('Speech input must be normalized raw 16 kHz mono PCM, not a WAV container')
  }
  let silent = true
  for (let i = 0; i < bytes.length; i++) if (bytes[i] !== 0) { silent = false; break }
  return { samples: bytes.byteLength / 2, durationMs: bytes.byteLength / 32, silent }
}

export function directSegments(output, durationMs) {
  // Resampled AAC can contain a fractional number of milliseconds. The wire
  // protocol is integer milliseconds, including the clamp boundary itself.
  const limit = Math.max(0, Math.floor(durationMs))
  const bounded = value => Math.max(0, Math.min(limit, Math.round(value)))
  return (Array.isArray(output) ? output : [output]).filter(s => s?.text?.trim()
    && !s.text.includes('[No speech detected]') && !s.text.includes('[BLANK_AUDIO]')).map(s => {
    const startMs = bounded((s.start ?? 0) * 1000)
    return { startMs, endMs: Math.max(startMs, bounded((s.end ?? durationMs / 1000) * 1000)), text: s.text }
  })
}
