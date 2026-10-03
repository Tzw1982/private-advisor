/// 严过关 · 独立 QA 验证脚本 —— **群聊失败分支独立断言集**。
///
/// 运行：`cd advisor_core && dart run tool/qa_verify_group_failure.dart`
///
/// 背景（team-lead 提级理由）：单聊脚本 `qa_verify_single_chat.dart` 的 **[C5.9]**
/// 抓到一个**真缺陷**——`runSingleChat` 的失败 catch 只把 step/run 置 failed，
/// **从不 `updateMessage` 占位专家消息**，导致其永远停留在 `MessageStatus.streaming`
/// （与 `run=failed` 不一致、UI 上表现为一个转不完的“悬空气泡”）。
///
/// team-lead 已读代码坐实群聊 `runGroupChat` **成员循环的 Fail Soft catch 有同一处遗漏**
/// （`services.dart` 成员循环 `catch` 仅 `upsertStep(failed)` + 记 skipped，
/// 从不 `updateMessage(msg)`）。本脚本即为其**群聊版第二套独立断言**。
///
/// 独立性声明（硬约束）：
/// - **不 import 任何 `verify*.dart` 辅助函数**（`Harness` / `DynamicLlm` / `_drain` 一律自建）；
/// - 自带脚本化 LLM（`_OutcomeLlm`，可**逐调用**指定“成功 / 失败”，支持“部分产出后失败”）；
/// - 自带断言框架（`t` / `Case`）；
/// - 用 `inMemoryRepositories()` + 真跑 `runGroupChat`（`async*` 惰性，**一律经 `_collect`/`_drain` 消费**）；
/// - **只读取 / 调用生产代码，不修改任何生产代码**。
///
/// 覆盖：
///   H1 单成员流式失败（C5.9 群聊版，task #42 已修复 → 全绿）—— Fail Soft + 占位终态 + 总结仍跑
///   H2 全员失败 —— run 终态（含 errorCode 回填正向不变式）+ 无悬挂 running
///   H3 §2.8 总结者失败契约（`SummaryFailedUpdate`）—— 主线 / 全员失败 / 反向 /
///      归一化边界 / 回归护栏 五个场景，独立于工程师 `verify_round7` 的第二套断言。
library;

import 'dart:async';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（自建）
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
// async* 惰性护栏（自建，语义与既有 QA 脚本一致）
// ---------------------------------------------------------------------------

/// `runGroupChat` 是 `async*`（惰性 Stream）：`await` 只拿到 Stream 对象，
/// **函数体（成员循环 / 落库 / Fail Soft 判定）根本不会执行**，错误也不会抛出。
/// 必须消费它才会真正跑。本 helper 把“消费”集中化，杜绝未消费 → 假绿。
Future<void> _drain(Stream<dynamic> stream) => stream.forEach((_) {});

/// 消费并收集全部更新（同样是一次完整消费；用具断言编排事件）。
Future<List<GenerationUpdate>> _collect(Stream<GenerationUpdate> stream) =>
    stream.toList();

// ---------------------------------------------------------------------------
// 本脚本自有的脚本化 LLM（可逐调用指定成败，不 import verify*.dart）
// ---------------------------------------------------------------------------

/// 单次调用的预设：成功返回 [text]，或失败抛出 [error]（可选先产出 [partial]），
/// 或直接抛出**非 [AppError]** 的原始对象 [thrown]（验证归一化边界）。
class _Outcome {
  _Outcome.ok(this.text)
      : fail = false,
        error = null,
        partial = null,
        thrown = null;
  _Outcome.fail(this.error, {this.partial})
      : fail = true,
        text = null,
        thrown = null;

  /// 首事件即抛出**非 AppError** 的原始对象（H3.4 归一化边界专用）：
  /// 走 `e is AppError ? e : GenerationError('gen.summarizer_failed', …)` 分支。
  _Outcome.throwRaw(this.thrown)
      : fail = false,
        text = null,
        error = null,
        partial = null;

  final bool fail;
  final String? text;
  final AppError? error;

