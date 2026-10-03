/// 第 6 轮核心逻辑验证 T01（纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_core && dart run tool/verify_round6.dart`
///
/// 覆盖（任务 #32 · T01 完成标准）：
/// 1. **分词口径唯一性**：[ExpertiseTokenizer] 与 `AutoStrategy.tokenize` **逐字相同**；
/// 2. **MemberRelevanceScorer**：score / rank（同分按 sortOrder）/ relevantAbove（阈值）；
/// 3. **GroupDirectiveResolver**：真实句式解析（"让组长一个人发言"/"组长来主持"/
///    "大家各自说说"/"@某专家"/"请某专家来回答"）+ 未命中回落 null + 无组长时回落 null；
/// 4. **GroupPromptComposer**：roleBlock（组长/组员 + 组长名）/ consensusBlock（公告**逐字**
///    进入）/ scopeBlock / nonParticipationRule（含 `kNonParticipationToken`）/ block 聚合；
/// 5. **LeaderLedStrategy（B3 验收断言 1–6）**：
///    ① 问 A 专业的事 → A 入选、B 不入选；② 不相关且未 @ → 不入选；③ 组长正文 @B → B 必选；
///    ④ 用户消息 @B → B 必选；⑤ 相关性全员不命中 → 仅组长；⑥ 命中 5 人 + 上限 3 → 恰 3 人；
/// 6. **ContextManager.build**：`groupBlocks` 注入（顺序正确）+ 默认空 → 旧行为零变化。
///
/// ⚠️ 静默契约（断言 7：`【不参与】` → step skipped + 消息 cancelled + UI 无气泡）属
///    `runGroupChat` 编排层行为，落 **T02** 验证（本文件只验常量与提示词含该 token）。
library;

import 'dart:io';

import 'package:advisor_core/advisor_core.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（与 verify_round4 同款）
// ---------------------------------------------------------------------------

int _passed = 0;
int _failed = 0;
final List<String> _failures = [];
String _current = '';

void section(String name) {
  _current = name;
  stdout.writeln('\n── $name ─────────────────────────────');
}

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failed++;
    final msg = '[$_current] $name${detail == null ? '' : '  → $detail'}';
    _failures.add(msg);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void checkEq(String name, Object? actual, Object? expected) {
  check(name, actual == expected, 'actual=$actual expected=$expected');
}

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

Message _userMsg(String content) => Message(
      id: 'u1',
      conversationId: 'c1',
      senderType: MessageSenderType.user,
      content: content,
      createdAt: 1,
      updatedAt: 1,
    );

/// 丰富夹具：组长 L（综合管理）+ 投标专家 A（投标/报价/资格条件）+ 医生 B（医学/诊疗）。
final List<GroupMember> _richMembers = [
  const GroupMember(expertId: 'L', name: '组长', role: MemberRole.leader, sortOrder: 0, expertise: ['综合管理']),
  const GroupMember(expertId: 'A', name: '投标专家', sortOrder: 1, expertise: ['投标', '报价', '资格条件']),
  const GroupMember(expertId: 'B', name: '医生', sortOrder: 2, expertise: ['医学', '诊疗']),
];

GroupContext _ctx(
  String userText, {
  List<GroupMember> members = const [],
  List<ExpertOutput> previousSpeakerOutputs = const [],
  String? lastSpeakerId,
}) =>
    GroupContext(
      conversationId: 'c1',
      userMessage: _userMsg(userText),
      members: members,
      previousSpeakerOutputs: previousSpeakerOutputs,
      lastSpeakerId: lastSpeakerId,
    );

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 第 6 轮核心验证 T01（advisor_core / 相关性 + 指令解析 + 组长主持 + 提示词组装）');
  stdout.writeln('=' * 64);

  _verifyTokenizerParity();
  _verifyRelevanceScorer();
  _verifyDirectiveResolver();
  _verifyPromptComposer();
  await _verifyLeaderLed();
  _verifyContextManager();

  stdout.writeln('\n${'=' * 64}');
  stdout.writeln('结果：通过 $_passed ／ 失败 $_failed');
  if (_failures.isNotEmpty) {
    stdout.writeln('\n失败明细：');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
    exitCode = 1;
  } else {
    stdout.writeln('全部通过 ✅');
  }
}

