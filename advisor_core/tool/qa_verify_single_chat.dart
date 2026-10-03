/// 严过关 · 独立 QA 验证脚本 —— **单聊 `runSingleChat` 独立断言集**。
///
/// 运行：`cd advisor_core && dart run tool/qa_verify_single_chat.dart`
///
/// 背景（team-lead 提级理由）：`conversation_view.dart` **单聊/群聊共用**，第 6 轮
/// 群聊改造触碰了该共享 UI 层；群聊侧已有独立断言（`qa_verify_round6.dart`），
/// 但**单聊链路缺一套与工程师脚本相互独立的断言**。本脚本即为补齐。
///
/// 独立性声明（硬约束）：
/// - **不 import 任何 `verify*.dart` 辅助函数**（`Harness` / `DynamicLlm` / `_drain` 等一律自建）；
/// - 自带脚本化 LLM（`_ScriptedLlm`）、自带断言框架（`t` / `Case`）；
/// - 用 `inMemoryRepositories()` + 真跑 `runSingleChat`（`async*` 惰性，必须消费）；
/// - **只读取 / 调用生产代码，不修改任何生产代码**。
///
/// 六类覆盖：
///   1) 七类流式更新（顺序 + 数量）  2) 思考过程不外泄
///   3) 引用落库                     4) 续聊落库与重载
///   5) 失败分支（RunFailed）        6) 边界
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（自建，与验证脚本互不复用）
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
// async* 惰性护栏（自建同名 helper，语义与既有 QA 脚本一致）
// ---------------------------------------------------------------------------

/// `runSingleChat` 是 `async*`（惰性 Stream）：`await` 只拿到 Stream 对象，
/// **函数体（检索 / 落库 / 编排）根本不会执行**，错误也不会抛出。
/// 必须消费它才会真正跑。本 helper 把"消费"集中化，杜绝未消费 → 假绿。
Future<void> _drain(Stream<dynamic> stream) => stream.forEach((_) {});

/// 消费并收集全部更新（同样是一次完整 drain）。
Future<List<GenerationUpdate>> _collect(Stream<GenerationUpdate> stream) =>
    stream.toList();

// ---------------------------------------------------------------------------
// 本脚本自有的脚本化 LLM（不 import verify*.dart）
// ---------------------------------------------------------------------------

/// 按调用次序返回预设事件序列；超出则复用最后一个（多轮续聊用）。
class _ScriptedLlm implements LlmProvider {
  _ScriptedLlm(this.turns, {this.providerId = 'pp_q'});

  final List<List<StreamEvent>> turns;
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
    final events = turns[_i < turns.length ? _i : turns.length - 1];
    _i++;
    for (final e in events) {
      yield e;
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<ProviderHealth> healthCheck() async =>
      const ProviderHealth(health: Health.healthy, latencyMs: 1);

  @override
  AppError mapError(Object raw) => raw is AppError ? raw : ProviderServerError('$raw');
}

/// 构造一条"正文回答"事件序列：可选前置 reasoning 通道增量 + 分片 token 增量 + 用量 + 结束。
List<StreamEvent> _reply(String text, {int chunk = 8, List<String> reasoning = const []}) {
  final out = <StreamEvent>[];
  for (final r in reasoning) {
    out.add(ReasoningDelta(r));
  }
  for (var i = 0; i < text.length; i += chunk) {
    out.add(TokenDelta(text.substring(i, math.min(i + chunk, text.length))));
  }
  out.add(UsageEvent(7, 13));
  out.add(const StreamDone());
  return out;
}

// ---------------------------------------------------------------------------
// 测试装置 Harness（自建）
// ---------------------------------------------------------------------------

class _H {
  _H({
    required this.repos,
    required this.experts,
    required this.conversations,
    required this.knowledge,
    required this.gen,
    required this.llm,
    required this.expertId,
    required this.convId,
  });

  final Repositories repos;
  final ExpertService experts;
  final ConversationService conversations;
  final KnowledgeService knowledge;
  final GenerationService gen;
  final _ScriptedLlm llm;
  final String expertId;
  final String convId;

