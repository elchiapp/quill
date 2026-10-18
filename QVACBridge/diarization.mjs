function timestampMs(value) {
  const text = value.trim().replace(/s$/i, '')
  if (/^\d+(?:\.\d+)?$/.test(text)) return Math.round(Number(text) * 1000)
  if (!/^\d+:\d{2}:\d{2}(?:\.\d+)?$/.test(text)) return null
  const [hours, minutes, seconds] = text.split(':').map(Number)
  if (minutes >= 60 || seconds >= 60) return null
  return Math.round((hours * 3600 + minutes * 60 + seconds) * 1000)
}

export function parseSpeakerTurns(text, durationMs = Infinity) {
  const turns = []
  const pattern = /Speaker\s+(\d+):\s*([\d:.]+s?)\s*[-–—]\s*([\d:.]+s?)/gi
  for (const match of text.matchAll(pattern)) {
    const startMs = timestampMs(match[2])
    const end = timestampMs(match[3])
    if (startMs === null || end === null) continue
    const endMs = Math.min(end, durationMs)
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) continue
    turns.push({ speaker: `speaker_${Number(match[1])}`, startMs, endMs, confidence: 1 })
  }
  return turns
}