// ---------------------------------------------------------------------------
// 1. 分词口径唯一性
// ---------------------------------------------------------------------------

void _verifyTokenizerParity() {
  section('分词口径唯一性（ExpertiseTokenizer ≡ AutoStrategy.tokenize）');

  const samples = ['招标文件', '消防车额定流量', 'ABC-123 报价', '组长', ''];
  for (final s in samples) {
    check('口径一致：「$s」',
        ExpertiseTokenizer.tokenize(s).join('|') == AutoStrategy.tokenize(s).join('|'),
        'expertise=${ExpertiseTokenizer.tokenize(s)} auto=${AutoStrategy.tokenize(s)}');
  }
  final t = ExpertiseTokenizer.tokenize('招标文件');
  check('中文逐字 + 2-gram', t.contains('招') && t.contains('招标') && t.contains('标文') && t.contains('文件'));
  check('拉丁/数字小写聚合', ExpertiseTokenizer.tokenize('ABC-123').containsAll({'abc', '123'}));
  check('空串 → 空集', ExpertiseTokenizer.tokenize('   ').isEmpty);
}

// ---------------------------------------------------------------------------
// 2. MemberRelevanceScorer
// ---------------------------------------------------------------------------

void _verifyRelevanceScorer() {
  section('MemberRelevanceScorer（score / rank / relevantAbove）');

  const a = GroupMember(expertId: 'A', name: '投标专家', sortOrder: 1, expertise: ['投标', '报价']);
  const b = GroupMember(expertId: 'B', name: '医生', sortOrder: 2, expertise: ['医学', '诊疗']);

  check('A 命中投标类标签 > 0', MemberRelevanceScorer.score('招标文件资格条件', a) > 0);
  checkEq('B 不命中 → 0', MemberRelevanceScorer.score('招标文件资格条件', b), 0.0);

  final ranked = MemberRelevanceScorer.rank('招标文件', [b, a]);
  checkEq('rank 降序（A 在前）', '${ranked[0].expertId}${ranked[1].expertId}', 'AB');

  // 同分按 sortOrder 升序
  const c = GroupMember(expertId: 'C', name: '顾问', sortOrder: 0, expertise: ['无关']);
  const d = GroupMember(expertId: 'D', name: '顾问2', sortOrder: 5, expertise: ['无关']);
  final tie = MemberRelevanceScorer.rank('完全不相关', [d, c]);
  checkEq('同分按 sortOrder 升序', '${tie[0].expertId}${tie[1].expertId}', 'CD');

  checkEq('relevantAbove 阈值过滤', MemberRelevanceScorer.relevantAbove('招标文件', [a, b]).length, 1);
  checkEq('relevantAbove 全部不相关 → 空', MemberRelevanceScorer.relevantAbove('天气', [a, b]).length, 0);

  // 总结者 0.5 折扣
  const sum = GroupMember(expertId: 'S', name: '总结者', role: MemberRole.summarizer, sortOrder: 3, expertise: ['投标']);
  const plain = GroupMember(expertId: 'P', name: '普通', sortOrder: 4, expertise: ['投标']);
  check('总结者折扣（score 更低）',
      MemberRelevanceScorer.score('投标', sum) < MemberRelevanceScorer.score('投标', plain));
}

// ---------------------------------------------------------------------------
// 3. GroupDirectiveResolver（句式解析 + 回落）
// ---------------------------------------------------------------------------