  /// 真跑一次单聊并收集全部更新（内部已 drain）。
  Future<List<GenerationUpdate>> run(String userText, {String userMessageId = 'um_syn'}) =>
      _collect(gen.runSingleChat(
        conversationId: convId,
        userMessageId: userMessageId,
        userText: userText,
      ));

  Future<List<Message>> expertMsgs() async =>
      (await repos.messages.listMessages(convId)).where((m) => m.isFromExpert).toList();
}

/// 组装一套可跑单聊的内存装置。
Future<_H> _build({
  List<List<StreamEvent>>? turns,
  String grounding = 'off',
  bool seedKb = false,
  bool configureModel = true,
}) async {
  final repos = inMemoryRepositories();
  final now = DateTime.now().millisecondsSinceEpoch;

  await repos.providers.upsertProvider(const ProviderProfile(
      id: 'pp_q', providerId: 'deepseek', displayName: 'Q', baseUrl: 'https://q.local'));
  await repos.providers.upsertModel(ModelProfile.deepseekChat(providerProfileId: 'pp_q'));
  await repos.credentials.upsert(CredentialProfile(
      id: 'cr_q', providerProfileId: 'pp_q', name: 'k', secretRef: 'ref_q',
      createdAt: now, updatedAt: now));
  await repos.secrets.write('ref_q', 'sk-q');
  if (configureModel) {
    await repos.settings.set(SettingKeys.defaultModelProfileId, 'mp_deepseek_chat');
    await repos.settings.set(SettingKeys.defaultCredentialProfileId, 'cr_q');
  }

  final experts = ExpertService(repos);
  final expert = await experts.createLocal(name: '严测', systemPrompt: '你是测试专家。');
  await repos.experts.upsertRuntimeConfig(ExpertRuntimeConfig(
      expertId: expert.id, groundingPolicy: GroundingPolicy.parse(grounding)));

  final conversations = ConversationService(repos);
  final conv = await conversations.createSingle(expert.id);

  final knowledge = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 120),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    retriever: InMemoryRetriever(repos.knowledge),
    embeddingModel: HashEmbeddingModel(dimension: 256),
  );

  final llm = _ScriptedLlm(turns ?? [_reply('正文答案。')]);
  final gen = GenerationService(
    repos,
    experts: experts,
    conversations: conversations,
    knowledge: knowledge,
    llmFactory: (_) => llm,
  );

  final h = _H(
    repos: repos, experts: experts, conversations: conversations,
    knowledge: knowledge, gen: gen, llm: llm,
    expertId: expert.id, convId: conv.id,
  );
  if (seedKb) await _seedKb(h);
  return h;
}

