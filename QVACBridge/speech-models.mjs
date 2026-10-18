import fs from 'bare-fs'
import path from 'bare-path'
import { downloadAsset, getModelInfo } from '@qvac/inference'

const encoderFiles = [
  ['PARAKEET_TDT_COREMLDATA', 'analytics/coremldata.bin'],
  ['PARAKEET_TDT_COREMLDATA_1', 'coremldata.bin'],
  ['PARAKEET_TDT_METADATA', 'metadata.json'],
  ['PARAKEET_TDT_MODEL', 'model.mil'],
  ['PARAKEET_TDT_WEIGHT', 'weights/weight.bin']
]

export async function stageParakeetCoreML ({ modelPath, onProgress = () => {} } = {}) {
  const assets = modelPath ? encoderFiles : [
    ['PARAKEET_TDT_0_6B_V3_Q8_0', '../parakeet-tdt-0.6b-v3.q8_0.gguf'], ...encoderFiles
  ]
  const infos = await Promise.all(assets.map(async ([name, relative]) => ({
    name, relative, info: await getModelInfo({ name })
  })))
  const total = infos.reduce((sum, item) => sum + item.info.expectedSize, 0)
  let completed = 0
  let stagedRoot
  let sourceModel = modelPath
  for (const item of infos) {
    let { info } = item
    if (!info.isCached) {
      if (!info.registrySource || !info.registryPath) throw new Error(`No registry asset for ${item.name}`)
      await downloadAsset({
        assetSrc: `registry://${info.registrySource}/${info.registryPath}`,
        onProgress: progress => onProgress({
          downloaded: completed + (progress.downloaded ?? 0), total,
          percentage: 100 * (completed + (progress.downloaded ?? 0)) / Math.max(total, 1)
        })
      })
      info = await getModelInfo({ name: item.name })
    }
    const source = info.cacheFiles.find(file => file.isCached)?.path
    if (!source) throw new Error(`Core ML asset was not cached: ${item.name}`)
    stagedRoot ??= path.join(path.dirname(source), 'parakeet-tdt-0.6b-v3-coreml-20260928')
    if (item.name === 'PARAKEET_TDT_0_6B_V3_Q8_0') sourceModel = source
    else {
      const destination = path.join(stagedRoot, 'parakeet-tdt-0.6b-v3-encoder.mlmodelc', item.relative)
      fs.mkdirSync(path.dirname(destination), { recursive: true })
      if (!fs.existsSync(destination)) fs.linkSync(source, destination)
    }
    completed += info.expectedSize
    onProgress({ downloaded: completed, total, percentage: 100 * completed / Math.max(total, 1) })
  }
  if (!sourceModel || !stagedRoot) throw new Error('Parakeet Core ML model is incomplete')
  const destination = path.join(stagedRoot, 'parakeet-tdt-0.6b-v3.q8_0.gguf')
  fs.mkdirSync(stagedRoot, { recursive: true })
  if (!fs.existsSync(destination)) fs.linkSync(sourceModel, destination)
  return destination
}
