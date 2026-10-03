/// QA 独立验证脚本（严过关）——任务 #49「群聊角色错位」根因修复的独立验收。
///
/// 运行：`cd advisor_core && dart run tool/qa_verify_group_identity.dart`
///
/// 背景（用户走查缺陷 → 主理人定位根因并修复）：
/// 投标决策群里重新任命组长后，**招标文件解读专家的回复以 `【<总裁助理id>】` 开头、
/// 自称"组长（我，总裁助理）"去分派任务**。DB 实测数据与角色判定完全正确
/// （唯一组长 = 总裁助理），真根因是 `ContextManager.build` 把历史专家消息渲染成
/// `【<expertId>】<content>` 塞进提示词 → 模型模仿该格式、把别人的 id/身份安到自己头上。
///
/// 本脚本对主理人的三处修复做**独立**验收（与工程师/主理人脚本互不依赖）：
///   修复 1：orchestration.dart `ContextManager.build` 新增 `nameOf`，历史标签改为展示名；
///   修复 2：group_directive.dart 新增 `noSpeakerLabelEchoRule` 并并入 `block()`；
///   修复 3：services.dart `runGroupChat` 传 `nameOf`（本脚本在 E2E 侧证其链路可达）。
///
/// 断言 A–E（编号与任务书一一对应）：
///   A 历史标签不含裸 expertId：3 条历史专家消息 + nameOf(张三/李四/王五)
///     → assistant content 不含任何 `e_` 开头的 id，且分别含各展示名标签。
///   B nameOf 缺省不回归：不传仍能构造，标签退回 id（与修复前旧调用行为等价）。
///   C `_speakerLabel` 空值兜底：nameOf 返回空/纯空白 → 标签退回 id 而非空；
///     senderId 为 null → 退回「专家」；全文绝不出现 `【】` 空标签。
///   D `block()` 必须含发言格式纪律：对实现常量 `noSpeakerLabelEchoRule` 做 contains
///     （不硬抄中文文案），且位于 concisionRule 之后。
///   E 角色块防回归：roleBlock(leader) 含「组长」；roleBlock(member, leaderName)
///     含「本群组长是「X」」。
///   F E2E 链路证明：真跑 runGroupChat 捕获 ChatRequest，证明 nameOf 接线
///     （修复 3）在真实请求里生效；并顺带排查 runSingleChat 残留（见 F2 注记）。
///
/// 纪律：只读 / 调用生产代码，不修改任何生产代码；只新建本 `qa_verify_*.dart`。
///
/// **退出码语义**：A–E + F1 + F2 **全部**须绿（共 43 例）才算任务 #49 修复验收通过。
/// 注：F2 曾以红态记录群聊范围外的残留（`runSingleChat` 未传 nameOf，裸 id 进单聊
/// 提示词）；该残留已被修复（services.dart 单聊侧补传 `nameOf`），F2 现为**真绿**的
/// 防回归断言——若日后单聊回归裸 id，F2.2/F2.3 会再次转红。
library;

import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（与 qa_verify_round6.dart 同构，口径一致便于横向比对）
// ---------------------------------------------------------------------------

class Case {
  Case(this.id, this.name, this.expected, this.actual, this.pass, [this.note]);
  final String id, name, expected, actual;
  final bool pass;
  final String? note;
}

final List<Case> _res = [];
int _pass = 0, _fail = 0;

void t(String id, String name, Object? expected, Object? actual, {String? note}) {
  final ok = expected == actual;
  if (ok) {
    _pass++;
  } else {
    _fail++;
  }
  _res.add(Case(id, name, '$expected', '$actual', ok, note));
  stdout.writeln('  ${ok ? '✓' : '✗'} [$id] $name  (期望=$expected 实际=$actual)');
}

void section(String s) => stdout.writeln('\n── $s ──────────────────────────');

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

/// 取自用户机器 DB 的真实 expertId（招标决策群 `conv_muplhf0l_1bmijfq001`）：
/// 总裁助理（组长）与另一位专家的裸 id —— 正是"被模型冒领"的那类标识。
const _leaderId = 'e_muqacf53_1hm33cz001';
const _expertId = 'e_mupjbwsf_1ucyrek001';
const _thirdId = 'e_qa003_1zzz001';