  /// 失败前先产出的正文片段（模拟“部分产出后中断”）；为空则首事件即失败。
  final String? partial;

  /// 非 AppError 的原始抛错对象（H3.4 用）。
  final Object? thrown;
}

/// H3.4 专用：模拟“非 AppError”原始异常（用于验证总结者 catch 的归一化分支）。
class _RawFailure implements Exception {
  @override
  String toString() => '模拟非 AppError 原始异常';
}

/// 按调用次序返回预设结果；超出则复用最后一个。失败以 `StreamErrorEvent` 表达。
class _OutcomeLlm implements LlmProvider {
  _OutcomeLlm(this.outcomes, {this.providerId = 'pp_gf'});

  final List<_Outcome> outcomes;
  final List<ChatRequest> calls = [];
  int _i = 0;

  @override
  final String providerId;

  @override
  Future<List<ModelDescriptor>> listModels() async =>
      const [ModelDescriptor(modelId: 'deepseek-chat')];

  @override
  Future<ChatResponse> chat(ChatRequest request) async => const ChatResponse(content: '');

  @override
  Stream<StreamEvent> stream(ChatRequest request) async* {
    calls.add(request);
    final o = outcomes[_i < outcomes.length ? _i : outcomes.length - 1];
    _i++;
    final raw = o.thrown;
    if (raw != null) {
      // 直接抛出非 AppError（async* 中 throw → 流错误；await for 端 rethrow 原始对象）。
      throw raw;
    }
    if (o.fail) {
      final p = o.partial;
      if (p != null && p.isNotEmpty) {
        yield TokenDelta(p);
        await Future<void>.delayed(Duration.zero);
      }
      yield StreamErrorEvent(o.error!);
      return;
    }
    final text = o.text!;
    for (var i = 0; i < text.length; i += 8) {
      final end = i + 8 > text.length ? text.length : i + 8;
      yield TokenDelta(text.substring(i, end));
      await Future<void>.delayed(Duration.zero);
    }
    yield UsageEvent(5, 9);
    yield const StreamDone();
  }

  @override
  Future<ProviderHealth> healthCheck() async =>
      const ProviderHealth(health: Health.healthy, latencyMs: 1);

  @override
  AppError mapError(Object raw) => raw is AppError ? raw : ProviderServerError('$raw');
}

// ---------------------------------------------------------------------------
// 装置
// ---------------------------------------------------------------------------

class _GH {
  _GH(this.repos, this.updates, this.run);
  final Repositories repos;
  final List<GenerationUpdate> updates;
  final GenerationRun run;

  Future<List<Message>> expertMsgs() async =>
      (await repos.messages.listMessages('c6')).where((m) => m.isFromExpert).toList();

  Future<List<GenerationStep>> steps() => repos.generations.listSteps(run.id);

  Future<GenerationRun?> reloadRun() => repos.generations.getRun(run.id);
}

