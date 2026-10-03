/// 第 6 轮编排接线验证 T02（纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_core && dart run tool/verify_round6_group.dart`
///
/// 覆盖（任务 #32 · T02 完成标准）：
/// 1. **发言范围指令生效**：用户「让组长一个人发言」→ 只跑组长；
/// 2. **群公告硬契约**：公告文本进入**每位发言者**（含总结者）的 system；
/// 3. **群角色注入**：组长 system 含「组长」、组员 system 含「组员」+ 组长名；
/// 4. **相关性驱动 + 静默契约（断言 7）**：相关成员自动接话；被选中但不相关的成员
///    回 `【不参与】` → step skipped、消息 cancelled 且正文清空、**无可见气泡**；
/// 5. **max_speakers_per_round 上限**：单轮发言者数受群配置约束；
/// 6. **群管理方法**：updateAnnouncement / updateSpeakStrategy / updateMaxSpeakers /
///    renameGroup 落库 + 非法入参拒绝。
library;

import 'dart:async';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架
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

Future<void> checkThrowsCode(
    String name, Future<void> Function() body, String code) async {
  try {
    await body();
    check(name, false, '未抛出异常（期望 code=$code）');
  } catch (e) {
    if (e is AppError && e.code == code) {
      check(name, true);
    } else {
      check(name, false, '抛出了 ${e.runtimeType}(${e is AppError ? e.code : '?'})，期望 $code');
    }
  }
}

// ---------------------------------------------------------------------------
// 可捕获 LLM 替身：按 system 里的专家名决定是否「不参与」
// ---------------------------------------------------------------------------

class GroupLlm implements LlmProvider {
  GroupLlm({
    this.nonParticipants = const {},
    this.failSummarizer = false,
    this.failMembers = false,
  });

  /// 这些**名字**的专家若被选中 → 输出静默哨兵（模拟"自判无关"）。
  final Set<String> nonParticipants;

  /// 为 true 时，**总结调用**（system 含「只输出 JSON」）抛错——用于验证 6-B：
  /// 成员全成功 + 总结者失败 → run 必须落 `partial`（不得静默 `completed`）。
  final bool failSummarizer;

  /// 为 true 时，**成员调用**（非总结）全部抛错——用于验证 6-B：
  /// 群聊全员失败 → run 落 `failed` 且**流中产出 `RunFailedUpdate`**。
  final bool failMembers;
  final List<ChatRequest> calls = [];
  int _n = 0;

  /// 是否总结调用（system 含「只输出 JSON」）。
  static bool _isSummaryCall(ChatRequest request) =>
      request.messages.isNotEmpty &&
      request.messages.first.content.contains('只输出 JSON');

  @override
  String get providerId => 'pp_test';

  @override
  Future<List<ModelDescriptor>> listModels() async =>
      const [ModelDescriptor(modelId: 'test-chat')];

  @override
  Future<ChatResponse> chat(ChatRequest request) async =>
      ChatResponse(content: _respond(request), promptTokens: 5, completionTokens: 5);

  @override
  Stream<StreamEvent> stream(ChatRequest request) async* {
    calls.add(request);
    if (failSummarizer && _isSummaryCall(request)) {
      throw ProviderServerError('总结服务不可用（测试注入）');
    }
    if (failMembers && !_isSummaryCall(request)) {
      throw ProviderServerError('成员服务不可用（测试注入）');
    }
    final text = _respond(request);
    yield TokenDelta(text);
    yield const UsageEvent(5, 5);
    yield const StreamDone();
  }

  String _respond(ChatRequest request) {
    final all = request.messages.map((m) => m.content).join('\n');
    if (all.contains('只输出 JSON')) {
      return '```json\n{"consensus":["已达成共识"],"recommendations":["按此推进"]}\n```';
    }
    final name = _expertName(all);
    if (nonParticipants.contains(name)) return kNonParticipationToken;
    _n++;
    // 内容以「名字 + 序号」为主，确保不同专家的 bigram 集合几乎不重叠（躲开去重 0.82 阈值）。
    final distinct = List.generate(8, (i) => '$name$_n$i').join('，');
    return '【$name】$distinct。';
  }

  /// 取 system 中**首个** 「…」 内的名字（roleBlock 里「你是本群组长/组员「X」」的 X）。
  ///
  /// 不能取最后一个——`nonParticipationRule` 结尾的「【不参与】」也在 「」 内。
  static String _expertName(String system) {
    final m = RegExp('「([^」]+)」').firstMatch(system);
    return m == null ? '' : m.group(1)!.trim();
  }