/// 构造一条专家历史消息（senderType=expert，senderId=expertId）。
///
/// ⚠️ [conversationId] 必须与 E2E 播种的会话一致——曾因硬编码 'conv_qa'
/// 导致历史消息进了不存在的会话、E2E 请求里 assistant 恒为空（假阴性，已修）。
Message _expertMsg(String id, String senderId, String content,
        {String conversationId = 'conv_qa'}) =>
    Message(
      id: id,
      conversationId: conversationId,
      senderType: MessageSenderType.expert,
      senderId: senderId,
      content: content,
      createdAt: 0,
      updatedAt: 0,
    );

/// 构造一条用户历史消息（不加任何标签是 build 的既有契约）。
Message _userMsg(String id, String content) => Message(
      id: id,
      conversationId: 'conv_qa',
      senderType: MessageSenderType.user,
      content: content,
      createdAt: 0,
      updatedAt: 0,
    );

/// 3 条历史专家消息 + 1 条用户消息，顺序固定（张三→李四→王五）。
List<Message> _history() => [
      _expertMsg('m1', _leaderId, '组长先定分工：张工评估技术标。'),
      _userMsg('m2', '继续，重点关注泵参数。'),
      _expertMsg('m3', _expertId, '我来解读招标文件的技术条款。'),
      _expertMsg('m4', _thirdId, '合同付款节点有风险。'),
    ];

/// 展示名映射（模拟 services.dart 里从 groupMembers 取 name 的 nameOf）。
String _nameOf(String id) => switch (id) {
      _leaderId => '张三',
      _expertId => '李四',
      _thirdId => '王五',
      _ => id,
    };

/// 取 build 产出里的 assistant（历史专家）消息。
List<ChatMessage> _assistantOf(List<ChatMessage> msgs) =>
    msgs.where((m) => m.role == ChatRole.assistant).toList();