/// 组装群聊装置并真跑一次（全员发言指令 → 3 名成员 + 可选总结）。
Future<_GH> _buildGroup(
  List<_Outcome> outcomes, {
  String userText = '大家都说说看法',
}) async {
  final repos = inMemoryRepositories();
  final now = DateTime.now().millisecondsSinceEpoch;

  await repos.providers.upsertProvider(const ProviderProfile(
      id: 'pp_gf', providerId: 'deepseek', displayName: 'GF', baseUrl: 'https://gf.local'));
  await repos.providers.upsertModel(ModelProfile.deepseekChat(providerProfileId: 'pp_gf'));
  await repos.credentials.upsert(CredentialProfile(
      id: 'cr_gf', providerProfileId: 'pp_gf', name: 'k', secretRef: 'ref_gf',
      createdAt: now, updatedAt: now));
  await repos.secrets.write('ref_gf', 'sk-gf');
  await repos.settings.set(SettingKeys.defaultModelProfileId, 'mp_deepseek_chat');
  await repos.settings.set(SettingKeys.defaultCredentialProfileId, 'cr_gf');

  for (final e in [
    (id: 'eL', name: '李组', tags: ['消防车']),
    (id: 'eM1', name: '张工', tags: ['消防车泵']),
    (id: 'eM2', name: '王律', tags: ['合同法']),
  ]) {
    await repos.experts.upsertExpert(Expert(
        id: e.id, name: e.name, systemPrompt: 'sp', source: ExpertSource.local,
        createdAt: now, updatedAt: now));
    await repos.experts.setTags(e.id, e.tags);
  }

  await repos.conversations.upsertConversation(Conversation(
      id: 'c6', type: ConversationType.group, title: '失败测试群',
      createdAt: now, updatedAt: now));
  await repos.conversations.upsertMember(const ConversationMember(
      conversationId: 'c6', expertId: 'eL', role: MemberRole.leader, sortOrder: 0));
  await repos.conversations.upsertMember(
      const ConversationMember(conversationId: 'c6', expertId: 'eM1', sortOrder: 1));
  await repos.conversations.upsertMember(
      const ConversationMember(conversationId: 'c6', expertId: 'eM2', sortOrder: 2));
  await repos.conversations.upsertGroupConfig(const GroupConfig(
      conversationId: 'c6', speakStrategy: 'leader_led', maxSpeakersPerRound: 3));

  final experts = ExpertService(repos);
  final conversations = ConversationService(repos);
  final knowledge = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    retriever: InMemoryRetriever(repos.knowledge),
  );
  final llm = _OutcomeLlm(outcomes);
  final group = GroupService(
    repos,
    experts: experts,
    conversations: conversations,
    knowledge: knowledge,
    llmFactory: (_) => llm,
  );

  // async* 惰性：必须消费（_collect）才会真正跑编排，否则 msgs/runs 全为空 → 假绿。
  final updates = await _collect(group.runGroupChat(
    conversationId: 'c6',
    userMessageId: 'um_gf',
    userText: userText,
  ));

  final runs = await repos.generations.listRuns('c6');
  return _GH(repos, updates, runs.last);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('严过关 · 独立 QA 验证（群聊失败分支独立断言集）');
  stdout.writeln('=' * 62);
  stdout.writeln('dart = ${Platform.version}');

  await _h1_singleMemberFails();
  await _h2_allMembersFail();
  await _h3_summaryFailedContract();

  _print();
  exitCode = _fail == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// H1 单成员流式失败（C5.9 群聊版）
// ---------------------------------------------------------------------------