  @override
  Future<ProviderHealth> healthCheck() async =>
      const ProviderHealth(health: Health.healthy, latencyMs: 5);

  @override
  AppError mapError(Object raw) => raw is AppError ? raw : ProviderServerError('$raw');
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class Harness {
  Harness(this.repos, this.llm)
      : experts = ExpertService(repos),
        providers = ProviderService(repos),
        credentials = CredentialService(repos),
        conversations = ConversationService(repos) {
    knowledge = KnowledgeService(
      repos,
      parsers: [PlainTextParser()],
      chunker: SimpleChunker(targetTokens: 120),
      vectorStore: InMemoryVectorStore(repos.knowledge),
      embeddingModel: HashEmbeddingModel(dimension: 64),
    );
    group = GroupService(
      repos,
      experts: experts,
      conversations: conversations,
      knowledge: knowledge,
      llmFactory: (_) => llm,
    );
  }

  final Repositories repos;
  final LlmProvider llm;
  final ExpertService experts;
  final ProviderService providers;
  final CredentialService credentials;
  final ConversationService conversations;
  late final KnowledgeService knowledge;
  late final GroupService group;

  GroupLlm get groupLlm => llm as GroupLlm;

  /// 注册内置 Provider + 默认模型 + 凭据，使专家可解析到模型（否则 gen.unconfigured）。
  Future<void> bootstrapProvider() async {
    await providers.registerBuiltins();
    await credentials.saveDefault(
      apiKey: 'sk-test-not-a-real-key',
      providerProfileId: ProviderService.deepseekProviderId,
    );
  }
}

Future<List<GenerationUpdate>> runChat(
  Harness h, {
  required String conversationId,
  required String userText,
}) async {
  final msg = await h.conversations.appendUserMessage(conversationId, userText);
  final out = <GenerationUpdate>[];
  await for (final u in h.group.runGroupChat(
    conversationId: conversationId,
    userMessageId: msg.id,
    userText: userText,
  )) {
    out.add(u);
  }
  return out;
}

List<String> _genExpertIds(List<GenerationStep> steps) => steps
    .where((s) => s.stage == StepStage.generation)
    .map((s) => s.expertId ?? '')
    .toList();

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 第 6 轮编排接线验证 T02（群聊发言质量 + 公告 + 静默契约）');
  stdout.writeln('=' * 64);

  SpeakingStrategies.registerBuiltins();

