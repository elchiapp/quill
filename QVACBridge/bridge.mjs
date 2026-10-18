import bareProcess from 'bare-process'
import {
  QWEN3_5_2B_MULTIMODAL_Q4_K_M,
  QWEN3_5_4B_MULTIMODAL_Q4_K_M,
  QWEN3_5_9B_MULTIMODAL_Q4_K_M,
  QWEN3_6_27B_MULTIMODAL_Q4_K_XL,
  QWEN3_6_35B_A3B_MULTIMODAL_Q4_K_M,
  QWEN3_8_27B_MULTIMODAL_UD_Q4_K_XL,
  PARAKEET_TDT_0_6B_V3_Q8_0,
  PARAKEET_SORTFORMER_4SPK_V2_1_Q8_0,
  OCR_LATIN,
  close,
  plugins
} from '@qvac/inference'
import { llmPlugin } from '@qvac/inference/llamacpp-completion/plugin'
import { parakeetPlugin } from '@qvac/inference/parakeet-transcription/plugin'
import { ocrPlugin } from '@qvac/inference/ggml-ocr/plugin'
import { stream as engineStream } from '@qvac/inference/engine'
import { stageParakeetCoreML } from './speech-models.mjs'
import { structuredResponseFormat } from './structured-output.mjs'
import { parseSpeakerTurns } from './diarization.mjs'

globalThis.process = bareProcess

const {
  completion,
  loadModel,
  ocr,
  transcribe,
  unloadModel
} = plugins([
  llmPlugin,
  parakeetPlugin,
  ocrPlugin
])

const protocolPrefix = '__DROPSIFT_QVAC__'
const loaded = {
  llm: null,
  transcription: null,
  diarization: null,
  ocr: null
}
const loading = {
  llm: null,
  transcription: null,
  diarization: null,
  ocr: null
}

const llmModels = {
  '2B': QWEN3_5_2B_MULTIMODAL_Q4_K_M,
  '4B': QWEN3_5_4B_MULTIMODAL_Q4_K_M,
  '9B': QWEN3_5_9B_MULTIMODAL_Q4_K_M,
  '27B': QWEN3_6_27B_MULTIMODAL_Q4_K_XL,
  '35B': QWEN3_6_35B_A3B_MULTIMODAL_Q4_K_M
}

const llmModelsById = {
  'mlx-community/Qwen3.5-2B-4bit': QWEN3_5_2B_MULTIMODAL_Q4_K_M,
  'mlx-community/Qwen3.5-4B-4bit': QWEN3_5_4B_MULTIMODAL_Q4_K_M,
  'mlx-community/Qwen3.5-9B-4bit': QWEN3_5_9B_MULTIMODAL_Q4_K_M,
  'mlx-community/Qwen3.6-27B-4bit': QWEN3_6_27B_MULTIMODAL_Q4_K_XL,
  'mlx-community/Qwen3.6-35B-A3B-4bit': QWEN3_6_35B_A3B_MULTIMODAL_Q4_K_M,
  'mlx-community/Qwen3.8-27B-4bit': QWEN3_8_27B_MULTIMODAL_UD_Q4_K_XL
}

function send (value) {
  bareProcess.stdout.write(protocolPrefix + JSON.stringify(value) + '\n')
}

function errorMessage (error) {
  if (error instanceof Error) return error.message
  return String(error)
}

async function prepareModel (kind, id, detail, loader) {
  if (loaded[kind]) {
    send({ id, type: 'result', model: loaded[kind] })
    return
  }

  let entry = loading[kind]
  if (!entry) {
    const listeners = new Set()
    let lastPercentage = -1
    const task = Promise.resolve().then(() => loader(progress => {
      const percentage = Math.max(
        0,
        Math.min(100, progress.percentage ?? 0)
      )
      // Registry downloads report every tiny block. A quarter-percent update
      // keeps the UI smooth without flooding the bridge with tens of thousands
      // of redundant JSON messages.
      if (percentage < 100 && percentage - lastPercentage < 0.25) return
      lastPercentage = percentage
      for (const listener of listeners) {
        send({
          id: listener,
          type: 'progress',
          percentage,
          downloaded: progress.downloaded,
          total: progress.total,
          detail
        })
      }
    })).then(modelId => {
      loaded[kind] = modelId
      return modelId
    }).finally(() => {
      if (loading[kind]?.task === task) loading[kind] = null
    })
    entry = { listeners, task }
    loading[kind] = entry
  }

  entry.listeners.add(id)
  try {
    const modelId = await entry.task
    send({ id, type: 'result', model: modelId })
  } finally {
    entry.listeners.delete(id)
  }
}

