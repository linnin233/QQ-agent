// 提示词组装的单元自测：验证"零历史"成本模型的关键性质。
import assert from 'node:assert';
import { ChatStore } from '../src/store.js';
import { MemoryStore } from '../src/memory.js';
import { buildSystemPrompt, buildUserPrompt, buildPastState, resolveContextTier } from '../src/prompt.js';
import { setRuntimeConfig, DEFAULT_CONFIG } from '../src/config.js';

// 注入测试配置
const cfg = structuredClone(DEFAULT_CONFIG);
cfg.persona.botName = '测试机';
cfg.persona.roleText = '你是测试群里的测试机。';
cfg.persona.participation = 'medium';
// 读多少条历史由"档位 + 触发原因"决定；旧的 pastStateLimit / pastStateMaxChars 已废弃
cfg.store.contextTier = 4;
cfg.store.atCount = 20;
cfg.store.keywordCount = 15;
cfg.store.randomCount = 8;
cfg.store.allCount = 80;
cfg.sticker.enabled = true;
setRuntimeConfig(cfg);

function makeStore() {
  const store = new ChatStore(0);
  // 造 100 条历史
  for (let i = 1; i <= 100; i++) {
    store.appendIncoming('group:123', {
      mid: 1000 + i,
      ts: Date.now() - (101 - i) * 60000,
      senderId: `u${i % 5}`,
      senderName: `群友${i % 5}`,
      text: i % 2 === 0 ? `这是第${i}条消息，比较长一点为了占用预算一点为了占用预算` : `消息${i}`,
      reply: i % 7 === 0 ? { sender: '某人', text: '引用内容' } : null
    });
  }
  store.appendSelf('group:123', { text: '我自己的一句话', ts: Date.now() - 30000 });
  // 历史消息视为已读
  store.drainUnread('group:123');
  // 3 条未读（触发批）
  for (let i = 1; i <= 3; i++) {
    store.appendIncoming('group:123', {
      mid: 2000 + i,
      ts: Date.now() - (4 - i) * 1000,
      senderId: `u${i}`,
      senderName: `群友${i}`,
      text: `未读消息${i}`
    });
  }
  return store;
}

// ── 1. 系统提示包含全部行为模块，且不包含已移除的沉睡/唤醒机制 ──
const sys = buildSystemPrompt();
for (const keyword of ['安全规则', '工作方式', '反 AI 味', '保持主体性', '该说/不该说', '群聊不是客服队列', '像真人一样', '引用与点名', '记忆', '表情包策略', '发送与汇报禁令']) {
  assert.ok(sys.includes(keyword), `系统提示缺少模块：${keyword}`);
}
for (const banned of ['沉睡前观察', 'qq_wait_for_messages', 'qq_set_wake_config', 'qq_mark_read', '[SILENT]', '会话令牌']) {
  assert.ok(!sys.includes(banned), `系统提示不应包含已废弃概念：${banned}`);
}

// ── 2. 用户提示：包含理想清单的全部段落，顺序正确 ──
const store = makeStore();
const memory = new MemoryStore();
memory.append('group:123', 'memberImpression', '喜欢猫', { userId: 'u1', target: '群友1' });

const unreadBefore = store.unreadCount('group:123');
assert.strictEqual(unreadBefore, 3, '应有 3 条未读');

const triggerEntries = store.drainUnread('group:123');
assert.strictEqual(triggerEntries.length, 3, '触发批应是 3 条未读');
assert.strictEqual(store.unreadCount('group:123'), 0, 'drain 后无未读');

const session = {};
const userPrompt = buildUserPrompt({
  chatKey: 'group:123',
  kind: 'group',
  chatId: '123',
  chatName: '测试群',
  triggerEntries,
  store,
  memory,
  stickerEntries: [{ id: 's1', desc: '滑稽', useCount: 3 }],
  selfNickname: '测试机',
  selfLastMessageAt: Date.now() - 30000,
  lastMessageAt: Date.now(),
  recentCount: 42,
  runSeq: 7,
  moreUnreadDuringRun: false,
  proactive: false,
  session
});
// 带进提示词的已读条数要回写到 session，get_recent_messages 靠它做翻页补偿
assert.ok(session.pastStateCount > 0, 'session.pastStateCount 应被写入');