Future<void> _h1_singleMemberFails() async {
  section('H1 单成员流式失败：Fail Soft + 占位终态 + 总结仍跑');
  stdout.writeln('  说明：3 名成员按序发言（eL→eM1→eM2），第 2 名（eM1）'
      '“部分产出后失败”，其余正常 → accepted=2，总结应照常跑。');

  // 调用序：0=eL 成功, 1=eM1 部分产出后失败, 2=eM2 成功, 3=总结者成功
  final h = await _buildGroup([
    _Outcome.ok('李组：先给结论，消防车泵流量需大于 60L/s。'),
    _Outcome.fail(ProviderServerError('模拟成员服务端错误'), partial: '张工：这个'),
    _Outcome.ok('王律：从合同法角度，该条款需明确违约责任。'),
    _Outcome.ok('（总结）已汇总两位专家意见。'),
  ]);

  final steps = await h.steps();
  final msgs = await h.expertMsgs();
  final run = await h.reloadRun();

  final genSteps = steps.where((s) => s.stage == StepStage.generation).toList();
  final failedStep =
      genSteps.where((s) => s.status == RunStatus.failed).toList();

  // 发言人数（全员指令 → 3）
  t('H1.1', '生成阶段发言 step 数 = 3（全员指令）', 3, genSteps.length);
  // 恰有 1 名成员失败
  t('H1.2', '失败成员 step 恰好 1 个', 1, failedStep.length);
  t('H1.3', '失败成员 step 状态 = failed', RunStatus.failed,
      failedStep.isEmpty ? '(无)' : failedStep.single.status);
  t('H1.4', '失败成员 step errorCode = provider.server', 'provider.server',
      failedStep.isEmpty ? '(无)' : failedStep.single.errorCode);

  // —— C5.9 群聊版：失败成员的占位消息必须处于终态（不得 streaming）——
  final failedExpertId = failedStep.isEmpty ? null : failedStep.single.expertId;
  final failedMsgs =
      msgs.where((m) => m.senderId == failedExpertId).toList();
  final failedMsg = failedMsgs.isEmpty ? null : failedMsgs.last;
  t('H1.5', '失败成员的占位专家消息已落库（1 条）', 1, failedMsgs.length,
      note: 'failedExpertId=$failedExpertId');
  t('H1.6', '【C5.9群聊版】失败成员占位消息处于终态（非 streaming，与 step=failed 一致）',
      true, failedMsg != null && failedMsg.status != MessageStatus.streaming,
      note: 'task #42 已修复（占位消息落终态）；实际状态=${failedMsg?.status}');
  t('H1.7', '【C5.9群聊版·强断言】失败成员占位消息状态 = failed', true,
      failedMsg != null && failedMsg.status == MessageStatus.failed,
      note: 'task #42 已修复；实际状态=${failedMsg?.status}');

  // Fail Soft：其余成员不受影响
  final okMsgs = msgs
      .where((m) => m.senderId != failedExpertId && m.status == MessageStatus.completed)
      .toList();
  t('H1.8', '其余成员照样完成（Fail Soft：completed 消息 = 2 条成员发言 + 1 条总结）',
      3, okMsgs.length,
      note: '各成员=${msgs.map((m) => '${m.senderId}:${m.status.name}').toList()}');

  // 总结仍跑（accepted=2）
  final synth = steps.where((s) => s.stage == StepStage.synthesis).toList();
  t('H1.9', '总结 step 存在（accepted=2 触发）', 1, synth.length);
  t('H1.10', '总结 step 状态 = completed', RunStatus.completed,
      synth.isEmpty ? '(无)' : synth.single.status);
  final summaryUps = h.updates.whereType<SummaryUpdate>().toList();
  t('H1.11', '产出 SummaryUpdate（总结消息已生成）', 1, summaryUps.length);

  // run 终态
  t('H1.12', 'run 状态 = partial（有成功有失败）', RunStatus.partial, run?.status);
  t('H1.13', 'run.errorCode 未被群级覆盖（成员失败不升为整群失败）', true,
      run == null || run.errorCode == null, note: '实际=${run?.errorCode}');

  // 无悬挂 running
  final running = steps.where((s) => s.status == RunStatus.running).toList();
  t('H1.14', '无残留 running step', 0, running.length,
      note: 'running=${running.map((s) => '${s.expertId}/${s.stage.name}').toList()}');

  // 失败成员气泡：终态后不应是“半透明生成中”；记录内容供人评估
  t('H1.15', '失败成员占位正文（记录，供评估是否保留部分产出）', 'recorded',
      'recorded', note: '实际正文=「${failedMsg?.content}」');
}

// ---------------------------------------------------------------------------
// H2 全员失败
// ---------------------------------------------------------------------------