async function unload (kind) {
  const modelId = loaded[kind]
  if (!modelId) return
  loaded[kind] = null
  await unloadModel({ modelId, clearStorage: false })
}

async function prepareLLM (id, params) {
  const requested = llmModelsById[params.modelID] ??
    llmModels[params.modelSize] ??
    llmModels['2B']
  await prepareModel(
    'llm',
    id,
    'Downloading QVAC language model',
    onProgress => loadModel({
      modelSrc: requested,
      modelType: 'llamacpp-completion',
      modelConfig: {
        ctx_size: Math.max(16384, Math.min(262144, params.contextTokens ?? 32768)),
        temp: 0.4,
        top_p: 0.8,
        top_k: 20,
        repeat_penalty: 1.05,
        gpu_layers: 999,
        reasoning_budget: 0
      },
      onProgress
    })
  )
}

async function complete (id, params) {
  if (!loaded.llm) throw new Error('QVAC language model is not loaded.')
  const history = [
    { role: 'system', content: (params.systemPrompt ?? '') + '\n/no_think' },
    ...(params.messages ?? []).map(message => ({
      role: message.role,
      content: message.content
    }))
  ]
  const run = completion({
    modelId: loaded.llm,
    history,
    stream: true,
    captureThinking: true,
    toolDialect: 'qwen35',
    responseFormat: structuredResponseFormat(params.responseFormat),
    generationParams: {
      predict: params.maxTokens ?? 2048,
      temp: 0.4,
      top_p: 0.8,
      top_k: 20,
      repeat_penalty: 1.05,
      reasoning_budget: 0
    }
  })
  let text = ''
  for await (const event of run.events) {
    if (event.type !== 'contentDelta' || !event.text) continue
    text += event.text
    send({ id, type: 'token', text: event.text })
  }
  const final = await run.final
  const content = final.content || text
  if (!text && content) send({ id, type: 'token', text: content })
  send({ id, type: 'result', text: content })
}

async function prepareTranscription (id, params = {}) {
  await prepareModel(
    'transcription',
    id,
    'Downloading QVAC Parakeet speech model',
    async onProgress => {
      // Registry downloads can include Core ML companions automatically. Do not
      // let cache contents silently override the measured Metal default.
      bareProcess.env.PARAKEET_COREML_DISABLE = params.speechCoreML ? '0' : '1'
      return loadModel({
        modelSrc: params.speechCoreML
          ? await stageParakeetCoreML({ modelPath: params.speechModelPath, onProgress })
          : params.speechModelPath ?? PARAKEET_TDT_0_6B_V3_Q8_0,
        modelType: 'parakeet-transcription',
        modelConfig: {
          useGPU: true,
          maxThreads: 8,
          timestampsEnabled: true,
          streaming: false
        },
        onProgress
      })
    }
  )
}

async function transcribeAudio (id, params) {
  if (!loaded.transcription) {
    throw new Error('QVAC transcription model is not loaded.')
  }
  const segments = []
  let stats
  let diagnostics
  for await (const event of engineStream({
    type: 'transcribe',
    modelId: loaded.transcription,
    audioChunk: { type: 'filePath', value: params.audioPath },
    metadata: true,
    requestId: id
  })) {
    if (event.segment?.text?.trim()) {
      segments.push({
        startMs: Math.round(event.segment.startMs ?? 0),
        endMs: Math.round(event.segment.endMs ?? params.audioDurationMs ?? 0),
        text: event.segment.text
      })
    }
    if (event.stats) stats = event.stats
    if (event.diagnostics) diagnostics = event.diagnostics
  }
  send({
    id,
    type: 'result',
    segments,
    stats,
    diagnostics
  })
}