// 段落清单与 prompt.js 顶部注释保持一致：
// 【当前时间】【角色设定】【此刻状态】【过去状态】【本次唤醒】【记忆】【可用表情包】【引导说明】
// （【会话标识】已并入【此刻状态】，【参与度参考】已并入系统提示的【该说/不该说】）
let cursor = -1;
for (const section of ['【当前时间】', '【角色设定', '【此刻状态】', '【过去状态】', '【本次唤醒】', '【记忆】', '【可用表情包】', '【引导说明】']) {
  const at = userPrompt.indexOf(section);
  assert.ok(at >= 0, `用户提示缺少段落：${section}`);
  assert.ok(at > cursor, `用户提示段落顺序不对：${section}`);
  cursor = at;
}
for (const banned of ['沉睡前观察', 'qq_', '[SILENT]']) {
  assert.ok(!userPrompt.includes(banned), `用户提示不应包含：${banned}`);
}

// ── 3. 触发批不出现在"过去状态"里（避免重复） ──
const past = buildPastState(store, 'group:123', { excludeIds: triggerEntries.map((m) => m.id) });
assert.ok(!past.text.includes('未读消息1'), '过去状态不应包含触发批消息');
assert.ok(past.text.includes('第100条消息'), '过去状态应包含历史消息');
assert.ok(past.text.includes('我自己的一句话'), '过去状态应包含自己的发言');

// ── 4. 上下文条数控制：limit 决定带多少条已读历史（旧的字数预算已废弃） ──
const full = buildPastState(store, 'group:123', { limit: 200 });
const ten = buildPastState(store, 'group:123', { limit: 10 });
assert.strictEqual(ten.count, 10, 'limit=10 应只带 10 条已读历史');
assert.ok(ten.count < full.count, 'limit 应真的生效（10 条少于全量）');
assert.strictEqual(
  ten.text,
  full.text.split('\n').slice(-10).join('\n'),
  'limit=10 应正好是全量的最后 10 行'
);
// limit=0 是"失忆"的根源：调用方在决定响应之后必须避免传 0
const zero = buildPastState(store, 'group:123', { limit: 0 });
assert.strictEqual(zero.count, 0, 'limit=0 不应带任何历史');
assert.strictEqual(zero.text, '', 'limit=0 时文本应为空');

// ── 5. 零历史性质：整个用户提示里不出现"assistant 说过的话"这种 LLM 轮次结构 ──
// （用户消息是单个字符串，不含 OpenAI messages 数组的历史角色）
assert.ok(!userPrompt.includes('role'), '用户提示不应包含角色结构标记');

// ── 6. 主动机会模式 ──
const proactivePrompt = buildUserPrompt({
  chatKey: 'group:123', kind: 'group', chatId: '123', chatName: '测试群',
  triggerEntries: [], store, memory, stickerEntries: [],
  selfNickname: '测试机', selfLastMessageAt: 0, lastMessageAt: Date.now() - 3600000,
  recentCount: 0, runSeq: 8, moreUnreadDuringRun: false, proactive: true
});
assert.ok(proactivePrompt.includes('【过去状态】'), '主动模式也带过去状态');

// ── 7. 默认人设 = 原版小鲸鱼角色卡（已适配新架构，不含旧机制指令） ──
assert.ok(DEFAULT_CONFIG.persona.roleText.includes('DeepSeek 小鲸鱼'), '默认人设为原版小鲸鱼角色卡');
for (const banned of ['[SILENT]', 'mcp__snowluma', 'qq_set_wake_config', 'qq_mark_read', 'qq_wait_for_messages', 'qq_send_message', '空格分隔（例如']) {
  assert.ok(!DEFAULT_CONFIG.persona.roleText.includes(banned), `默认人设不应包含旧架构指令：${banned}`);
}