void _verifyDirectiveResolver() {
  section('GroupDirectiveResolver（真实句式解析 + 未命中回落）');

  SpeakerDirective? r(String text, {String? leaderId = 'L'}) =>
      GroupDirectiveResolver.resolve(userText: text, members: _richMembers, leaderId: leaderId);

  // ① 仅组长一人
  var d = r('让组长一个人发言');
  check('「让组长一个人发言」→ 仅组长', d != null && d.expertIds.length == 1 && d.expertIds.first == 'L',
      '${d?.expertIds}');
  check('依据含「仅组长」', d != null && d.reason.contains('仅组长'));

  d = r('组长单独说');
  check('「组长单独说」→ 仅组长', d != null && d.expertIds.first == 'L');

  // ② 组长发言 / 主持
  d = r('组长来主持一下');
  check('「组长来主持」→ 仅组长', d != null && d.expertIds.first == 'L');
  d = r('请组长发言');
  check('「请组长发言」→ 仅组长', d != null && d.expertIds.first == 'L');

  // ③ 全体
  d = r('大家各自说说');
  check('「大家各自说说」→ 全体', d != null && d.isFullGroup && d.expertIds.length == _richMembers.length);
  d = r('各位都谈谈看法');
  check('「各位都谈谈」→ 全体', d != null && d.isFullGroup);

  // ④ 点名 @
  d = r('@投标专家 说说你的看法');
  check('「@投标专家」→ A 必选', d != null && d.expertIds.contains('A'));
  check('点名依据含专家名', d != null && d.reason.contains('投标专家'));

  // ④ 点名 名 + 动词
  d = r('请投标专家来回答');
  check('「请投标专家来回答」→ A', d != null && d.expertIds.contains('A'));

  // ④ 多个 @
  d = r('@投标专家 @医生 都说说');
  check('多个 @ 都入选', d != null && ['A', 'B'].every(d.expertIds.contains) && d.expertIds.length == 2);

  // ⑤ 未命中 → null
  checkEq('普通闲聊 → null（回落持久策略）', r('今天天气不错'), null);
  checkEq('空串 → null', r('   '), null);

  // 无组长时「仅组长」无法执行 → 回落 null（成员名单里没有组长、也没有名为「组长」的成员）。
  checkEq(
      '无组长 + 「仅组长」→ null（避免冷场）',
      GroupDirectiveResolver.resolve(
          userText: '让组长一个人发言',
          members: [_richMembers[1], _richMembers[2]],
          leaderId: null),
      null);
}

// ---------------------------------------------------------------------------
// 4. GroupPromptComposer
// ---------------------------------------------------------------------------

void _verifyPromptComposer() {
  section('GroupPromptComposer（角色声明 / 公告逐字 / 发言范围 / 自判纪律）');

  final leaderBlock = GroupPromptComposer.roleBlock(selfName: '张三', role: MemberRole.leader);
  check('组长角色块含自称与「组长」', leaderBlock.contains('张三') && leaderBlock.contains('组长'));

  final memberBlock = GroupPromptComposer.roleBlock(
      selfName: '李四', role: MemberRole.member, leaderName: '张三');
  check('组员角色块含自称 + 组长名', memberBlock.contains('李四') && memberBlock.contains('张三'));

  final memberNoLeader = GroupPromptComposer.roleBlock(selfName: '李四', role: MemberRole.member);
  check('无组长时组员块提示「暂无组长」', memberNoLeader.contains('暂无组长'));

  const announcement = '本群只为政府招投标项目提供建议，不参与私人事务。';
  final cb = GroupPromptComposer.consensusBlock(announcement);
  check('公告块**逐字**含公告文本（硬契约）', cb.contains(announcement));
  checkEq('空公告 → 空串', GroupPromptComposer.consensusBlock(null), '');
  checkEq('空白公告 → 空串', GroupPromptComposer.consensusBlock('   '), '');

  final scopeFull = GroupPromptComposer.scopeBlock(
      SpeakerDirective(expertIds: const ['A', 'B'], reason: '全体', isFullGroup: true), const ['投标专家', '医生']);
  check('范围块（全体）含成员名', scopeFull.contains('投标专家') && scopeFull.contains('医生'));
  final scopeOne = GroupPromptComposer.scopeBlock(
      SpeakerDirective(expertIds: const ['L'], reason: '仅组长'), const ['组长']);
  check('范围块（限定）含「仅由」+ 成员名', scopeOne.contains('仅') && scopeOne.contains('组长'));
  final scopeNone = GroupPromptComposer.scopeBlock(null, const []);
  check('范围块（null）说明按策略自动选择', scopeNone.contains('策略'));

  check('自判纪律含静默哨兵 token', GroupPromptComposer.nonParticipationRule.contains(kNonParticipationToken));
  check('表达纪律存在', GroupPromptComposer.concisionRule.isNotEmpty);

  final block = GroupPromptComposer.block(
    selfName: '投标专家',
    role: MemberRole.member,
    leaderName: '组长',
    announcement: announcement,
    directive: SpeakerDirective(expertIds: const ['A'], reason: '点名'),
    speakerNames: const ['投标专家'],
  );
  check('聚合块含角色声明', block.contains('投标专家'));
  check('聚合块含公告', block.contains(announcement));
  check('聚合块含发言范围', block.contains('本轮发言范围'));
  check('聚合块含自判哨兵', block.contains(kNonParticipationToken));

  // 短回执
  check('「收到」识别为短回执', ShortAckDetector.isShortAck('收到'));
  check('「明白」识别为短回执', ShortAckDetector.isShortAck('明白'));
  check('长文本不识别为短回执', !ShortAckDetector.isShortAck('收到，我这就详细说明投标策略的全部要点与风险'));
}