Future<void> _h2_allMembersFail() async {
  section('H2 全员失败：run 终态 + 无悬挂 running + 不产出总结');

  // 3 名成员全部失败（首事件即失败）
  final h = await _buildGroup([
    _Outcome.fail(NetworkError('成员A 网络不可达')),
    _Outcome.fail(NetworkError('成员B 网络不可达')),
    _Outcome.fail(NetworkError('成员C 网络不可达')),
  ]);

  final steps = await h.steps();
  final msgs = await h.expertMsgs();
  final run = await h.reloadRun();

  final genSteps = steps.where((s) => s.stage == StepStage.generation).toList();
  t('H2.1', '生成阶段发言 step 数 = 3', 3, genSteps.length);
  t('H2.2', '3 名成员 step 全部 failed', 3,
      genSteps.where((s) => s.status == RunStatus.failed).length);

  t('H2.3', '【C5.9群聊版】全部占位消息处于终态（非 streaming）', true,
      msgs.isNotEmpty && msgs.every((m) => m.status != MessageStatus.streaming),
      note: 'task #42 已修复；实际=${msgs.map((m) => m.status.name).toList()}');
  t('H2.4', '占位消息数 = 3（每名成员各 1 条）', 3, msgs.length);

  t('H2.5', 'run 状态 = failed（accepted 为空且 anyFailed）', RunStatus.failed, run?.status);

  final running = steps.where((s) => s.status == RunStatus.running).toList();
  t('H2.6', '无残留 running step', 0, running.length,
      note: 'running=${running.map((s) => '${s.expertId}/${s.stage.name}').toList()}');

  final synth = steps.where((s) => s.stage == StepStage.synthesis).toList();
  t('H2.7', '无总结 step（accepted=0 不触发）', 0, synth.length);
  t('H2.8', '无 SummaryUpdate', 0, h.updates.whereType<SummaryUpdate>().length);

  // —— 正向不变式（6-A 修复生效后的契约 §2.7）——
  // 群聊 run=failed 时，run.errorCode 必须**回填**「首个失败成员 step 的 errorCode」（非空）；
  // 群聊 run=partial 时，run.errorCode 必须保持 null（见 H1.13，成员失败不升为整群失败）。
  // 修复前此处实测 run=null（症状记录式断言），6-A 修复后回填 provider.network →
  // 本条由「红（记录症状）」转「绿（正向不变式）」= 修复生效的证据。
  t('H2.9', 'run=failed 时 errorCode 应非空（与单聊失败路径一致）', true,
      run != null && (run.errorCode != null && run.errorCode!.isNotEmpty),
      note: '契约 §2.7：群级终态回填首个失败成员码；实际=${run?.errorCode}');

  final firstFailedCode = genSteps.isEmpty ? null : genSteps.first.errorCode;
  t('H2.10',
      '正向不变式：run=failed ⇒ run.errorCode == 首个失败 step.errorCode（非空）',
      true,
      run != null &&
          run.status == RunStatus.failed &&
          run.errorCode != null &&
          run.errorCode == firstFailedCode,
      note: 'step=$firstFailedCode / run=${run?.errorCode}；'
          '（修复前症状记录 run=null，已由 6-A 修复为回填，本条由红转绿）');
}

// ---------------------------------------------------------------------------
// H3 契约 §2.8：总结者失败契约（SummaryFailedUpdate）
//
// 与"成员失败"（H1/H2）**语义独立**：成员可全部成功，但本轮**未产出会议纪要**。
// 断言原则（延续既有风格）：**正向不变式**、不硬编码具体错误码
// （唯 H3.4 例外——该场景本身即验证"非 AppError → gen.summarizer_failed"的归一化契约）。
// ---------------------------------------------------------------------------

