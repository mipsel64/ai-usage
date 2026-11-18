const FEED_SUFFIX = '/Library/Application Support/ai-usage/claude-desktop.json'
const ISO_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/

function isRecord(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function feedPath(home) {
  if (typeof home !== 'string' || !home.startsWith('/') || home.includes('\0')) return undefined
  const parts = home.split('/')
  if (parts.includes('.') || parts.includes('..')) return undefined
  return `${home.replace(/\/+$/, '')}${FEED_SUFFIX}`
}

function quotaReport(usage, observedAt) {
  if (!Number.isSafeInteger(observedAt) || !isRecord(usage) || !Array.isArray(usage.rateLimits)) {
    return undefined
  }

  const rateLimits = []
  const seen = new Set()
  for (const candidate of usage.rateLimits) {
    if (!isRecord(candidate) || typeof candidate.kind !== 'string') return undefined
    const kind = candidate.kind
    if (kind !== 'five_hour' && kind !== 'seven_day') continue
    if (seen.has(kind)) return undefined
    seen.add(kind)

    const percentUsed = candidate.percentUsed
    if (typeof percentUsed !== 'number' || !Number.isFinite(percentUsed) || percentUsed < 0 || percentUsed > 100) {
      return undefined
    }
    const limit = { kind, percentUsed }

    if (candidate.resetsAt !== undefined) {
      // Mod reset dates are ISO 8601; the menu's local feed uses epoch seconds.
      if (typeof candidate.resetsAt !== 'string' || !ISO_TIMESTAMP.test(candidate.resetsAt)) {
        return undefined
      }
      const resetMilliseconds = Date.parse(candidate.resetsAt)
      const resetsAt = Math.floor(resetMilliseconds / 1000)
      if (!Number.isFinite(resetMilliseconds) || !Number.isSafeInteger(resetsAt)) return undefined
      limit.resetsAt = resetsAt
    }
    rateLimits.push(limit)
  }

  if (rateLimits.length === 0) return undefined
  return { observedAt, rateLimits }
}

export function register(on) {
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    try {
      const surfaces = await $.session.surfaces()
      if (!surfaces.includes('desktop')) return result

      const usage = await $.session.usage()
      const report = quotaReport(usage, Math.floor(Date.now() / 1000))
      if (report === undefined) return result

      const path = feedPath(await $.env.get('HOME'))
      if (path === undefined) return result
      const dir = await $.fs.stat(path.slice(0, path.lastIndexOf('/')))
      const file = await $.fs.stat(path)
      if (dir.kind !== 'dir' || dir.isLink || file.kind !== 'file' || file.isLink) return result
      await $.fs.write(path, JSON.stringify(report))
    } catch {
      // Capture is best-effort. Do not log errors or replace the turn's result.
    }
    return result
  })
}
