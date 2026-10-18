const shortList = (maximumItems, maximumLength) => ({
  type: 'array', maxItems: maximumItems,
  items: { type: 'string', minLength: 1, maxLength: maximumLength }
})

export const responseSchemas = {
  presentation: {
    type: 'object', additionalProperties: false,
    properties: {
      title: { type: 'string', minLength: 3, maxLength: 140 },
      description: { type: 'string', minLength: 12, maxLength: 480 }
    },
    required: ['title', 'description']
  },
  summary: {
    type: 'object', additionalProperties: false,
    properties: {
      overview: { type: 'string', minLength: 12, maxLength: 1000 },
      participants: shortList(12, 80),
      topics: shortList(8, 100),
      decisions: shortList(8, 180),
      action_items: shortList(10, 180)
    },
    required: ['overview', 'participants', 'topics', 'decisions', 'action_items']
  }
}

export function structuredResponseFormat(format) {
  if (!format) return undefined
  const schema = responseSchemas[format]
  if (!schema) throw new Error(`Unknown structured response format: ${format}`)
  return { type: 'json_schema', json_schema: { name: format, schema } }
}
