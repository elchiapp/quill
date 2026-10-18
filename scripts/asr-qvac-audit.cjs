// Untimed identity / metadata audit. Uses the installed SDK, not a patched app.
globalThis.require = require
const [runtime, model, audio, output] = Bare.argv.slice(2)
if (!output) throw new Error('Usage: asr-qvac-audit RUNTIME MODEL PCM OUTPUT')
const proc = require(runtime + '/node_modules/bare-process')
const fs = require(runtime + '/node_modules/bare-fs')
globalThis.process = proc
proc.env.PARAKEET_COREML_DISABLE = '1'

;(async () => {
  const base = runtime + '/node_modules/@qvac/inference'
  const pkg = require(base + '/package.json')
  const sdk = await import(base + '/dist/index.js')
  const { parakeetPlugin } = await import(base + '/' + pkg.exports['./parakeet-transcription/plugin'].import)
  const { stream } = await import(base + '/dist/engine.js')
  const api = sdk.plugins([parakeetPlugin])
  const modelId = await api.loadModel({ modelSrc: model, modelType: 'parakeet-transcription',
    modelConfig: { useGPU: true, maxThreads: 8, timestampsEnabled: true, streaming: false } })
  const info = await sdk.getLoadedModelInfo({ modelId })
  const events = []
  for await (const event of stream({ type: 'transcribe', modelId,
    audioChunk: { type: 'filePath', value: audio }, metadata: true, requestId: 'accuracy-audit' })) {
    events.push(event)
  }
  const metadataText = events.map(event => event.segment?.text ?? '').join(' ').trim()
  const plainText = await api.transcribe({ modelId, audioChunk: audio })
  await api.unloadModel({ modelId })
  await sdk.close()
  fs.writeFileSync(output, JSON.stringify({ info, metadataText, plainText, events,
    identical: metadataText.trim() === plainText.trim() }, null, 2))
  proc.stdout.write(JSON.stringify({ modelId, loadedPath: info.path,
    identical: metadataText.trim() === plainText.trim(), metadataCharacters: metadataText.length,
    plainCharacters: plainText.length }) + '\n')
})().catch(error => { console.error(error); Bare.exit(1) })