// ---------------------------------------------------------------------------
// 5. LeaderLedStrategy（B3 验收断言 1–6）
// ---------------------------------------------------------------------------

Future<void> _verifyLeaderLed() async {
  section('LeaderLedStrategy（B3 断言 1–6：相关性入选 / @ 必选 / 兜底 / 上限）');

  Future<List<String>> run(
    String text, {
    int maxSpeakers = 3,
    List<GroupMember>? members,
    List<ExpertOutput> prev = const [],
  }) async {
    final plan = await LeaderLedStrategy(maxSpeakers: maxSpeakers).selectNextSpeakers(
      _ctx(text, members: members ?? _richMembers, previousSpeakerOutputs: prev),
    );
    return plan.primarySpeakers;
  }

  // 断言 ①：问 A 专业的事（A 标签命中、B 不命中）→ A 入选、B 不入选。
  var picked = await run('帮我看看招标文件的资格条件怎么响应');
  check('断言① A 入选', picked.contains('A'), 'got=$picked');
  check('断言① B 不入选', !picked.contains('B'), 'got=$picked');
  check('断言① 组长先行（首位为 L）', picked.isNotEmpty && picked.first == 'L', 'got=$picked');

  // 断言 ②：相关性不命中且未被任何 @ → 不入选（B 就在此列）。
  check('断言② 不相关成员 B 不入选', !picked.contains('B'));

  // 断言 ③：组长正文 @B → B 必选（无论相关性）。
  picked = await run('随便聊两句', prev: const [
    ExpertOutput(expertId: 'L', expertName: '组长', content: '这次请 @医生 来回答'),
  ]);
  check('断言③ 组长@提名 → B 必选', picked.contains('B'), 'got=$picked');

  // 断言 ④：用户消息 @B → B 必选。
  picked = await run('@医生 帮我看下');
  check('断言④ 用户@B → B 必选', picked.contains('B'), 'got=$picked');

  // 断言 ⑤：相关性全员不命中 → 仅组长（不冷场、不全员）。
  picked = await run('今天天气怎么样');
  check('断言⑤ 全不命中 → 恰仅组长', picked.length == 1 && picked.first == 'L', 'got=$picked');

  // 断言 ⑥：命中 5 人 + 上限 3 → 恰 3 人（Top-3 相关度）。
  final five = <GroupMember>[
    const GroupMember(expertId: 'M1', name: '投标A', sortOrder: 0, expertise: ['投标']),
    const GroupMember(expertId: 'M2', name: '报价B', sortOrder: 1, expertise: ['报价']),
    const GroupMember(expertId: 'M3', name: '法律C', sortOrder: 2, expertise: ['法律']),
    const GroupMember(expertId: 'M4', name: '医学D', sortOrder: 3, expertise: ['医学']),
    const GroupMember(expertId: 'M5', name: '财务E', sortOrder: 4, expertise: ['财务']),
  ];
  picked = await run('投标 报价 法律 医学 财务', members: five, maxSpeakers: 3);
  check('断言⑥ 恰 3 人', picked.length == 3, 'got=$picked');
  check('断言⑥ 命中的成员入选（子集）', picked.every((e) => ['M1', 'M2', 'M3', 'M4', 'M5'].contains(e)), 'got=$picked');

  // 断言 ⑥ 变体：含组长 + 4 命中 → 仍恰 3（含组长）。
  final withLeader = <GroupMember>[
    const GroupMember(expertId: 'L', name: '组长', role: MemberRole.leader, sortOrder: 0, expertise: ['无关']),
    const GroupMember(expertId: 'M1', name: '投标A', sortOrder: 1, expertise: ['投标']),
    const GroupMember(expertId: 'M2', name: '报价B', sortOrder: 2, expertise: ['报价']),
    const GroupMember(expertId: 'M3', name: '法律C', sortOrder: 3, expertise: ['法律']),
    const GroupMember(expertId: 'M4', name: '医学D', sortOrder: 4, expertise: ['医学']),
  ];
  picked = await run('投标 报价 法律 医学', members: withLeader, maxSpeakers: 3);
  check('断言⑥变体 含组长时仍恰 3', picked.length == 3, 'got=$picked');
  check('断言⑥变体 组长在列', picked.contains('L'), 'got=$picked');

  // 强制入选不被上限丢弃（用户 @ 两位 + 上限 2）。
  picked = await run('@投标专家 @医生 都来', maxSpeakers: 2);
  check('强制入选按上限保留（@A @B + cap2）', ['A', 'B'].every(picked.contains) && picked.length == 2, 'got=$picked');

  // 空成员 → none
  final emptyPlan = await LeaderLedStrategy().selectNextSpeakers(_ctx('你好'));
  check('无成员 → 计划为空', emptyPlan.isEmpty);

  // 策略已注册
  SpeakingStrategies.registerBuiltins();
  final led = SpeakingStrategies.byId('leader_led');
  check('leader_led 已注册', led != null);
  checkEq('leader_led label', led?.label, '组长主持（推荐）');
  check('四种既有策略仍在', ['manual', 'round_robin', 'weighted', 'auto'].every((id) => SpeakingStrategies.byId(id) != null));
}

