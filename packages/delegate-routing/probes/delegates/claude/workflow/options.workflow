// Claude Workflow script body (top-level await + return): sent verbatim as the Workflow tool input by mock_api.py, not a Node module.
export const meta = { name: 'offline-workflow-options', description: 'offline agent option and concurrency replay' }
const results = await parallel([
  () => agent('NODE_PIN_FIRST', { model: 'sonnet', effort: 'low', label: 'pinned' }),
  () => agent('PARALLEL_DEFAULT_1', { label: 'default-1' }),
  () => agent('PARALLEL_DEFAULT_2', { label: 'default-2' }),
  () => agent('PARALLEL_DEFAULT_3', { label: 'default-3' }),
])
return results