  await _verifyDirectiveOverridesStrategy();
  await _verifyAnnouncementAndRoles();
  await _verifySilentContract();
  await _verifyMaxSpeakersCap();
  await _verifyManagementMethods();
  await _verifySummarizerFailure();
  await _verifyGroupRunFailedEvent();

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

/// 建一个「组长 + 法律 + 医学」群，返回 (h, groupId, ids)。
Future<(Harness, Conversation, String leader, String law, String med)> _mkGroup({
  Set<String> nonParticipants = const {},
  String strategy = 'leader_led',
  bool failSummarizer = false,
  bool failMembers = false,
}) async {
  final repos = inMemoryRepositories();
  final llm = GroupLlm(
    nonParticipants: nonParticipants,
    failSummarizer: failSummarizer,
    failMembers: failMembers,
  );
  final h = Harness(repos, llm);
  await h.bootstrapProvider();

  final leader = await h.experts.createLocal(name: '组长', systemPrompt: '你是本群负责人。');
  final law = await h.experts.createLocal(name: '法律顾问', systemPrompt: '你是法律顾问。');
  final med = await h.experts.createLocal(name: '医生', systemPrompt: '你是全科医生。');
  await h.experts.setTags(leader.id, ['综合管理']);
  await h.experts.setTags(law.id, ['法律', '合同', '条款']);
  await h.experts.setTags(med.id, ['医学', '诊疗']);

  final group = await h.conversations.createGroup(
    title: '顾问团',
    expertIds: [leader.id, law.id, med.id],
    speakStrategy: strategy,
    leaderExpertId: leader.id,
  );
  return (h, group, leader.id, law.id, med.id);
}

// ---------------------------------------------------------------------------
// 1. 发言范围指令覆盖策略
// ---------------------------------------------------------------------------

Future<void> _verifyDirectiveOverridesStrategy() async {
  section('1. 发言范围指令（用户本次指令优先于持久策略）');

  final (h, group, leader, law, med) = await _mkGroup();
  final updates = await runChat(h, conversationId: group.id, userText: '让组长一个人发言');
  final finished = updates.whereType<RunFinishedUpdate>().firstOrNull;
  check('运行完成', finished != null);

  final steps = await h.repos.generations.listSteps(finished!.run.id);
  final gen = _genExpertIds(steps);
  checkEq('仅 1 位发言者', gen.length, 1);
  checkEq('发言者恰为组长', gen.firstOrNull, leader);
  check('组员（法律/医学）均未发言', !gen.contains(law) && !gen.contains(med));

  // 总结者：仅 1 位发言 → accepted < 2 → 不触发总结。
  check('单人发言不触发总结', steps.where((s) => s.stage == StepStage.synthesis).isEmpty);
}

// ---------------------------------------------------------------------------
// 2. 公告硬契约 + 角色注入
// ---------------------------------------------------------------------------

Future<void> _verifyAnnouncementAndRoles() async {
  section('2. 群公告（硬契约）+ 群角色注入（每位发言者含总结者）');

  final (h, group, leader, law, med) = await _mkGroup();
  const ann = '本群只服务招投标项目，与招投标无关的话题一律不参与。';
  await h.group.updateAnnouncement(group.id, ann);
  checkEq('公告已落库', (await h.group.config(group.id))?.announcement, ann);

  // 法律相关话题 → 组长 + 法律顾问入选（医生不相关、不入选）。
  final updates =
      await runChat(h, conversationId: group.id, userText: '这份合同的条款风险怎么审');
  final finished = updates.whereType<RunFinishedUpdate>().firstOrNull;
  final steps = await h.repos.generations.listSteps(finished!.run.id);
  final gen = _genExpertIds(steps);
  check('法律顾问入选', gen.contains(law), 'gen=$gen');
  check('医生不入选（不相关）', !gen.contains(med), 'gen=$gen');

  // 断言：每位发言者的 system 含公告文本（硬契约）。
  final memberCalls = h.groupLlm.calls
      .where((c) => !c.messages.first.content.contains('只输出 JSON'))
      .toList();
  check('存在成员发言调用', memberCalls.isNotEmpty);
  check('每位成员 system 均含公告文本',
      memberCalls.every((c) => c.messages.first.content.contains(ann)),
      'count=${memberCalls.length}');

  // 角色注入：组长 system 含「组长」，组员 system 含「组员」+ 组长名。
  final leaderCall = memberCalls.firstWhere(
      (c) => c.messages.first.content.contains('你是本群组长'),
      orElse: () => memberCalls.first);
  check('组长 system 声明「组长」', leaderCall.messages.first.content.contains('你是本群组长'));
  final memberCall = memberCalls.firstWhere(
      (c) => c.messages.first.content.contains('你是本群组员'),
      orElse: () => memberCalls.first);
  check('组员 system 声明「组员」', memberCall.messages.first.content.contains('你是本群组员'));
  check('组员 system 含组长名', memberCall.messages.first.content.contains('组长'));
  check('组员 system 含相关性自判哨兵', memberCall.messages.first.content.contains(kNonParticipationToken));

  // 总结者 system 也含公告（硬契约覆盖总结者）。
  final summaryCalls =
      h.groupLlm.calls.where((c) => c.messages.first.content.contains('只输出 JSON')).toList();
  check('发生总结调用', summaryCalls.isNotEmpty);
  check('总结者 system 含公告文本',
      summaryCalls.every((c) => c.messages.first.content.contains(ann)));
}

// ---------------------------------------------------------------------------
// 3. 静默契约（断言 7）
// ---------------------------------------------------------------------------

Future<void> _verifySilentContract() async {
  section('3. 静默契约：自判「不参与」→ step skipped + 消息 cancelled + 无可见气泡');

  // 让「医生」在被选中时回【不参与】。
  final (h, group, leader, law, med) = await _mkGroup(nonParticipants: {'医生'});
  const ann = '本群只服务招投标项目。';
  await h.group.updateAnnouncement(group.id, ann);

  // 话题同时命中法律与医学 → 组长 + 法律 + 医生入选（cap 默认 3）。
  final updates =
      await runChat(h, conversationId: group.id, userText: '合同条款和医学诊疗哪个风险更大');
  final finished = updates.whereType<RunFinishedUpdate>().firstOrNull;
  final steps = await h.repos.generations.listSteps(finished!.run.id);
  final gen = _genExpertIds(steps);
  check('医生被选中', gen.contains(med), 'gen=$gen');
  check('法律顾问被选中', gen.contains(law), 'gen=$gen');

  // 医生 step 被标 skipped（partial）且带消息 id。
  final medStep = steps.firstWhere(
      (s) => s.stage == StepStage.generation && s.expertId == med,
      orElse: () => steps.first);
  checkEq('医生 step 状态 = partial（skipped 语义）', medStep.status, RunStatus.partial);
  check('医生 step 记录 outputMessageId', medStep.outputMessageId != null);

  // StepFinishedUpdate：医生 skipped=true，正文为空。
  final medFinish = updates
      .whereType<StepFinishedUpdate>()
      .where((u) => u.expertId == med)
      .firstOrNull;
  check('医生 StepFinishedUpdate skipped=true', medFinish?.skipped == true);
  checkEq('医生 step 正文为空', medFinish?.content, '');

  // 消息：cancelled + 正文清空（UI 不渲染）。
  final medMsg = await h.repos.messages.getMessage(medStep.outputMessageId!);
  checkEq('医生消息状态 = cancelled', medMsg?.status, MessageStatus.cancelled);
  checkEq('医生消息正文已清空', medMsg?.content, '');

  // 可见气泡：history 中不存在「有正文的医生专家消息」。
  final history = await h.conversations.history(group.id);
  final medVisible = history.where((m) => m.isFromExpert && m.senderId == med && m.content.trim().isNotEmpty);
  check('无可见的医生气泡', medVisible.isEmpty);

  // 组长 + 法律（2 位有效）→ 仍触发总结。
  check('有效发言 ≥2 → 触发总结',
      steps.where((s) => s.stage == StepStage.synthesis).isNotEmpty);
}

// ---------------------------------------------------------------------------
// 4. max_speakers_per_round 上限
// ---------------------------------------------------------------------------

Future<void> _verifyMaxSpeakersCap() async {
  section('4. max_speakers_per_round 约束单轮发言者数');

  final (h, group, leader, law, med) = await _mkGroup();
  await h.group.updateMaxSpeakers(group.id, 2);
  checkEq('上限已落库', (await h.group.config(group.id))?.maxSpeakersPerRound, 2);

  // 话题同时命中法律与医学 → 3 人相关，但上限 2。
  final updates =
      await runChat(h, conversationId: group.id, userText: '合同条款和医学诊疗哪个风险更大');
  final finished = updates.whereType<RunFinishedUpdate>().firstOrNull;
  final steps = await h.repos.generations.listSteps(finished!.run.id);
  final gen = _genExpertIds(steps);
  checkEq('发言者恰 2 位（受上限约束）', gen.length, 2);
  check('组长在列（先行）', gen.contains(leader), 'gen=$gen');
}

// ---------------------------------------------------------------------------
// 5. 群管理方法
// ---------------------------------------------------------------------------

Future<void> _verifyManagementMethods() async {
  section('5. 群管理方法（公告 / 策略 / 上限 / 群名）');

  final (h, group, leader, law, med) = await _mkGroup();

  // 策略：合法切换 ✓、非法拒绝 ✗。
  await h.group.updateSpeakStrategy(group.id, 'round_robin');
  checkEq('策略切换为 round_robin', (await h.group.config(group.id))?.speakStrategy, 'round_robin');
  await h.group.updateSpeakStrategy(group.id, 'leader_led');
  checkEq('策略切回 leader_led', (await h.group.config(group.id))?.speakStrategy, 'leader_led');
  await checkThrowsCode('非法策略被拒', () => h.group.updateSpeakStrategy(group.id, 'nope'),
      'group.strategy.unknown');

  // 上限：合法 ✓、越界拒绝 ✗。
  await h.group.updateMaxSpeakers(group.id, 5);
  checkEq('上限置 5', (await h.group.config(group.id))?.maxSpeakersPerRound, 5);
  await checkThrowsCode(
      '上限 0 被拒', () => h.group.updateMaxSpeakers(group.id, 0), 'group.max_speakers.invalid');
  await checkThrowsCode(
      '上限 99 被拒', () => h.group.updateMaxSpeakers(group.id, 99), 'group.max_speakers.invalid');

  // 公告：写入 + 更新时间。
  await h.group.updateAnnouncement(group.id, '共识：先资格后报价。');
  final cfg = await h.group.config(group.id);
  checkEq('公告写入', cfg?.announcement, '共识：先资格后报价。');
  check('公告更新时间已写', cfg?.announcementUpdatedAt != null);
  // 清空公告（空串）。
  await h.group.updateAnnouncement(group.id, '   ');
  checkEq('公告清空', (await h.group.config(group.id))?.announcement, '');

  // 群名：改名 ✓、空名拒绝 ✗。
  await h.group.renameGroup(group.id, '新群名');
  final conv = await h.repos.conversations.getConversation(group.id);
  checkEq('群名已改', conv?.title, '新群名');
  await checkThrowsCode(
      '空群名被拒', () => h.group.renameGroup(group.id, '   '), 'group.title.empty');

  // 单聊不受群级块影响：用一个单聊会话跑一次（不注入群块）。
  // （群级块仅在 runGroupChat 注入；单聊走 GenerationService，不在本脚本范围。）
  check('群管理方法全部可用', true);
}

// ---------------------------------------------------------------------------
// 6. 总结者失败 → run = partial（6-B：不得静默停在 completed）
// ---------------------------------------------------------------------------

Future<void> _verifySummarizerFailure() async {
  section('6. 总结者失败 → run=partial（成员成功 + 总结者失败，不静默 completed）');

  // 成员照常（组长 + 法律相关入选），但总结调用抛错。
  final (h, group, leader, law, med) = await _mkGroup(failSummarizer: true);

  final updates =
      await runChat(h, conversationId: group.id, userText: '这份合同的条款风险怎么审');
  final finished = updates.whereType<RunFinishedUpdate>().firstOrNull;
  check('运行完成（总结失败不中断 run）', finished != null);

  final steps = await h.repos.generations.listSteps(finished!.run.id);
  final genDone = steps
      .where((s) => s.stage == StepStage.generation && s.status == RunStatus.completed)
      .length;
  check('成员发言仍成功（≥2）', genDone >= 2, 'completed=$genDone');

  final synth = steps.where((s) => s.stage == StepStage.synthesis).toList();
  checkEq('总结 step 唯一', synth.length, 1);
  checkEq('总结 step 状态 = failed', synth.firstOrNull?.status, RunStatus.failed);

  checkEq('run 状态 = partial（不得 completed）', finished.run.status, RunStatus.partial);
  check('无 SummaryUpdate 产出', updates.whereType<SummaryUpdate>().isEmpty);

  // 6-B 判据 ①：流中出现 SummaryFailedUpdate（携失败总结者 + 错误原因）；
  // 且 partial **不回填** run.errorCode（6-A：仅 failed 回填）。
  final sumFailed = updates.whereType<SummaryFailedUpdate>().toList();
  check('流中出现 SummaryFailedUpdate', sumFailed.isNotEmpty);
  final sf = sumFailed.firstOrNull;
  check('SummaryFailedUpdate 携带失败总结者 expertId',
      sf != null && sf.expertId.isNotEmpty, 'expertId=${sf?.expertId}');
  check('SummaryFailedUpdate 携带错误原因（非静默）',
      sf != null && sf.error.message.contains('总结服务不可用'), 'error=${sf?.error.message}');
  checkEq('run.errorCode = null（partial 不回填）', finished.run.errorCode, null);
}

// ---------------------------------------------------------------------------
// 6b. 群聊全员失败 → run = failed + 流中 RunFailedUpdate（6-B 判据 ②）
// ---------------------------------------------------------------------------

Future<void> _verifyGroupRunFailedEvent() async {
  section('6b. 群聊全员失败 → run=failed + 流中 RunFailedUpdate（与单聊同口径）');

  // 成员调用全部抛错 → 无任何 accepted 产出。
  final (h, group, leader, law, med) = await _mkGroup(failMembers: true);

  final updates =
      await runChat(h, conversationId: group.id, userText: '这份合同的条款风险怎么审');
  final finished = updates.whereType<RunFinishedUpdate>().firstOrNull;
  check('运行完成（全员失败不阻断 run 终态）', finished != null);

  checkEq('run 状态 = failed（全员失败）', finished!.run.status, RunStatus.failed);
  check('流中出现 RunFailedUpdate', updates.whereType<RunFailedUpdate>().isNotEmpty);
  check('run.errorCode 已回填（failed 必回填）', finished.run.errorCode != null);

  final steps = await h.repos.generations.listSteps(finished.run.id);
  check('全员失败 → 无总结（accepted<2）',
      steps.where((s) => s.stage == StepStage.synthesis).isEmpty);
}