Future<void> _h3_summaryFailedContract() async {
  section('H3 §2.8 总结者失败契约（SummaryFailedUpdate）');

  // ── H3.1 主线：3 成员全部成功发言 + 仅总结者抛错 ──────────────────────────
  // 调用序：0=eL, 1=eM1, 2=eM2 全部成功；3=总结者抛错。
  final h1 = await _buildGroup([
    _Outcome.ok('李组：先给结论——消防车泵流量指标需大于 60L/s。'),
    _Outcome.ok('张工：泵体结构上建议采用双级离心，兼顾压力与流量。'),
    _Outcome.ok('王律：合同条款需明确验收标准与违约责任。'),
    _Outcome.fail(ProviderServerError('模拟总结者服务端错误')),
  ]);
  final steps1 = await h1.steps();
  final run1 = await h1.reloadRun();
  final gen1 = steps1.where((s) => s.stage == StepStage.generation).toList();
  final synth1 = steps1.where((s) => s.stage == StepStage.synthesis).toList();
  final failed1 = h1.updates.whereType<SummaryFailedUpdate>().toList();
  final sf1 = failed1.isEmpty ? null : failed1.single;

  t('H3.1.1', '生成阶段发言 step 数 = 3（全员指令）', 3, gen1.length);
  t('H3.1.2', '3 名成员全部发言成功（completed，无成员失败）', 3,
      gen1.where((s) => s.status == RunStatus.completed).length);
  t('H3.1.3', '恰 1 个 SummaryFailedUpdate', 1, failed1.length);
  t('H3.1.4',
      'SummaryFailedUpdate.expertId == 总结 step.expertId（即失败的总结者）',
      true,
      sf1 != null && synth1.isNotEmpty && sf1.expertId == synth1.single.expertId,
      note: 'event=${sf1?.expertId} / step=${synth1.isEmpty ? '(无)' : synth1.single.expertId}');
  t('H3.1.5', 'SummaryFailedUpdate.error.code 非空（错误对象已携出）', true,
      sf1 != null && sf1.error.code.isNotEmpty,
      note: '实际=${sf1?.error.code}');
  t('H3.1.6', '总结 step 状态 = failed', RunStatus.failed,
      synth1.isEmpty ? '(无)' : synth1.single.status);
  t('H3.1.7', '总结 step errorCode 非空（失败原因已落库）', true,
      synth1.isNotEmpty && (synth1.single.errorCode?.isNotEmpty ?? false),
      note: '实际=${synth1.isEmpty ? '(无)' : synth1.single.errorCode}');
  t('H3.1.8', 'run.status = partial（成员全成功但总结失败 —— 不得 completed）',
      RunStatus.partial, run1?.status,
      note: '§2.8：总结失败须落 partial，避免静默停在 completed');
  t('H3.1.9', 'run.errorCode = null（总结失败不升为整群 run 级 errorCode，§2.7 口径）',
      true, run1?.errorCode == null, note: '实际=${run1?.errorCode}');
  t('H3.1.10', '无 SummaryUpdate（本轮未产出纪要）', 0,
      h1.updates.whereType<SummaryUpdate>().length);

  // ── H3.2 全员失败 → run 落 failed 且产出 RunFailedUpdate（§2.8-B）────────────
  final h2 = await _buildGroup([
    _Outcome.fail(NetworkError('成员A 网络不可达')),
    _Outcome.fail(NetworkError('成员B 网络不可达')),
    _Outcome.fail(NetworkError('成员C 网络不可达')),
  ]);
  final steps2 = await h2.steps();
  final run2 = await h2.reloadRun();
  final gen2 = steps2.where((s) => s.stage == StepStage.generation).toList();
  final runFailedEvts = h2.updates.whereType<RunFailedUpdate>().toList();
  final firstFailedCode2 = gen2.isEmpty ? null : gen2.first.errorCode;

  t('H3.2.1', '流中出现 RunFailedUpdate（修掉「群聊从不产出失败事件」）', true,
      runFailedEvts.isNotEmpty,
      note: '收到 ${runFailedEvts.length} 个 RunFailedUpdate');
  t('H3.2.2', 'RunFailedUpdate.run.status = failed', true,
      runFailedEvts.isNotEmpty && runFailedEvts.first.run.status == RunStatus.failed);
  t('H3.2.3', 'run.status = failed（accepted 空且 anyFailed）', RunStatus.failed,
      run2?.status);
  t('H3.2.4', 'run=failed ⇒ run.errorCode == 首个失败 step.errorCode（非空，§2.7 回填）',
      true,
      run2 != null && run2.errorCode != null && run2.errorCode == firstFailedCode2,
      note: 'step=$firstFailedCode2 / run=${run2?.errorCode}');
  t('H3.2.5', '无 SummaryFailedUpdate（accepted=0 未进入总结路径，路径不交叉）', 0,
      h2.updates.whereType<SummaryFailedUpdate>().length);

  // ── H3.3 反向护栏：总结者成功 → 不得误报 SummaryFailedUpdate ────────────────
  final h3 = await _buildGroup([
    _Outcome.ok('李组：结论先行，建议分两阶段推进落地。'),
    _Outcome.ok('张工：结构参数按双级离心设计更稳妥。'),
    _Outcome.ok('王律：合同需明确违约责任与验收标准。'),
    _Outcome.ok('（总结）已汇总三位专家意见，形成会议纪要。'),
  ]);
  final steps3 = await h3.steps();
  final run3 = await h3.reloadRun();
  final synth3 = steps3.where((s) => s.stage == StepStage.synthesis).toList();

  t('H3.3.1', '恰 1 个 SummaryUpdate（纪要已产出）', 1,
      h3.updates.whereType<SummaryUpdate>().length);
  t('H3.3.2', '无 SummaryFailedUpdate（总结成功路径不得误报）', 0,
      h3.updates.whereType<SummaryFailedUpdate>().length);
  t('H3.3.3', '总结 step 状态 = completed', RunStatus.completed,
      synth3.isEmpty ? '(无)' : synth3.single.status);
  t('H3.3.4', 'run.status = completed（无任何失败）', RunStatus.completed, run3?.status);

  // ── H3.4 归一化边界：总结者抛出**非 AppError** → 不崩溃 + 归一化 ──────────────
  final h4 = await _buildGroup([
    _Outcome.ok('李组：先给结论，建议采用双级离心泵方案。'),
    _Outcome.ok('张工：结构上需校核流量与扬程的匹配区间。'),
    _Outcome.ok('王律：验收标准与违约责任应在合同中写明。'),
    _Outcome.throwRaw(_RawFailure()),
  ]);
  final steps4 = await h4.steps();
  final run4 = await h4.reloadRun();
  final failed4 = h4.updates.whereType<SummaryFailedUpdate>().toList();
  final sf4 = failed4.isEmpty ? null : failed4.single;

  t('H3.4.1', '恰 1 个 SummaryFailedUpdate（非 AppError 亦不崩溃，事件照常产出）', 1,
      failed4.length);
  t('H3.4.2',
      '归一化边界：非 AppError ⇒ error.code == gen.summarizer_failed（§2.8 catch 归一化契约）',
      'gen.summarizer_failed', sf4?.error.code,
      note: 'catch 表达式：e is AppError ? e : GenerationError(\'gen.summarizer_failed\', …)');
  t('H3.4.3', 'run.status = partial（成员全成功、仅总结者失败）', RunStatus.partial,
      run4?.status);
  t('H3.4.4', '无 SummaryUpdate', 0, h4.updates.whereType<SummaryUpdate>().length);
  t('H3.4.5', 'run.errorCode = null（总结失败不升为 run 级）', true,
      run4?.errorCode == null, note: '实际=${run4?.errorCode}');

  // ── H3.5 回归护栏：单成员失败 + 其余成员与总结者成功 → 不得误报总结失败 ──────
  // 目的：证明「成员失败」与「总结失败」两条路径**互不交叉污染**。
  final h5 = await _buildGroup([
    _Outcome.ok('李组：先给结论，消防车泵流量需大于 60L/s。'),
    _Outcome.fail(ProviderServerError('模拟成员服务端错误'), partial: '张工：这个'),
    _Outcome.ok('王律：从合同法角度，该条款需明确违约责任。'),
    _Outcome.ok('（总结）已汇总两位专家意见。'),
  ]);
  final steps5 = await h5.steps();
  final run5 = await h5.reloadRun();
  final gen5 = steps5.where((s) => s.stage == StepStage.generation).toList();
  final synth5 = steps5.where((s) => s.stage == StepStage.synthesis).toList();

  t('H3.5.1', '恰 1 名成员失败', 1,
      gen5.where((s) => s.status == RunStatus.failed).length);
  t('H3.5.2', '无 SummaryFailedUpdate（成员失败路径不得污染总结路径）', 0,
      h5.updates.whereType<SummaryFailedUpdate>().length);
  t('H3.5.3', '恰 1 个 SummaryUpdate（总结照常产出）', 1,
      h5.updates.whereType<SummaryUpdate>().length);
  t('H3.5.4', '总结 step 状态 = completed', RunStatus.completed,
      synth5.isEmpty ? '(无)' : synth5.single.status);
  t('H3.5.5', 'run.status = partial（有成员失败）', RunStatus.partial, run5?.status);
}

// ---------------------------------------------------------------------------
// 输出
// ---------------------------------------------------------------------------

void _print() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('# QA 群聊失败分支独立断言用例表');
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
