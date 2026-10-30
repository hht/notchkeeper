import { expect, mock, test } from 'claude-code/testing'

const FILE = '/Users/u/Library/Application Support/Notchkeeper/turns/s1.json'

/** 给 mod 用到的调用打桩，返回它写过的每一份回合文件（解析成对象） */
function stubs(on) {
  const writes = []
  const clock = mock.clock(on, { now: 1000 })
  on('session.id', () => ({ value: 's1' }))
  on('env.get', () => ({ value: '/Users/u' }))
  on('fs.write', ($, e) => {
    expect(e.path).toBe(FILE)
    writes.push(JSON.parse(e.text))
    return { value: undefined }
  })
  on('session.start', () => ({ cwd: '/work' }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('agent.spawn', ($, e) => ({ model: 'haiku', agentId: e.tool_use_id }))
  on('turn.step', async function* ($, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: e.model, usage: null }
  })
  return { writes, clock }
}

/** 走一步请求；测试借 model 字段指定这一步停在哪 */
async function step($, turnId, stopReason, agentId) {
  const stream = $.turn.step({ turnId, index: 0, model: stopReason, messageCount: 1, ...(agentId ? { agentId } : {}) })
  let s = await stream.next()
  while (s.done !== true) s = await stream.next()
}

async function start($, interactive = true) {
  await $.session.start({ surface: interactive ? 'terminal' : null, isInteractive: interactive, cwd: '/work' })
}

function complete($, turnId, reason, extra = {}) {
  return $.turn.complete({ turnId, answer: '', durationMs: 1, isAborted: reason === 'aborted', reason, usage: null, ...extra })
}

function spawn($, id, background) {
  return $.agent.spawn({ tool_use_id: id, prompt: '', description: '', subagentType: 'general-purpose', background })
}

test('主回合正常答完：写 reason、最后一步的 stopReason、结束时刻', async ($, on) => {
  const { writes, clock } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await step($, 't1', 'tool_use')
  await step($, 't1', 'end_turn')
  await clock.advance(500)
  await complete($, 't1', 'answer')
  expect(writes).toEqual([{ sessionId: 's1', ended: { turnId: 't1', reason: 'answer', lastStop: 'end_turn', backgroundAgents: 0, at: 1500 } }])
})

test('批准框里被拒：最后一步停在 tool_use', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await step($, 't1', 'tool_use')
  await complete($, 't1', 'answer')
  expect(writes.at(-1).ended.lastStop).toBe('tool_use')
})

test('出错：照写 reason，一步都没走完时 lastStop 是 null', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await complete($, 't1', 'error')
  expect(writes.at(-1).ended).toMatchObject({ reason: 'error', lastStop: null })
})

test('子 agent 的步骤不算主 agent 的最后一步', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await step($, 't1', 'end_turn')
  await step($, 'sub', 'tool_use', 'a1')
  await complete($, 't1', 'answer')
  expect(writes.at(-1).ended.lastStop).toBe('end_turn')
})

test('结束时还在跑的后台 agent 照记；前台子 agent 不算；子 agent 的回合不写', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await spawn($, 'fg', false)
  await spawn($, 'bg', true)
  await complete($, 't1', 'answer')
  expect(writes.at(-1).ended.backgroundAgents).toBe(1)
  await complete($, 'x', 'answer', { agentId: 'bg' })
  expect(writes.length).toBe(1)
  // 后台 agent 完成后送进来的通知回合
  await $.turn.start({ text: '', turnId: 't2' })
  await complete($, 't2', 'answer')
  expect(writes.at(-1).ended).toMatchObject({ turnId: 't2', backgroundAgents: 0 })
})

test('下一回合开始不清掉上一回合的记录（排队的消息）', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await complete($, 't1', 'answer')
  await $.turn.start({ text: '', turnId: 't2' })
  expect(writes).toHaveLength(1)
  expect(writes[0].ended.turnId).toBe('t1')
})

test('/clear 之后：后台 agent 和正在跑的回合都清掉', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '', turnId: 't1' })
  await spawn($, 'bg', true)
  await $.session.end({ reason: 'clear', sessionId: 's0', resume: { id: 's0' } })
  await complete($, 't1', 'answer')
  expect(writes).toEqual([])
  await $.turn.start({ text: '', turnId: 't2' })
  await complete($, 't2', 'answer')
  expect(writes.at(-1).ended.backgroundAgents).toBe(0)
})

test('非交互式会话（claude -p、SDK）不写', async ($, on) => {
  const { writes } = stubs(on)
  await start($, false)
  await $.turn.start({ text: '', turnId: 't1' })
  await complete($, 't1', 'answer')
  expect(writes).toEqual([])
})

test('不写提示词和回答', async ($, on) => {
  const { writes } = stubs(on)
  await start($)
  await $.turn.start({ text: '秘密提示词', turnId: 't1' })
  await $.turn.complete({ turnId: 't1', answer: '秘密回答', durationMs: 1, isAborted: false, reason: 'answer', usage: null })
  expect(JSON.stringify(writes)).not.toContain('秘密')
})