// ---------------------------------------------------------------------------
// 6. ContextManager.build（groupBlocks 注入 + 默认行为不变）
// ---------------------------------------------------------------------------

void _verifyContextManager() {
  section('ContextManager.build（群级块注入顺序 + 默认空零变化）');

  // 默认（单聊 / 旧调用）：groupBlocks 省略 → system == 风格 + 提示词。
  final base = ContextManager.build(systemPrompt: '你是专家', styleDirective: '简洁', userTask: '问题');
  final sys0 = base.firstWhere((m) => m.role == ChatRole.system).content;
  check('默认：system 含风格 + 提示词', sys0.contains('简洁') && sys0.contains('你是专家'));
  check('默认：system 不含群级块', !sys0.contains('【群角色】'));

  // 注入群级块：顺序 风格 → 提示词 → 群块。
  final withGroup = ContextManager.build(
    systemPrompt: '你是专家',
    styleDirective: '简洁',
    groupBlocks: '【群角色】你是本群组长',
    userTask: '问题',
  );
  final sys1 = withGroup.firstWhere((m) => m.role == ChatRole.system).content;
  check('注入：system 含群角色块', sys1.contains('【群角色】'));
  final iStyle = sys1.indexOf('简洁');
  final iPrompt = sys1.indexOf('你是专家');
  final iGroup = sys1.indexOf('【群角色】');
  check('顺序正确：风格 < 提示词 < 群块', iStyle < iPrompt && iPrompt < iGroup,
      'style=$iStyle prompt=$iPrompt group=$iGroup');

  // 硬契约：公告（经 consensusBlock）逐字进入 system。
  const ann = '本群只讨论招投标，无关话题一律不参与。';
  final gb = GroupPromptComposer.block(
    selfName: '投标专家',
    role: MemberRole.member,
    leaderName: '组长',
    announcement: ann,
    directive: SpeakerDirective(expertIds: const ['A'], reason: '点名'),
    speakerNames: const ['投标专家'],
  );
  final withAnn = ContextManager.build(systemPrompt: '你是专家', groupBlocks: gb, userTask: '问题');
  final sys2 = withAnn.firstWhere((m) => m.role == ChatRole.system).content;
  check('硬契约：公告文本逐字进入 system', sys2.contains(ann));
  check('硬契约：自判哨兵进入 system', sys2.contains(kNonParticipationToken));

  // strict 规则排在群块之后。
  final withStrict = ContextManager.build(
      systemPrompt: '你是专家', groupBlocks: '【群角色】组长', userTask: '问题', strictGrounding: true);
  final sys3 = withStrict.firstWhere((m) => m.role == ChatRole.system).content;
  check('strict 规则在群块之后', sys3.indexOf('【群角色】') < sys3.indexOf(GroundingResolver.strictSystemRule));
}
