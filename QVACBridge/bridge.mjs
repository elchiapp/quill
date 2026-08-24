import bareProcess from 'bare-process'
import {
  QWEN3_5_2B_MULTIMODAL_Q4_K_M,
  QWEN3_5_4B_MULTIMODAL_Q4_K_M,
  QWEN3_5_9B_MULTIMODAL_Q4_K_M,
  QWEN3_6_27B_MULTIMODAL_Q4_K_XL,
  QWEN3_6_35B_A3B_MULTIMODAL_Q4_K_M,
  PARAKEET_TDT_0_6B_V3_Q8_0,
  PARAKEET_SORTFORMER_4SPK_V2_1_Q8_0,
  OCR_LATIN,
  close,
  plugins
} from '@qvac/bare-sdk'
import { llmPlugin } from '@qvac/bare-sdk/llamacpp-completion/plugin'
import { whisperPlugin } from '@qvac/bare-sdk/whispercpp-transcription/plugin'
import { parakeetPlugin } from '@qvac/bare-sdk/parakeet-transcription/plugin'
import { ocrPlugin } from '@qvac/bare-sdk/ggml-ocr/plugin'

globalThis.process = bareProcess

const {
  completion,
  loadModel,
  ocr,
  transcribe,
  unloadModel
} = plugins([
  llmPlugin,
  whisperPlugin,
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
  const requested = llmModels[params.modelSize] ?? llmModels['2B']
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
        reasoning_budget: 0
      },
      onProgress
    })
  )
}

async function complete (id, params) {
  if (!loaded.llm) throw new Error('QVAC language model is not loaded.')
  const history = [
    { role: 'system', content: params.systemPrompt ?? '' },
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
    generationParams: {
      predict: params.maxTokens ?? 2048,
      temp: 0.4,
      top_p: 0.8,
      top_k: 20,
      repeat_penalty: 1.05,
      reasoning_budget: 0,
      remove_thinking_from_context: true
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

async function prepareTranscription (id) {
  await prepareModel(
    'transcription',
    id,
    'Downloading QVAC Parakeet speech model',
    onProgress => loadModel({
      modelSrc: PARAKEET_TDT_0_6B_V3_Q8_0,
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

async function transcribeAudio (id, params) {
  if (!loaded.transcription) {
    throw new Error('QVAC transcription model is not loaded.')
  }
  const text = await transcribe({
    modelId: loaded.transcription,
    audioChunk: params.audioPath
  })
  const normalized = text.trim()
  send({
    id,
    type: 'result',
    segments: normalized
      ? [{
          startMs: 0,
          endMs: params.audioDurationMs ?? 0,
          text: normalized
        }]
      : []
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
  const turns = []
  for (const line of result.split('\n')) {
    const match = line.match(/Speaker (\d+): ([\d.]+)s - ([\d.]+)s/)
    if (!match) continue
    turns.push({
      speaker: `speaker_${Number(match[1])}`,
      startMs: Math.round(Number(match[2]) * 1000),
      endMs: Math.round(Number(match[3]) * 1000),
      confidence: 1
    })
  }
  send({ id, type: 'result', turns })
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
        send({ id, type: 'result', text: 'QVAC 0.17.1 ready' })
        break
      case 'prepareLLM':
        await prepareLLM(id, params)
        break
      case 'complete':
        await complete(id, params)
        break
      case 'prepareTranscription':
        await prepareTranscription(id)
        break
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
