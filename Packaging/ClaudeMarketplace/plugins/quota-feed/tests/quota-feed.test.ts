import type { SessionRateLimit, SessionUsage, TurnCompleteInput } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const HOME = '/Users/offline'
const FEED_PATH = `${HOME}/Library/Application Support/ai-usage/claude-desktop.json`
const DEFAULT_RESULT = { text: 'default turn result' }
const TURN: TurnCompleteInput = {
  turnId: 'turn-test',
  answer: 'assistant answer',
  durationMs: 1,
  isAborted: false,
  reason: 'answer',
}

type Write = { path: string; text: string }
const prepared = (path: string) => ({
  kind: path === FEED_PATH ? 'file' as const : 'dir' as const,
  isLink: false, size: 0, mtimeMs: 0,
})

function usage(rateLimits: SessionRateLimit[]) {
  const value = {
    startedAt: 0,
    context: { window: 200_000 },
    rateLimits,
  }
  return value
}

function oneWrite(writes: Write[]): Write {
  expect(writes).toHaveLength(1)
  const write = writes[0]
  if (write === undefined) throw new Error('missing captured write')
  return write
}

test('writes canonical percentages and converts ISO resets to Unix seconds', async ($, on) => {
  const writes: Write[] = []
  mock.env(on, { HOME })
  on('session.surfaces', () => ({ value: ['desktop'] as const }))
  on('session.usage', () => ({
    value: usage([
      { kind: 'five_hour', percentUsed: 23.5, resetsAt: '1970-01-01T00:02:03.456Z' },
      { kind: 'seven_day', percentUsed: 7 },
      { kind: 'spend_limit', percentUsed: 150, resetsAt: '1970-01-01T00:00:00Z' },
    ]),
  }))
  on('fs.stat', (_, e) => ({ value: prepared(e.path) }))
  on('fs.write', ($, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('turn.complete', () => DEFAULT_RESULT)

  const before = Math.floor(Date.now() / 1000)
  const result = await $.turn.complete(TURN)
  const after = Math.floor(Date.now() / 1000)

  expect(result).toEqual(DEFAULT_RESULT)
  const write = oneWrite(writes)
  expect(write.path).toBe(FEED_PATH)
  const report = JSON.parse(write.text) as { observedAt: number; rateLimits: unknown }
  expect(Object.keys(report).sort()).toEqual(['observedAt', 'rateLimits'])
  expect(Number.isSafeInteger(report.observedAt)).toBe(true)
  expect(report.observedAt).toBeGreaterThanOrEqual(before)
  expect(report.observedAt).toBeLessThanOrEqual(after)
  expect(report.rateLimits).toEqual([
    { kind: 'five_hour', percentUsed: 23.5, resetsAt: 123 },
    { kind: 'seven_day', percentUsed: 7 },
  ])
})

test('exports no transcript, session, context, cost, or gateway data', async ($, on) => {
  const writes: Write[] = []
  mock.env(on, { HOME })
  const privateUsage = {
    ...usage([{ kind: 'five_hour', percentUsed: 42 }]),
    sessionId: 'PRIVATE SESSION ID',
    transcript: 'PRIVATE TRANSCRIPT',
    cost: { usd: 12.34 },
  } as SessionUsage
  on('session.surfaces', () => ({ value: ['desktop'] as const }))
  on('session.usage', () => ({ value: privateUsage }))
  on('fs.stat', (_, e) => ({ value: prepared(e.path) }))
  on('fs.write', ($, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('turn.complete', () => DEFAULT_RESULT)

  await $.turn.complete({ ...TURN, answer: 'PRIVATE ANSWER' })

  const write = oneWrite(writes)
  expect(write.text).toBe(JSON.stringify({
    observedAt: JSON.parse(write.text).observedAt,
    rateLimits: [{ kind: 'five_hour', percentUsed: 42 }],
  }))
  expect(write.text.includes('PRIVATE')).toBe(false)
  expect(write.text.includes('sessionId')).toBe(false)
  expect(write.text.includes('context')).toBe(false)
  expect(write.text.includes('cost')).toBe(false)
})

test('does not write without a canonical subscription window', async ($, on) => {
  const writes: Write[] = []
  let current = usage([])
  mock.env(on, { HOME })
  on('session.surfaces', () => ({ value: ['desktop'] as const }))
  on('session.usage', () => ({ value: current }))
  on('fs.write', ($, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('turn.complete', () => DEFAULT_RESULT)

  await $.turn.complete(TURN)
  current = usage([{ kind: 'spend_limit', percentUsed: 25 }])
  await $.turn.complete(TURN)

  expect(writes).toEqual([])
})

test('rejects malformed canonical windows without clamping or partial output', async ($, on) => {
  const writes: Write[] = []
  let current = usage([]) as SessionUsage
  mock.env(on, { HOME })
  on('session.surfaces', () => ({ value: ['desktop'] as const }))
  on('session.usage', () => ({ value: current }))
  on('fs.write', ($, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('turn.complete', () => DEFAULT_RESULT)

  const malformed: unknown[] = [
    usage([{ kind: 'five_hour', percentUsed: -0.1 }]),
    usage([{ kind: 'five_hour', percentUsed: 100.1 }]),
    usage([{ kind: 'five_hour', percentUsed: Number.NaN }]),
    usage([{ kind: 'five_hour', percentUsed: Number.POSITIVE_INFINITY }]),
    usage([{ kind: 'five_hour', percentUsed: 10, resetsAt: 'not-a-date' }]),
    { context: { window: 1 }, rateLimits: [{ kind: 'five_hour', percentUsed: 10, resetsAt: 123 }] },
    { context: { window: 1 }, rateLimits: 'not-an-array' },
    usage([
      { kind: 'five_hour', percentUsed: 10 },
      { kind: 'seven_day', percentUsed: 101 },
    ]),
    usage([
      { kind: 'five_hour', percentUsed: 10 },
      { kind: 'five_hour', percentUsed: 20 },
    ]),
  ]
  for (const value of malformed) {
    current = value as SessionUsage
    const result = await $.turn.complete(TURN)
    expect(result).toEqual(DEFAULT_RESULT)
  }

  expect(writes).toEqual([])
})

test('does not write when HOME is missing, relative, or traversal-shaped', async ($, on) => {
  const writes: Write[] = []
  let home: string | undefined = HOME
  on('env.get', () => ({ value: home }))
  on('session.surfaces', () => ({ value: ['desktop'] as const }))
  on('session.usage', () => ({ value: usage([{ kind: 'five_hour', percentUsed: 10 }]) }))
  on('fs.write', ($, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('turn.complete', () => DEFAULT_RESULT)

  for (const value of [undefined, '', 'relative/home', '/Users/offline/../escape', '/Users/offline/./escape']) {
    home = value
    const result = await $.turn.complete(TURN)
    expect(result).toEqual(DEFAULT_RESULT)
  }

  expect(writes).toEqual([])
})

test('does not read usage or write for a terminal-only turn', async ($, on) => {
  const writes: Write[] = []
  let usageReads = 0
  mock.env(on, { HOME })
  on('session.surfaces', () => ({ value: ['terminal'] as const }))
  on('session.usage', () => {
    usageReads += 1
    return { value: usage([{ kind: 'five_hour', percentUsed: 10 }]) }
  })
  on('fs.write', ($, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('turn.complete', () => DEFAULT_RESULT)

  const result = await $.turn.complete(TURN)

  expect(result).toEqual(DEFAULT_RESULT)
  expect(usageReads).toBe(0)
  expect(writes).toEqual([])
})

test('preserves the default result when the usage source fails', async ($, on) => {
  const writes: Write[] = []
  mock.env(on, { HOME })
  on('session.surfaces', () => ({ value: ['desktop'] as const }))
  on('session.usage', () => ({ deny: 'synthetic usage failure' }))
  on('fs.write', ($, e) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('turn.complete', () => DEFAULT_RESULT)

  const result = await $.turn.complete(TURN)

  expect(result).toEqual(DEFAULT_RESULT)
  expect(writes).toEqual([])
})

test('preserves the default result when the feed write fails', async ($, on) => {
  mock.env(on, { HOME })
  on('session.surfaces', () => ({ value: ['desktop'] as const }))
  on('session.usage', () => ({ value: usage([{ kind: 'five_hour', percentUsed: 10 }]) }))
  on('fs.stat', (_, e) => ({ value: prepared(e.path) }))
  on('fs.write', () => ({ deny: 'synthetic write failure' }))
  on('turn.complete', () => DEFAULT_RESULT)

  const result = await $.turn.complete(TURN)

  expect(result).toEqual(DEFAULT_RESULT)
})

test('does not create an unprepared feed or follow a linked feed', async ($, on) => {
  mock.env(on, { HOME })
  on('session.surfaces', () => ({ value: ['desktop'] as const }))
  on('session.usage', () => ({ value: usage([{ kind: 'five_hour', percentUsed: 10 }]) }))
  let linked = true
  on('fs.stat', (_, e) => e.path !== FEED_PATH ? { value: prepared(e.path) }
    : linked ? { value: { ...prepared(e.path), isLink: true } } : { deny: 'missing file' })
  let writes = 0
  on('fs.write', () => { writes++; return { value: undefined } })
  on('turn.complete', () => DEFAULT_RESULT)
  expect(await $.turn.complete(TURN)).toEqual(DEFAULT_RESULT)
  linked = false
  expect(await $.turn.complete(TURN)).toEqual(DEFAULT_RESULT)
  expect(writes).toBe(0)
})