// ── 8. 档位与读入条数：锁死"判定要响应 ⇒ 一定带正数条历史"这个不变量 ──
// 回归防护。orchestrator.wake() 曾经在闸门判定之后又调了一次 resolveContextTier，
// 3 档的随机触发因此被掷了两次骰子：第二次没掷中就得到 tier=0 / count=0，
// contextLimit 跟着变 0，提示词里【过去状态】退化成"暂无历史记录，这是你第一次
// 参与这个会话" —— 模型每次运行都失忆（线上实测 15 次运行里 4 次踩中）。
// 这里把不变量钉住：只要判定为"要响应"，对应档位的条数就必须是正数。
const atMsg = { id: 'm1', ts: Date.now(), senderId: 'u1', senderName: '群友1', self: false, text: '@测试机 在吗' };
const plainMsg = { id: 'm2', ts: Date.now(), senderId: 'u2', senderName: '群友2', self: false, text: '今天天气不错' };
const tierCfg = { ...cfg.store, atCount: 20, keywordCount: 15, randomCount: 8, allCount: 80, keywords: [] };

for (const contextTier of [1, 2, 3, 4]) {
  for (const roll of [0, 1, 50, 99]) {
    for (const triggerEntries of [[atMsg], [plainMsg]]) {
      const r = resolveContextTier({
        triggerEntries, selfNickname: '测试机', botName: '测试机', selfId: '10000',
        cfg: { ...tierCfg, contextTier }, roll
      });
      if (r.shouldRespond) {
        assert.ok(r.count > 0, `tier=${contextTier} roll=${roll} 判定要响应却带了 0 条历史（会导致失忆）`);
      }
    }
  }
}

// 1~3 档下被艾特是最明确的召唤：无论骰子如何，都必须用 atCount 条并记为 1 档
// （4 档是"读满"档，在 atMe 判定之前就无条件返回，按设计一律吃 allCount）
for (const contextTier of [1, 2, 3]) {
  for (const roll of [0, 99]) {
    const r = resolveContextTier({
      triggerEntries: [atMsg], selfNickname: '测试机', botName: '测试机', selfId: '10000',
      cfg: { ...tierCfg, contextTier }, roll
    });
    assert.strictEqual(r.tier, 1, `tier=${contextTier} 被艾特应记为 1 档`);
    assert.strictEqual(r.count, 20, `tier=${contextTier} 被艾特应带 atCount(20) 条`);
    assert.strictEqual(r.shouldRespond, true, `tier=${contextTier} 被艾特必须响应`);
  }
}

// 4 档：无条件响应并读满 allCount（被艾特也不例外，4 档的语义就是"全读"）
const tier4 = resolveContextTier({
  triggerEntries: [atMsg], selfNickname: '测试机', botName: '测试机', selfId: '10000',
  cfg: { ...tierCfg, contextTier: 4 }, roll: 99
});
assert.strictEqual(tier4.tier, 4, '4 档应记为 4 档（全部响应）');
assert.strictEqual(tier4.count, 80, '4 档应带 allCount(80) 条');
assert.strictEqual(tier4.shouldRespond, true, '4 档必须响应');

// 各档条数互相独立：3 档下被艾特带的仍是 atCount，不是 randomCount
const independent = resolveContextTier({
  triggerEntries: [atMsg], selfNickname: '测试机', botName: '测试机', selfId: '10000',
  cfg: { ...tierCfg, contextTier: 3, atCount: 60, randomCount: 40 }, roll: 0
});
assert.strictEqual(independent.count, 60, '3 档下被艾特应带 atCount(60) 条，而不是 randomCount');

// 关键词表为空时，2 档不能凭关键词触发（避免"空表命中"）
const emptyKw = resolveContextTier({
  triggerEntries: [plainMsg], selfNickname: '测试机', botName: '测试机', selfId: '10000',
  cfg: { ...tierCfg, contextTier: 2, keywords: [] }, roll: 0
});
assert.strictEqual(emptyKw.shouldRespond, false, '关键词表为空时 2 档不应响应');

console.log('✓ 提示词自测全部通过');