async function prepareDiarization (id) {
  await prepareModel(
    'diarization',
    id,
    'Downloading QVAC speaker model',
    onProgress => loadModel({
      modelSrc: PARAKEET_SORTFORMER_4SPK_V2_1_Q8_0,
      modelType: 'parakeet-transcription',
      modelConfig: {
        useGPU: true,
        maxThreads: 8,
        timestampsEnabled: true,
        streaming: false
      },
      onProgress
    })
  )
}

async function diarizeAudio (id, params) {
  if (!loaded.diarization) {
    throw new Error('QVAC diarization model is not loaded.')
  }
  const result = await transcribe({
    modelId: loaded.diarization,
    audioChunk: params.audioPath
  })
  const turns = parseSpeakerTurns(result, params.audioDurationMs ?? Infinity)
  if (!turns.length && /Speaker\s+\d+:/i.test(result)) {
    throw new Error('QVAC returned an unrecognized speaker timeline; no speaker labels were changed.')
  }
  send({ id, type: 'result', turns, text: result })
}

async function prepareOCR (id) {
  await prepareModel(
    'ocr',
    id,
    'Downloading QVAC OCR model',
    onProgress => loadModel({
      modelSrc: OCR_LATIN,
      modelType: 'ggml-ocr',
      modelConfig: {
        magRatio: 1.5,
        defaultRotationAngles: [90, 180, 270],
        contrastRetry: true,
        lowConfidenceThreshold: 0.35,
        recognizerBatchSize: 1,
        backendDevice: 'metal'
      },
      onProgress
    })
  )
}

async function extractImageText (id, params) {
  if (!loaded.ocr) throw new Error('QVAC OCR model is not loaded.')
  const result = ocr({
    modelId: loaded.ocr,
    image: params.imagePath,
    options: { paragraph: false }
  })
  const blocks = await result.blocks
  send({
    id,
    type: 'result',
    blocks: blocks.map(block => ({
      text: block.text,
      confidence: block.confidence
    }))
  })
}

async function handle (request) {
  const { id, method, params = {} } = request
  try {
    switch (method) {
      case 'ping':
        send({ id, type: 'result', text: 'QVAC inference 0.21.1 ready' })
        break
      case 'prepareLLM':
        await prepareLLM(id, params)
        break
      case 'complete':
        await complete(id, params)
        break
      case 'prepareTranscription':
        await prepareTranscription(id, params)
        break
      case 'prepareSpeechAssets': {
        const model = await stageParakeetCoreML({ modelPath: params.speechModelPath })
        send({ id, type: 'result', model })
        break
      }
      case 'transcribe':
        await transcribeAudio(id, params)
        break
      case 'prepareDiarization':
        await prepareDiarization(id)
        break
      case 'diarize':
        await diarizeAudio(id, params)
        break
      case 'prepareOCR':
        await prepareOCR(id)
        break
      case 'extractImageText':
        await extractImageText(id, params)
        break
      case 'unloadLLM':
        await unload('llm')
        send({ id, type: 'result' })
        break
      case 'unloadTranscription':
        await unload('transcription')
        send({ id, type: 'result' })
        break
      case 'unloadDiarization':
        await unload('diarization')
        send({ id, type: 'result' })
        break
      case 'unloadOCR':
        await unload('ocr')
        send({ id, type: 'result' })
        break
      case 'shutdown':
        await unload('ocr')
        await unload('diarization')
        await unload('transcription')
        await unload('llm')
        await close()
        send({ id, type: 'result' })
        break
      default:
        throw new Error(`Unknown QVAC bridge method: ${method}`)
    }
  } catch (error) {
    send({ id, type: 'error', error: errorMessage(error) })
  }
}

let input = ''
bareProcess.stdin.on('data', chunk => {
  input += chunk.toString()
  while (true) {
    const newline = input.indexOf('\n')
    if (newline < 0) break
    const line = input.slice(0, newline).trim()
    input = input.slice(newline + 1)
    if (!line) continue
    try {
      void handle(JSON.parse(line))
    } catch (error) {
      send({ id: '', type: 'error', error: errorMessage(error) })
    }
  }
})
bareProcess.stdin.on('end', () => bareProcess.exit(0))
bareProcess.stdin.on('error', () => bareProcess.exit(1))
bareProcess.stdin.resume()
send({ id: 'startup', type: 'ready', text: 'QVAC bridge ready' })
