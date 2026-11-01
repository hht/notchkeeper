// Notchkeeper 的 Claude Code mod：把最近一次结束的主回合写成一份小 JSON，给刘海 App 读。
// 只报事实（turnId、reason、最后一步的 stopReason、结束时还在跑的后台 agent 数、结束时刻），结局怎么算归 App 的 AgentCore；
// 只写元数据：提示词、回答、工具参数一概不写。
// 规则和文件格式见 docs/agent-integration.md「Notchkeeper mod」。
// @see https://code.claude.com/docs/en/plugins/mods/events （turn.start / turn.step / turn.complete / agent.spawn）

/** 只在有人在跟前的会话里写：`claude -p`、SDK 不写（session.start 的 isInteractive；mod 重新加载时也会再触发） */
let interactive = false
/** 正在跑的主回合：{ id, lastStop } */
let running = null
/** 还在跑的后台 agent 的 agentId */
const background = new Set()
/** 上一次写盘：写盘排成一队，后发的不会被先发的盖掉 */
let lastWrite = Promise.resolve()

/** 写下刚结束的主回合。sessionId 写盘时再取（`/clear` 之后换了） */
async function save($, ended) {
  if (!interactive) return
  const previous = lastWrite
  let finish
  lastWrite = new Promise((resolve) => { finish = resolve })
  await previous
  try {
    const sessionId = await $.session.id()
    const home = await $.env.get('HOME')
    // 整份覆盖写，不是原子写：App 读到写了一半的按解不开处理，等下一次写
    await $.fs.write(home + '/Library/Application Support/Notchkeeper/turns/' + sessionId + '.json',
      JSON.stringify({ sessionId, ended }))
  } catch (error) {
    // 写不了（磁盘满、权限）只记调试日志：这个会话不弹完成卡，Claude Code 照常跑
    $.ui.log('写回合文件失败：' + error, { to: 'debug' })
  } finally {
    finish()
  }
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    interactive = e.isInteractive
    return next(e)
  })

  // `/clear`、resume 之后会话换了 id，不再触发 session.start
  on('session.end', async ($, e, next) => {
    running = null
    background.clear()
    return next(e)
  })

  // 只在主回合触发（实测）
  on('turn.start', async ($, e, next) => {
    running = { id: e.turnId, lastStop: null }
    return next(e)
  })

  // 记主 agent 最后一步停在哪：停在 tool_use 说明工具结果之后没再请求模型（批准框里被拒）。
  // 子 agent 的步骤带的是它自己那次运行的 turnId，对不上主回合
  on('turn.step', async function* ($, e, next) {
    const result = yield* next(e)
    if (running && running.id === e.turnId) running.lastStop = result.stopReason ?? null
    return result
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId !== undefined) {
      // 子 agent 的回合（含被 TaskStop 停掉的，实测）：只关心后台的那些什么时候完成
      background.delete(e.agentId)
    } else if (running && running.id === e.turnId) {
      const ended = { turnId: e.turnId, reason: e.reason, lastStop: running.lastStop, backgroundAgents: background.size,
                      at: await $.clock.now() }
      running = null
      await save($, ended)
    }
    return next(e)
  })

  on('agent.spawn', async ($, e, next) => {
    const result = await next(e)
    if (e.background && result.agentId !== undefined) background.add(result.agentId)
    return result
  })
}