Future<void> main() async {
  stdout.writeln('严过关 · 独立 QA 验证（任务 #49 群聊角色错位根因修复）');
  stdout.writeln('=' * 62);
  stdout.writeln('dart = ${Platform.version}');

  _t_A_historyLabelUsesDisplayName();
  _t_B_nameOfOmittedNoRegression();
  _t_C_speakerLabelEmptyFallback();
  _t_D_blockHasSpeakerFormatRule();
  _t_E_roleBlockNoRegression();
  await _t_F_e2ePromptPath();

  _print();
  exitCode = _fail == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// A. 历史标签不含裸 expertId（修复 1 正面）
// ---------------------------------------------------------------------------

void _t_A_historyLabelUsesDisplayName() {
  section('A 历史发言标签 = 展示名（无裸 expertId）');

  final msgs = ContextManager.build(
    systemPrompt: '你是招标文件解读专家。',
    userTask: '请重新分派本轮任务',
    recentMessages: _history(),
    nameOf: _nameOf,
  );

  final assistants = _assistantOf(msgs);
  final allContent = assistants.map((m) => m.content).join('\n');

  // A1 三条专家历史全部进入上下文（assistant 角色数 = 3，用户消息不带 assistant）
  t('A1', '3 条专家历史全部进入上下文', 3, assistants.length,
      note: 'roles=${msgs.map((m) => m.role.name).toList()}');

  // A2–A4 没有任何一条 assistant content 泄漏 `e_` 开头的裸 id（根因正是它）
  t('A2', 'assistant content 不含总裁助理裸 id', false,
      allContent.contains(_leaderId));
  t('A3', 'assistant content 不含招标专家裸 id', false,
      allContent.contains(_expertId));
  t('A4', 'assistant content 不含第三条裸 id', false, allContent.contains(_thirdId));

  // A5 各展示名标签就位（按历史顺序）
  t('A5', '依次含【张三】/【李四】/【王五】', true, assistants.length == 3
      && assistants[0].content.contains('【张三】')
      && assistants[1].content.contains('【李四】')
      && assistants[2].content.contains('【王五】'),
      note: assistants.map((m) => m.content.split('】').first).join(' | '));

  // A6 标签后紧跟原正文（精确串，防标签与正文粘连/丢失）
  t('A6', '张三标签后紧跟原正文', true,
      assistants[0].content == '【张三】组长先定分工：张工评估技术标。',
      note: assistants[0].content);

  // A7 用户历史消息不加标签、正文逐字保留（build 既有契约不回归）
  final userHist = msgs
      .where((m) => m.role == ChatRole.user)
      .map((m) => m.content)
      .toList();
  t('A7', '用户历史不加标签且逐字保留', true,
      userHist.contains('继续，重点关注泵参数。'),
      note: 'user 消息=$userHist');

  // A8 system 与任务消息干净：首条 system、末条 = 用户任务
  t('A8a', '首条为 system', ChatRole.system, msgs.first.role);
  t('A8b', '末条为本次用户任务', '请重新分派本轮任务', msgs.last.content);
  t('A8c', 'system 不含任何历史裸 id', false,
      msgs.first.content.contains(_leaderId) ||
          msgs.first.content.contains(_expertId));
}

// ---------------------------------------------------------------------------
// B. nameOf 缺省不回归（修复 1 兼容面）
// ---------------------------------------------------------------------------

void _t_B_nameOfOmittedNoRegression() {
  section('B nameOf 缺省 → 构造不崩、标签退回 id（旧调用等价）');

  // 不传 nameOf（老调用方形态，如单聊 / 未接线路径）
  final msgs = ContextManager.build(
    systemPrompt: '你是专家。',
    userTask: '问题',
    recentMessages: _history(),
  );
  final assistants = _assistantOf(msgs);

  t('B1', '不传 nameOf 仍能正常构造', 3, assistants.length);
  t('B2', '标签退回 senderId（修复前行为等价）', true, assistants.length == 3
      && assistants[0].content.startsWith('【$_leaderId】')
      && assistants[1].content.startsWith('【$_expertId】')
      && assistants[2].content.startsWith('【$_thirdId】'),
      note: assistants.map((m) => m.content.split('】').first).join(' | '));

  // nameOf = null 显式传入等价
  final explicitNull = ContextManager.build(
    systemPrompt: 'p',
    userTask: 't',
    recentMessages: _history(),
    nameOf: null,
  );
  t('B3', '显式 nameOf=null 等价缺省', true,
      _assistantOf(explicitNull)[0].content.startsWith('【$_leaderId】'));

  // 完全不传 recentMessages（最古老调用形态）也不崩
  final bare = ContextManager.build(systemPrompt: 'p', userTask: 't');
  t('B4', '无历史 + 无 nameOf → 仅 system+user 两条', 2, bare.length);
}

// ---------------------------------------------------------------------------
// C. _speakerLabel 空值兜底（修复 1 负面/边界）
// ---------------------------------------------------------------------------

void _t_C_speakerLabelEmptyFallback() {
  section('C 发言标签空值兜底（不得为空标签）');

  // C1 nameOf 返回空串 → 退回 id（而非 `【】`）
  final emptyName = _assistantOf(ContextManager.build(
    systemPrompt: 'p',
    userTask: 't',
    recentMessages: _history(),
    nameOf: (_) => '',
  ));
  t('C1', 'nameOf="" → 标签退回 id', true, emptyName.isNotEmpty
      && emptyName[0].content.startsWith('【$_leaderId】'),
      note: emptyName[0].content.split('】').first ?? '<空>');

  // C2 nameOf 返回纯空白 → trim 后仍为空 → 退回 id
  final blankName = _assistantOf(ContextManager.build(
    systemPrompt: 'p',
    userTask: 't',
    recentMessages: _history(),
    nameOf: (_) => '   \t ',
  ));
  t('C2', 'nameOf=纯空白 → 标签退回 id', true, blankName.isNotEmpty
      && blankName[0].content.startsWith('【$_leaderId】'));

  // C3 senderId 为 null（异常数据）→ 退回「专家」
  final nullSender = _assistantOf(ContextManager.build(
    systemPrompt: 'p',
    userTask: 't',
    recentMessages: [_expertMsg('mx', '', '无 id 的发言')],
    nameOf: (_) => '张三',
  ));
  // 注意：空串 senderId 与 null 同分支（id.isEmpty）→ 「专家」
  t('C3', 'senderId 为空串 → 标签为「专家」', true,
      nullSender.isNotEmpty && nullSender[0].content.startsWith('【专家】'),
      note: nullSender.isEmpty ? '<无消息>' : nullSender[0].content);

  final nullSenderMsg = Message(
    id: 'my',
    conversationId: 'conv_qa',
    senderType: MessageSenderType.expert,
    senderId: null,
    content: '裸 null 的发言',
    createdAt: 0,
    updatedAt: 0,
  );
  final nullRole = _assistantOf(ContextManager.build(
    systemPrompt: 'p',
    userTask: 't',
    recentMessages: [nullSenderMsg],
    nameOf: (_) => '张三',
  ));
  t('C3b', 'senderId=null → 标签为「专家」', true,
      nullRole.isNotEmpty && nullRole[0].content == '【专家】裸 null 的发言',
      note: nullRole.isEmpty ? '<无消息>' : nullRole[0].content);

  // C4 三种形态合计：全文绝不出现 `【】` 空标签 / `【 】` 空白标签
  final c4 = ContextManager.build(
    systemPrompt: 'p',
    userTask: 't',
    recentMessages: _history(),
    nameOf: (id) => id == _leaderId ? '' : (id == _expertId ? '  ' : '王五'),
  );
  final c4All = c4.map((m) => m.content).join('\n');
  t('C4a', '全文无 `【】` 空标签', false, c4All.contains('【】'));
  t('C4b', '全文无 `【 】` 空白标签', false, c4All.contains('【 】'));

  // C5 混合：空值退回 id + 正常展示名共存，且各自正确
  final c5 = _assistantOf(c4);
  t('C5', '混合场景：退回 id 与展示名各自正确', true, c5.length == 3
      && c5[0].content.startsWith('【$_leaderId】')
      && c5[1].content.startsWith('【$_expertId】')
      && c5[2].content.startsWith('【王五】'),
      note: c5.map((m) => m.content.split('】').first).join(' | '));
}

// ---------------------------------------------------------------------------
// D. block() 必须含发言格式纪律（修复 2）
// ---------------------------------------------------------------------------

void _t_D_blockHasSpeakerFormatRule() {
  section('D GroupPromptComposer.block 并入发言格式纪律');

  final blk = GroupPromptComposer.block(
    selfName: '招标文件解读专家',
    role: MemberRole.member,
    leaderName: '张三',
  );

  // D1 用**实现常量**做 contains（不硬抄文案，改文案不假红）
  t('D1', 'block() 含 noSpeakerLabelEchoRule（常量引用）', true,
      blk.contains(GroupPromptComposer.noSpeakerLabelEchoRule));

  // D2 并入位置：concisionRule 之后（与修复说明一致）
  t('D2', 'noSpeakerLabelEchoRule 位于 concisionRule 之后', true,
      blk.indexOf(GroupPromptComposer.noSpeakerLabelEchoRule) >
          blk.indexOf(GroupPromptComposer.concisionRule),
      note: 'concision@${blk.indexOf(GroupPromptComposer.concisionRule)} '
          'noLabel@${blk.indexOf(GroupPromptComposer.noSpeakerLabelEchoRule)}');

  // D3 常量自身的语义不变式：警告的正是 `【】` 标签格式（防文案被改成无关内容）
  t('D3', '常量含 `【】` 语义（禁【】前缀标注）', true,
      GroupPromptComposer.noSpeakerLabelEchoRule.contains('【】'));

  // D4 角色为组长时同样并入（"每位发言者都必须注入"的硬契约）
  final leaderBlk = GroupPromptComposer.block(
    selfName: '张三',
    role: MemberRole.leader,
  );
  t('D4', '组长块同样含发言格式纪律', true,
      leaderBlk.contains(GroupPromptComposer.noSpeakerLabelEchoRule));

  // D5 includeNonParticipation=false 只影响自判块，不影响发言格式纪律
  final noSilent = GroupPromptComposer.block(
    selfName: '张三',
    role: MemberRole.member,
    includeNonParticipation: false,
  );
  t('D5a', '关闭自判后仍含发言格式纪律', true,
      noSilent.contains(GroupPromptComposer.noSpeakerLabelEchoRule));
  t('D5b', '关闭自判后不含静默哨兵', false,
      noSilent.contains(kNonParticipationToken));
}

// ---------------------------------------------------------------------------
// E. 角色块防回归（第 6 轮已有契约，修复不得破坏）
// ---------------------------------------------------------------------------

void _t_E_roleBlockNoRegression() {
  section('E 角色块仍然正确（防回归）');

  final leader = GroupPromptComposer.roleBlock(
    selfName: '张三',
    role: MemberRole.leader,
  );
  t('E1', 'roleBlock(leader) 含「组长」', true, leader.contains('组长'));
  t('E2', 'roleBlock(leader) 含本人姓名（自认身份正确）', true, leader.contains('张三'));

  final member = GroupPromptComposer.roleBlock(
    selfName: '招标文件解读专家',
    role: MemberRole.member,
    leaderName: '张三',
  );
  t('E3', 'roleBlock(member, leaderName) 含「本群组长是「张三」」', true,
      member.contains('本群组长是「张三」'));
  t('E4', '组员块不含"你是本群组长"（不把组长身份安给组员）', false,
      member.contains('你是本群组长'));

  // 无组长时不虚构组长
  final noLeader = GroupPromptComposer.roleBlock(
    selfName: '王五',
    role: MemberRole.member,
  );
  t('E5', '无 leaderName → 不含虚构组长', false,
      noLeader.contains('本群组长是「'));
}

// ---------------------------------------------------------------------------
// F. E2E：真实 runGroupChat / runSingleChat 请求（修复 3 链路证明 + 残留排查）
// ---------------------------------------------------------------------------

/// **async\* 惰性护栏**：`runGroupChat` / `runSingleChat` 是 `async*`
/// （惰性 Stream），`await` 只拿到 Stream 对象，函数体根本不会执行。
/// 必须消费（forEach）才真跑编排，错误也才在此处抛出。
Future<void> _drain(Stream<dynamic> stream) => stream.forEach((_) {});

/// 公共播种：provider / model / credential / secret / 默认设置。
Future<(Repositories, int)> _seedRuntime() async {
  final repos = inMemoryRepositories();
  final now = DateTime.now().millisecondsSinceEpoch;
  await repos.providers.upsertProvider(const ProviderProfile(
      id: 'pp_qa49', providerId: 'deepseek', displayName: 'DeepSeek', baseUrl: 'https://x'));
  await repos.providers.upsertModel(ModelProfile.deepseekChat(providerProfileId: 'pp_qa49'));
  await repos.credentials.upsert(CredentialProfile(
      id: 'cr_qa49',
      providerProfileId: 'pp_qa49',
      name: 'k',
      secretRef: 'ref49',
      createdAt: now,
      updatedAt: now));
  await repos.secrets.write('ref49', 'sk-test');
  await repos.settings.set(SettingKeys.defaultModelProfileId, 'mp_deepseek_chat');
  await repos.settings.set(SettingKeys.defaultCredentialProfileId, 'cr_qa49');
  return (repos, now);
}

Future<void> _t_F_e2ePromptPath() async {
  section('F E2E：真实请求里历史标签 = 展示名（修复 3 链路证明）');

  // —— F1 群聊：runGroupChat 真跑，捕获发给模型的 ChatRequest ——
  final (repos, now) = await _seedRuntime();

  await repos.experts.upsertExpert(Expert(
      id: _leaderId,
      name: '张三',
      systemPrompt: '你是投标决策顾问。',
      source: ExpertSource.local,
      createdAt: now,
      updatedAt: now));
  await repos.experts.upsertExpert(Expert(
      id: _expertId,
      name: '李四',
      systemPrompt: '你是招标文件解读专家。',
      source: ExpertSource.local,
      createdAt: now,
      updatedAt: now));

  const convId = 'conv_qa49_group';
  await repos.conversations.upsertConversation(Conversation(
      id: convId,
      type: ConversationType.group,
      title: '投标决策群',
      createdAt: now,
      updatedAt: now));
  await repos.conversations.upsertMember(ConversationMember(
      conversationId: convId, expertId: _leaderId, role: MemberRole.leader, sortOrder: 0));
  await repos.conversations.upsertMember(
      const ConversationMember(conversationId: convId, expertId: _expertId, sortOrder: 1));
  await repos.conversations.upsertGroupConfig(
      const GroupConfig(conversationId: convId, speakStrategy: 'leader_led', maxSpeakersPerRound: 3));

  // 复刻用户 DB 现场：群里已有一条李四（裸 id senderId）的历史专家消息。
  await repos.messages.insertMessage(
      _expertMsg('m_prev', _expertId, '我来解读招标文件的技术条款。', conversationId: convId));

  final experts = ExpertService(repos);
  final conversations = ConversationService(repos);
  final knowledge = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    retriever: InMemoryRetriever(repos.knowledge),
  );
  final scripted = ScriptedLlmProvider(replies: ['结论：技术标条款总体可行。']);
  final group = GroupService(
    repos,
    experts: experts,
    conversations: conversations,
    knowledge: knowledge,
    llmFactory: (_) => scripted,
  );

  // 「请张三说说」→ 点名指令，发言人 = 张三（组长），确定性单发言者。
  await _drain(group.runGroupChat(
    conversationId: convId,
    userMessageId: 'um49',
    userText: '请张三说说技术标',
  ));

  final req = scripted.calls.isNotEmpty ? scripted.calls.first : null;
  final reqMessages = req?.messages ?? const <ChatMessage>[];
  final reqAll = reqMessages.map((m) => m.content).join('\n');
  final reqSystem = reqMessages.isNotEmpty ? reqMessages.first.content : '';

  t('F1.1', 'E2E：LLM 真被调用（请求已捕获）', true, scripted.calls.isNotEmpty,
      note: 'calls=${scripted.calls.length}');
  t('F1.2', 'E2E：请求里历史专家消息以【李四】开头（展示名）', true,
      reqMessages.any((m) =>
          m.role == ChatRole.assistant && m.content.startsWith('【李四】我来解读招标文件')),
      note: 'assistant=${reqMessages.where((m) => m.role == ChatRole.assistant).map((m) => m.content).toList()}');
  t('F1.3', 'E2E：整个请求不含裸 expertId（根因标识零出现）', false,
      reqAll.contains(_expertId) || reqAll.contains(_leaderId));
  t('F1.4', 'E2E：请求 system 含组长角色声明', true,
      reqSystem.contains('你是本群组长「张三」'));
  t('F1.5', 'E2E：请求 system 含发言格式纪律（修复 2 进真实请求）', true,
      reqSystem.contains(GroupPromptComposer.noSpeakerLabelEchoRule));

  final e2eMsgs = await repos.messages.listMessages(convId);
  final expertMsgs = e2eMsgs.where((m) => m.isFromExpert).toList();
  // 仅看**本轮新产生**的专家消息（刨掉预埋的历史 m_prev，否则把上轮发言算进本轮）。
  final newExpertMsgs = expertMsgs.where((m) => m.id != 'm_prev').toList();
  final runs = await repos.generations.listRuns(convId);
  t('F1.6', 'E2E：专家消息落库且 completed', true,
      expertMsgs.isNotEmpty && expertMsgs.any((m) => m.status == MessageStatus.completed));
  t('F1.7', 'E2E：run 状态 completed', RunStatus.completed,
      runs.isEmpty ? RunStatus.failed : runs.last.status);
  t('F1.8', 'E2E：本轮仅张三（组长）发言 1 条（点名指令生效，无他人代答）', true,
      newExpertMsgs.length == 1 && newExpertMsgs.every((m) => m.senderId == _leaderId),
      note: 'senders=${newExpertMsgs.map((m) => m.senderId).toList()}');

  // —— F2 单聊：同一根因模式（历史标签不得含裸 expertId）——原为残留缺陷，
  //    已修复（services.dart 单聊侧补传 nameOf），现作为**防回归断言**保留。 ——
  final (repos2, now2) = await _seedRuntime();
  await repos2.experts.upsertExpert(Expert(
      id: _leaderId,
      name: '张三',
      systemPrompt: '你是投标决策顾问。',
      source: ExpertSource.local,
      createdAt: now2,
      updatedAt: now2));
  const singleId = 'conv_qa49_single';
  await repos2.conversations.upsertConversation(Conversation(
      id: singleId,
      type: ConversationType.single,
      title: '与张三单聊',
      createdAt: now2,
      updatedAt: now2));
  await repos2.conversations.upsertMember(
      const ConversationMember(conversationId: singleId, expertId: _leaderId));
  await repos2.messages.insertMessage(
      _expertMsg('m_prev_s', _leaderId, '上一轮结论：付款节点需重谈。', conversationId: singleId));

  final experts2 = ExpertService(repos2);
  final conversations2 = ConversationService(repos2);
  final knowledge2 = KnowledgeService(
    repos2,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(),
    vectorStore: InMemoryVectorStore(repos2.knowledge),
    retriever: InMemoryRetriever(repos2.knowledge),
  );
  final scripted2 = ScriptedLlmProvider(replies: ['补充：建议加入违约条款。']);
  final genService = GenerationService(
    repos2,
    experts: experts2,
    conversations: conversations2,
    knowledge: knowledge2,
    llmFactory: (_) => scripted2,
  );
  await _drain(genService.runSingleChat(
    conversationId: singleId,
    userMessageId: 'um50',
    userText: '继续补充',
  ));

  final sReq = scripted2.calls.isNotEmpty ? scripted2.calls.first : null;
  final sMsgs = sReq?.messages ?? const <ChatMessage>[];
  final sAssistants =
      sMsgs.where((m) => m.role == ChatRole.assistant).map((m) => m.content).toList();
  t('F2.1', 'E2E：单聊 LLM 真被调用', true, scripted2.calls.isNotEmpty);
  // 以下两条编码修复的核心不变式（历史标签不得出现裸 expertId），**预期通过**：
  // `runSingleChat` 单聊侧此前漏传 nameOf，历史曾渲染 `【<expertId>】`；该残留已修复
  // （单聊 build 现传 `nameOf: (_) => eff.displayName`）→ 此处转为**防回归**：
  // 若单聊再度回归裸 id，F2.2/F2.3 会再次转红。
  t('F2.2', 'E2E：单聊历史以【张三】开头（展示名）', true,
      sAssistants.isNotEmpty && sAssistants.first.startsWith('【张三】'),
      note: sAssistants.isEmpty ? '<无 assistant>' : '实际=${sAssistants.first}');
  t('F2.3', 'E2E：单聊请求不含裸 expertId', false,
      sMsgs.map((m) => m.content).join('\n').contains(_leaderId));
}

// ---------------------------------------------------------------------------

void _print() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('# QA 任务 #49 用例表');
  stdout.writeln('| ID | 用例 | 期望 | 实际 | 结论 |');
  stdout.writeln('|----|------|------|------|------|');
  for (final r in _res) {
    final e = r.expected.replaceAll('|', r'\|');
    final a = r.actual.replaceAll('|', r'\|');
    stdout.writeln('| ${r.id} | ${r.name} | $e | $a | ${r.pass ? 'PASS' : 'FAIL'} |');
  }
  stdout.writeln('\n合计：通过 $_pass ／ 失败 $_fail');
  if (_fail > 0) {
    stdout.writeln('\n失败明细：');
    for (final r in _res.where((r) => !r.pass)) {
      stdout.writeln('  - [${r.id}] ${r.name}：期望=${r.expected} 实际=${r.actual}'
          '${r.note == null ? '' : '  （${r.note}）'}');
    }
  }
}
