import fs from 'bare-fs'
import ASRGgml from '@qvac/asr-ggml'
import { directSegments, pcmSummary, speechConfiguration, speechStatsDelta } from './speech-options.mjs'

// Direct public binding to the same Fabric Speech native engine as the SDK.
// No SDK inference dispatch, model registry or transcription adapter is used.
export class FabricSpeech {
  constructor(modelPath, options) {
    this.options = options
    this.model = new ASRGgml({ files: { model: modelPath },
      config: { engine: 'parakeet', parakeetConfig: speechConfiguration(options) },
      enableStats: true, logger: null })
  }
  async load() { await this.model.load() }
  async destroy() { await this.model.destroy() }
  async cancel() { await this.model.cancel() }
  async transcribe(audioPath) {
    const bytes = fs.readFileSync(audioPath)
    const summary = pcmSummary(bytes)
    if (summary.silent) return { segments: [], stats: { totalSamples: summary.samples, audioDurationMs: summary.durationMs },
      diagnostics: { speechRoute: 'fabricDirect', bypassReason: 'digital-silence' } }
    // Use the public asynchronous file-stream input, like the SDK adapter.
    // This bounds transfer buffers instead of materializing an extra complete
    // Float32 input array at the call boundary.
    const response = await this.model.run(fs.createReadStream(audioPath))
    let stats
    response.on('stats', value => { stats = value })
    const segments = []
    for await (const output of response.iterate()) segments.push(...directSegments(output, summary.durationMs))
    await response.await()
    stats ??= response.stats
    const info = this.model.getBackendInfo()
    const coreml = stats?.encoderUsedCoreml === 1
    const backend = coreml ? 'coreml' : ({ 0: 'cpu', 1: 'metal', 2: 'cuda', 3: 'vulkan', 4: 'opencl' }[stats?.backendId ?? info?.backendId] ?? 'unknown')
    const delta = speechStatsDelta(stats, this.previousStats)
    this.previousStats = stats
    return { segments, stats: delta, rawStats: stats, diagnostics: { speechRoute: 'fabricDirect',
      selectedBackend: backend, selectedDevice: coreml ? 'coreml-cpu-ne-eligible' : stats?.backendDevice === 1 ? 'gpu' : 'cpu',
      requestedAcceleration: this.options.acceleration, encoderBackend: info?.encoderBackend,
      npuHardwareVerified: false } }
  }
}