/// 直接经仓储种入一条知识并绑定（绕过文件解析 I/O，确定性、独立）。
Future<void> _seedKb(_H h) async {
  const text = '液压泵组的流量计算：额定流量应不小于 60 升每秒，压力 1.0 兆帕。';
  final base = await h.knowledge.createBase(name: '测试库');
  final doc = KnowledgeDocument(
    id: 'doc_q', knowledgeBaseId: base.id, fileName: '泵参数.txt',
    filePath: '/qa/泵参数.txt', fileHash: 'hash_q', fileSize: text.length,
    parser: 'plain', parserVersion: '1', status: DocumentStatus.indexed,
    createdAt: 0, updatedAt: 0,
  );
  await h.repos.knowledge.upsertDocument(doc);
  final chunks = [
    KnowledgeChunk(
      id: 'ch_q', documentId: doc.id, text: text, sequence: 0,
      tokenCount: KnowledgeChunk.estimateTokens(text), chunkHash: 'chash_q',
    ),
  ];
  await h.repos.knowledge.insertChunks(chunks);
  await h.knowledge.retriever!.indexChunks(chunks,
      knowledgeBaseId: base.id, documentId: doc.id);
  await h.experts.bindKnowledge(h.expertId, base.id);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('严过关 · 独立 QA 验证（单聊 runSingleChat 独立断言集）');
  stdout.writeln('=' * 62);
  stdout.writeln('dart = ${Platform.version}');

  await _c1_sevenUpdates();
  await _c2_reasoningNotLeaked();
  await _c3_citations();
  await _c4_continuation();
  await _c5_failure();
  await _c5b_failureBoundaries();
  await _c6_edges();

  _coverage();
  _print();
  exitCode = _fail == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// C1 七类流式更新：顺序 + 数量
// ---------------------------------------------------------------------------

Future<void> _c1_sevenUpdates() async {
  section('C1 七类流式更新：顺序 + 数量');
  const reply = '这是单聊的专业回答，包含结论与依据。';
  final h = await _build(turns: [_reply(reply)]);

  final user = await h.conversations.appendUserMessage(h.convId, '单聊问题一');
  final ups = await h.run('单聊问题一', userMessageId: user.id);

  int count<T>() => ups.whereType<T>().length;
  int firstIdx<T>() => ups.indexWhere((u) => u is T);

  // ① RunStartedUpdate
  t('C1.1', 'RunStartedUpdate 恰好 1 个', 1, count<RunStartedUpdate>());
  t('C1.2', 'RunStartedUpdate 为首事件', 0, firstIdx<RunStartedUpdate>());
  final started = ups.whereType<RunStartedUpdate>().single;
  t('C1.3', 'RunStarted.runType = singleChat', RunType.singleChat, started.run.runType);
  t('C1.4', 'RunStarted.run 状态 = running', RunStatus.running, started.run.status);
  t('C1.5', 'RunStarted.triggerMessageId 指向触发消息', user.id, started.run.triggerMessageId);

  // ② StepStatusUpdate
  final statusUps = ups.whereType<StepStatusUpdate>().toList();
  t('C1.6', 'StepStatusUpdate 恰好 2 个（thinking→generating）', 2, statusUps.length);
  t('C1.7', '首个状态 = thinking', Activity.thinking, statusUps.first.activity);
  t('C1.8', '次个状态 = generating', Activity.generating, statusUps.last.activity);
  t('C1.9', 'StepStatus.expertId = 单聊专家', h.expertId, statusUps.first.expertId);

  // ③ DeltaUpdate
  final deltas = ups.whereType<DeltaUpdate>().toList();
  final expectedChunks = (reply.length / 8).ceil();
  t('C1.10', 'DeltaUpdate 数量 = ceil(len/8)', expectedChunks, deltas.length);
  t('C1.11', 'DeltaUpdate 拼接 = 完整正文', reply, deltas.map((d) => d.text).join());
  t('C1.12', 'DeltaUpdate.messageId 全部一致', true,
      deltas.every((d) => d.messageId == deltas.first.messageId));

  // ④ StepFinishedUpdate
  final finished = ups.whereType<StepFinishedUpdate>().toList();
  t('C1.13', 'StepFinishedUpdate 恰好 1 个', 1, finished.length);
  t('C1.14', 'StepFinished.content = 完整正文', reply, finished.single.content);
  t('C1.15', 'StepFinished 未标记 skipped', false, finished.single.skipped);
  t('C1.16', 'StepFinished.messageId = Delta 的 messageId', deltas.first.messageId,
      finished.single.messageId);

  // ⑤ SummaryUpdate（单聊硬契约：绝不产生）
  t('C1.17', 'SummaryUpdate 单聊绝不产生（0 个）', 0, count<SummaryUpdate>());

  // ⑥ RunFinishedUpdate
  final runFin = ups.whereType<RunFinishedUpdate>().toList();
  t('C1.18', 'RunFinishedUpdate 恰好 1 个', 1, runFin.length);
  t('C1.19', 'RunFinished.run 状态 = completed', RunStatus.completed, runFin.single.run.status);
  t('C1.20', 'RunFinishedUpdate 为最后一个事件', ups.length - 1, firstIdx<RunFinishedUpdate>());

  // ⑦ RunFailedUpdate（happy path 不出现）
  t('C1.21', 'happy path 无 RunFailedUpdate', 0, count<RunFailedUpdate>());

  // 顺序严格递增
  final order = <int>[
    firstIdx<RunStartedUpdate>(),
    firstIdx<StepStatusUpdate>(),
    ups.lastIndexWhere((u) => u is StepStatusUpdate),
    ups.indexOf(deltas.first),
    firstIdx<StepFinishedUpdate>(),
    firstIdx<RunFinishedUpdate>(),
  ];
  var ascending = true;
  for (var i = 1; i < order.length; i++) {
    if (order[i] <= order[i - 1]) ascending = false;
  }
  t('C1.22', '事件顺序严格递增（start<think<gen<delta*<finish<end）', true, ascending,
      note: 'indices=$order');

  // 落库一致性
  final msgs = await h.expertMsgs();
  t('C1.23', '恰好落库 1 条专家消息', 1, msgs.length);
  t('C1.24', '落库消息状态 = completed', MessageStatus.completed, msgs.single.status);
  t('C1.25', '落库消息内容 = 完整正文', reply, msgs.single.content);
  t('C1.26', '落库消息 parentMessageId 指向用户消息', user.id, msgs.single.parentMessageId);
}

// ---------------------------------------------------------------------------
// C2 思考过程不外泄
// ---------------------------------------------------------------------------

Future<void> _c2_reasoningNotLeaked() async {
  section('C2 思考过程不外泄（reasoning 通道 + 显式围栏 + 保守剥离）');

  // 2.1~2.6 reasoning 通道：模型可见，但绝不进正文 / 不进 Delta
  const body = '结论：泵流量需大于 60L/s。';
  const secret = '内部推理：先想到X再想到Y';
  final h1 = await _build(turns: [_reply(body, reasoning: [secret])]);
  final ups1 = await h1.run('问题');
  final msg1 = (await h1.expertMsgs()).single;
  t('C2.1', 'reasoning 文本不进入落库正文', false, msg1.content.contains('内部推理'));
  t('C2.2', '落库正文 = 纯正文', body, msg1.content);
  t('C2.3', 'reasoning 不混入任何 DeltaUpdate', false,
      ups1.whereType<DeltaUpdate>().map((d) => d.text).join().contains('内部推理'));

  final run1 = (await h1.repos.generations.listRuns(h1.convId)).single;
  final steps1 = await h1.repos.generations.listSteps(run1.id);
  final events1 = await h1.repos.generations.listEvents(steps1.single.id);
  final reasonEvents =
      events1.where((e) => e.eventType == GenerationEventType.reasoningDelta).toList();
  final tokenEvents =
      events1.where((e) => e.eventType == GenerationEventType.tokenDelta).toList();
  t('C2.4', 'reasoning 落 generation_events(reasoning_delta)', 1, reasonEvents.length);
  t('C2.5', 'reasoning 事件 delta = 原文', secret, reasonEvents.single.delta);
  t('C2.6', 'token 事件拼接 = 正文（不含 reasoning）', body,
      tokenEvents.map((e) => e.delta).join());

  // 2.7~2.8 显式围栏【思考】…【/思考】
  const fenced = '【思考】这是不该展示的推理过程【/思考】这是正式结论。';
  final h2 = await _build(turns: [_reply(fenced)]);
  await h2.run('问题');
  final msg2 = (await h2.expertMsgs()).single;
  t('C2.7', '【思考】围栏内容被剥离', false, msg2.content.contains('不该展示的推理过程'));
  t('C2.8', '围栏外正文保留', true, msg2.content.contains('这是正式结论'));

  // 2.9~2.10 ```thinking 围栏
  const codeFence = '```thinking\n内部思考内容\n```\n对外结论在此。';
  final h3 = await _build(turns: [_reply(codeFence)]);
  await h3.run('问题');
  final msg3 = (await h3.expertMsgs()).single;
  t('C2.9', '```thinking 围栏被剥离', false, msg3.content.contains('内部思考内容'));
  t('C2.10', '围栏外正文保留', true, msg3.content.contains('对外结论在此'));

  // 2.11~2.12 段首元叙述短句（保守剥离）
  const metaLead = '让我想想。这个方案可行。';
  final h4 = await _build(turns: [_reply(metaLead)]);
  await h4.run('问题');
  final msg4 = (await h4.expertMsgs()).single;
  t('C2.11', '段首元叙述“让我想想。”被剥离', false, msg4.content.contains('让我想想'));
  t('C2.12', '真实结论保留', true, msg4.content.contains('这个方案可行'));

  // 2.13~2.14 保守：普通正文不被误删
  const plain = '工程车长臂喷射工程车最大工作高度为 60 米。';
  t('C2.13', '普通正文原样保留', plain, ReasoningStripper.strip(plain).text);
  t('C2.14', '普通正文 changed=false', false, ReasoningStripper.strip(plain).changed);

  // 2.15 安全兜底：剥离后为空 → 回退原文（绝不清空）
  const onlyFence = '【思考】只有推理【/思考】';
  t('C2.15', '仅含围栏时回退原文（不产生空正文）', onlyFence,
      ReasoningStripper.strip(onlyFence).text);
}

// ---------------------------------------------------------------------------
// C3 引用落库
// ---------------------------------------------------------------------------

Future<void> _c3_citations() async {
  section('C3 引用落库（检索 → citation 持久化）');

  final h = await _build(
      turns: [_reply('依据知识库，泵流量应大于 60L/s。')], grounding: 'preferred', seedKb: true);
  final ups = await h.run('液压泵组流量');
  final finished = ups.whereType<StepFinishedUpdate>().single;
  final msg = (await h.expertMsgs()).single;

  t('C3.1', 'StepFinished 携带引用（非空）', true, finished.citations.isNotEmpty,
      note: 'files=${finished.citations.map((c) => c.fileName).toList()}');
  final persisted = await h.repos.messages.listCitations(msg.id);
  t('C3.2', '引用已落库（listCitations 非空）', true, persisted.isNotEmpty);
  t('C3.3', '落库引用数 = 事件携带数', finished.citations.length, persisted.length);
  t('C3.4', '引用含文件名', true, persisted.every((c) => c.fileName.isNotEmpty));
  t('C3.5', '引用含 chunkId / documentId', true,
      persisted.every((c) => c.chunkId.isNotEmpty && c.documentId.isNotEmpty));
  t('C3.6', '引用 score > 0', true, persisted.every((c) => c.score > 0));

  // 未绑定知识库 → 无引用（preferred 也照常回答）
  final h2 = await _build(turns: [_reply('无知识库也能回答。')], grounding: 'preferred');
  final ups2 = await h2.run('液压泵组流量');
  t('C3.7', '未绑定知识库 → 引用为空', 0,
      ups2.whereType<StepFinishedUpdate>().single.citations.length);
  t('C3.8', '未绑定知识库仍正常完成', RunStatus.completed,
      ups2.whereType<RunFinishedUpdate>().single.run.status);
}

// ---------------------------------------------------------------------------
// C4 续聊落库与重载
// ---------------------------------------------------------------------------

Future<void> _c4_continuation() async {
  section('C4 续聊落库与重载（多轮 + 重新加载）');

  final h = await _build(turns: [_reply('第一轮回答。'), _reply('第二轮回答。')]);

  final u1 = await h.conversations.appendUserMessage(h.convId, '第一问');
  await h.run('第一问', userMessageId: u1.id);
  // 毫秒级时间戳排序：插入极小间隔，避免同毫秒导致顺序不确定。
  await Future<void>.delayed(const Duration(milliseconds: 3));
  final u2 = await h.conversations.appendUserMessage(h.convId, '第二问');
  await h.run('第二问', userMessageId: u2.id);

  final live = await h.conversations.history(h.convId);
  final liveExperts = live.where((m) => m.isFromExpert).toList();
  t('C4.1', '两轮后历史共 4 条消息', 4, live.length);
  t('C4.2', '专家消息 2 条', 2, liveExperts.length);
  t('C4.3', '专家内容按序落库', '第一轮回答。|第二轮回答。',
      liveExperts.map((m) => m.content).join('|'));
  t('C4.4', '顺序：用户→专家→用户→专家', true,
      live.length == 4 && live[0].isFromUser && live[1].isFromExpert &&
          live[2].isFromUser && live[3].isFromExpert);
  t('C4.5', '第二条专家消息 parentMessageId 指向第二问', u2.id, liveExperts.last.parentMessageId);

  // 重载：新服务实例读同一仓储（模拟重启后重新加载）
  final reloaded = ConversationService(h.repos);
  final after = await reloaded.history(h.convId);
  t('C4.6', '重载后消息数不变（4）', 4, after.length);
  t('C4.7', '重载后专家内容一致', liveExperts.map((m) => m.content).join('|'),
      after.where((m) => m.isFromExpert).map((m) => m.content).join('|'));
  t('C4.8', '重载后状态均 completed', true,
      after.where((m) => m.isFromExpert).every((m) => m.status == MessageStatus.completed));

  final conv = await h.repos.conversations.getConversation(h.convId);
  t('C4.9', '会话 lastMessageAt 已更新（非 null）', true, conv?.lastMessageAt != null);

  final runs = await h.repos.generations.listRuns(h.convId);
  t('C4.10', '两轮各产生 1 个 run（共 2）', 2, runs.length);
  t('C4.11', '两个 run 均 completed', true, runs.every((r) => r.status == RunStatus.completed));
}

// ---------------------------------------------------------------------------
// C5 失败分支
// ---------------------------------------------------------------------------

Future<void> _c5_failure() async {
  section('C5 失败分支（RunFailed + 状态一致性）');

  // 5.1~5.9 流内错误 → RunFailedUpdate
  final h = await _build(turns: [
    [const StreamErrorEvent(AuthenticationError()), const StreamDone()],
  ]);
  final ups = await h.run('问题');
  final failed = ups.whereType<RunFailedUpdate>().toList();
  t('C5.1', '产生 RunFailedUpdate', 1, failed.length);
  t('C5.2', 'RunFailed.error.code = provider.auth', 'provider.auth', failed.single.error.code);
  t('C5.3', 'RunFailed.run.status = failed', RunStatus.failed, failed.single.run.status);
  t('C5.4', '失败路径不产生 RunFinishedUpdate', 0, ups.whereType<RunFinishedUpdate>().length);

  final run = (await h.repos.generations.listRuns(h.convId)).single;
  t('C5.5', 'run.errorCode 落库 = provider.auth', 'provider.auth', run.errorCode);
  t('C5.6', 'run.status 落库 = failed', RunStatus.failed, run.status);
  final steps = await h.repos.generations.listSteps(run.id);
  t('C5.7', 'step.status 落库 = failed', RunStatus.failed, steps.single.status);

  final msgs = await h.expertMsgs();
  t('C5.8', '失败时已插入占位专家消息', 1, msgs.length);
  t('C5.9', '失败后专家消息处于终态（非 streaming，与 run 一致）', true,
      msgs.single.status != MessageStatus.streaming,
      note: '实际状态=${msgs.single.status}（run 已 failed）');

  // 5.10~5.11 配置缺失 → 明确 ValidationError（不静默）
  final h2 = await _build(configureModel: false, turns: [_reply('x')]);
  Object? err;
  try {
    await h2.run('问题');
  } catch (e) {
    err = e;
  }
  t('C5.10', '无默认模型 → ValidationError(gen.no_model)', true,
      err is ValidationError && err.code == 'gen.no_model', note: '实际=$err');
  t('C5.11', '配置错误不落下悬挂 run', 0,
      (await h2.repos.generations.listRuns(h2.convId)).length);
}

// ---------------------------------------------------------------------------
// C5b 失败边界（首块前 / 部分产出后 / 失败后续聊）——补强 C5.9 缺陷面
// ---------------------------------------------------------------------------

/// 说明（team-lead 派单）：`[C5.9]` 已坐实为**真缺陷**——`runSingleChat` 失败 catch
/// 只把 step/run 置 failed，**从不 `updateMessage` 占位消息** → 其永久停留在
/// `MessageStatus.streaming`。本段把该缺陷的**边界面**补齐（首块前 / 部分产出后），
/// 并验证“失败后续聊可正常恢复（无残留取消标志）”。
///
/// 预期：凡断言“占位消息终态 / = failed / 保留部分产出”者，**当前应为红**
/// （对应已派单缺陷 task #42），修复后转绿；其余为常态断言。
Future<void> _c5b_failureBoundaries() async {
  section('C5b 失败边界（首块前 / 部分产出后 / 失败后续聊）');

  // —— 5b.1~5b.4 失败发生在「首块 Token 之前」——
  final hA = await _build(turns: [
    [const StreamErrorEvent(ProviderServerError('首块前失败')), const StreamDone()],
  ]);
  final upsA = await hA.run('问题');
  final msgA = (await hA.expertMsgs()).single;
  t('C5b.1', '首块前失败：run 状态 = failed', RunStatus.failed,
      upsA.whereType<RunFailedUpdate>().single.run.status);
  t('C5b.2', '首块前失败：占位消息处于终态（非 streaming）', true,
      msgA.status != MessageStatus.streaming,
      note: '预期红·对应已派单缺陷（task #42）；实际=${msgA.status}');
  t('C5b.3', '首块前失败：占位消息状态 = failed（与 run 一致）', true,
      msgA.status == MessageStatus.failed,
      note: '预期红·对应已派单缺陷（task #42）；实际=${msgA.status}');
  t('C5b.4', '首块前失败：正文为空（确无部分产出）', '', msgA.content);

  // —— 5b.5~5b.8 失败发生在「已产出部分正文之后」——
  final hB = await _build(turns: [
    [
      const TokenDelta('部分正文'),
      const StreamErrorEvent(ProviderServerError('部分产出后失败')),
      const StreamDone(),
    ],
  ]);
  final upsB = await hB.run('问题');
  final msgB = (await hB.expertMsgs()).single;
  final deltasB = upsB.whereType<DeltaUpdate>().map((d) => d.text).join();
  t('C5b.5', '部分产出后失败：run 状态 = failed', RunStatus.failed,
      upsB.whereType<RunFailedUpdate>().single.run.status);
  t('C5b.6', '部分产出后失败：已下发 DeltaUpdate 承载部分正文（UI 曾可见）', '部分正文',
      deltasB);
  t('C5b.7', '部分产出后失败：占位消息处于终态（非 streaming）', true,
      msgB.status != MessageStatus.streaming,
      note: '预期红·对应已派单缺陷（task #42）；实际=${msgB.status}');
  t('C5b.8', '部分产出后失败：失败后正文保留已产出部分（post-fix 契约）', '部分正文',
      msgB.content,
      note: '预期红·目标契约：失败不清空已产出正文（与 5b.6 的可见部分一致）；'
          '若工程实现选择“失败即清空”，需回执本断言口径后再更新，勿单方改绿');

  // —— 5b.9~5b.12 失败后再次发起同一会话：无残留取消标志 / 无悬挂 run ——
  final hC = await _build(turns: [
    [const StreamErrorEvent(ProviderServerError('第一次失败')), const StreamDone()],
    _reply('恢复后的正常回答。'),
  ]);
  final upsC1 = await hC.run('第一问');
  t('C5b.9', '失败后重发：首次 run 状态 = failed', RunStatus.failed,
      upsC1.whereType<RunFailedUpdate>().single.run.status);
  final upsC2 = await hC.run('第二问');
  t('C5b.10', '失败后重发：第二次 run = completed（无残留取消标志）', RunStatus.completed,
      upsC2.whereType<RunFinishedUpdate>().single.run.status);
  final msgsC = await hC.expertMsgs();
  t('C5b.11', '失败后重发：恰有 1 条 completed 专家消息（即第二次）', 1,
      msgsC.where((m) => m.status == MessageStatus.completed).length);
  final runsC = await hC.repos.generations.listRuns(hC.convId);
  t('C5b.12', '失败后重发：run 数 = 2，状态依次 = failed|completed', 'failed|completed',
      runsC.map((r) => r.status.name).join('|'));
}

// ---------------------------------------------------------------------------
// C6 边界
// ---------------------------------------------------------------------------

Future<void> _c6_edges() async {
  section('C6 边界（空输入 / 长输入 / 空回复 / 分片合并）');

  // 6.1~6.2 空用户文本
  final h1 = await _build(turns: [_reply('对空输入的回应。')]);
  final ups1 = await h1.run('');
  t('C6.1', '空用户文本：run 完成', RunStatus.completed,
      ups1.whereType<RunFinishedUpdate>().single.run.status);
  t('C6.2', '空用户文本：专家消息落库', 1, (await h1.expertMsgs()).length);

  // 6.3 长用户文本
  final long = '液压泵组参数说明。' * 400;
  final h2 = await _build(turns: [_reply('对长输入的回应。')]);
  final ups2 = await h2.run(long);
  t('C6.3', '长输入（>3000 字）：run 完成', RunStatus.completed,
      ups2.whereType<RunFinishedUpdate>().single.run.status);

  // 6.4~6.7 空模型回复（无 TokenDelta）
  final h3 = await _build(turns: [_reply('')]);
  final ups3 = await h3.run('问题');
  final msg3 = (await h3.expertMsgs()).single;
  t('C6.4', '空回复：无 DeltaUpdate', 0, ups3.whereType<DeltaUpdate>().length);
  t('C6.5', '空回复：仍完成', RunStatus.completed,
      ups3.whereType<RunFinishedUpdate>().single.run.status);
  t('C6.6', '空回复：落库正文为空串', '', msg3.content);
  t('C6.7', '空回复：消息状态 completed', MessageStatus.completed, msg3.status);

  // 6.8~6.11 分片合并（chunk=1）
  const text = '分片回复合并测试ABC';
  final h4 = await _build(turns: [_reply(text, chunk: 1)]);
  final ups4 = await h4.run('问题');
  final deltas4 = ups4.whereType<DeltaUpdate>().toList();
  final msg4 = (await h4.expertMsgs()).single;
  t('C6.8', 'chunk=1：DeltaUpdate 数 = 字符数', text.length, deltas4.length);
  t('C6.9', 'chunk=1：拼接 = 原文', text, deltas4.map((d) => d.text).join());
  t('C6.10', 'chunk=1：落库正文 = 原文', text, msg4.content);
  t('C6.11', 'chunk=1：completionTokens 累计 > 0', true,
      msg4.completionTokens != null && msg4.completionTokens! > 0);

  // 6.12 混合 reasoning + body 分片
  const mixed = '结论XYZ。';
  final h5 = await _build(turns: [_reply(mixed, chunk: 2, reasoning: ['思考中……'])]);
  await h5.run('问题');
  t('C6.12', '混合 reasoning+body 分片：正文纯净', mixed, (await h5.expertMsgs()).single.content);
}

// ---------------------------------------------------------------------------
// 输出
// ---------------------------------------------------------------------------

void _coverage() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('六类覆盖 → 用例编号映射：');
  stdout.writeln('  1) 七类流式更新（顺序+数量）: C1.1 – C1.26');
  stdout.writeln('  2) 思考过程不外泄:            C2.1 – C2.15');
  stdout.writeln('  3) 引用落库:                  C3.1 – C3.8');
  stdout.writeln('  4) 续聊落库与重载:            C4.1 – C4.11');
  stdout.writeln('  5) 失败分支:                  C5.1 – C5.11');
  stdout.writeln('  5b) 失败边界（含预期红）:      C5b.1 – C5b.12');
  stdout.writeln('  6) 边界:                      C6.1 – C6.12');
}

void _print() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('# QA 单聊独立断言用例表');
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
