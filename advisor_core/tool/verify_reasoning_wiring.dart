/// 正文元叙述剥离「**接线存在性**」回归验证（纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_core && dart run tool/verify_reasoning_wiring.dart`
///
/// **背景（QA 发现的 F-1 缺陷）**：`ReasoningStripper` / `PresentedContent`
/// （`domain/reasoning.dart`）此前**只被单测直接调用**，应用层零调用点——
/// "函数正确" ≠ "函数被调用"，纯函数单测必然绿，接线缺失只有全仓扫描 / E2E 能暴露。
///
/// 本脚本是本缺陷的**回归防线**：只测**端到端接线**——用假 LLM 返回「段首元叙述 + 正文」，
/// 断言**落库的 `messages.content` 已剥离**（三条路径：单聊 / 群聊成员 / 群聊总结者）。
///
/// 断言设计（可区分「接线了」与「没接线」）：
/// 1. 先证明假 LLM 的**原始输出含元叙述**（`strip(raw) != raw`）——否则测试无区分力；
/// 2. 再断言**落库内容**既**不含**元叙述、又**保留**真实正文。
///
/// ⚠️ 本脚本**不得 import `app/` 任何东西**（纯 core）。
library;

import 'dart:async';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（与 verify_round6 同款）
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
// 假 LLM：一律以「段首元叙述 + 正文」作答（模拟模型把思考混进正文）
// ---------------------------------------------------------------------------

/// 元叙述句（**必须被剥离**）。
const String kMetaLine = '让我想想。';

/// 总结者元叙述句（**必须被剥离**）。
const String kSummaryMetaLine = '让我先梳理一下。';

/// 单聊真实正文锚点（**必须保留**）。
const String kSingleBodyAnchor = '单聊可交付的正文';

/// 群成员真实正文锚点（**必须保留**）。
const String kGroupBodyAnchor = '可交付正文';

/// 总结者真实正文锚点（**必须保留**）。
const String kSummaryBodyAnchor = '本轮达成共识 A';

class WiringLlm implements LlmProvider {
  final List<ChatRequest> calls = [];
  int _n = 0;

  @override
  String get providerId => 'pp_test';

  @override
  Future<List<ModelDescriptor>> listModels() async =>
      const [ModelDescriptor(modelId: 'test-chat')];

  @override
  Future<ChatResponse> chat(ChatRequest request) async =>
      ChatResponse(content: respond(request), promptTokens: 5, completionTokens: 5);

  @override
  Stream<StreamEvent> stream(ChatRequest request) async* {
    calls.add(request);
    yield TokenDelta(respond(request));
    yield const UsageEvent(5, 5);
    yield const StreamDone();
  }

  /// 生成假答复（同一逻辑供 chat / stream 复用，便于断言前先看原文）。
  String respond(ChatRequest request) {
    final all = request.messages.map((m) => m.content).join('\n');
    // 总结者调用：system 含「只输出 JSON」（Summarizer.buildPrompt 写死）。
    // 返回**非 JSON**（退化路径）——`fromModelText` 会把整段放进 recommendations，
    // 于是「元叙述是否被剥离」在最终 summary markdown 里直接可见。
    if (all.contains('只输出 JSON')) {
      return '$kSummaryMetaLine\n结论：$kSummaryBodyAnchor。';
    }
    final name = _expertName(all);
    _n++;
    if (name.isEmpty) {
      // 单聊（无 roleBlock 的「」）→ 固定正文。
      return '$kMetaLine\n$kSingleBodyAnchor$_n：$_n$_n。';
    }
    // 群成员：名字 + 序号生成近唯一 token，躲开去重 0.82 阈值。
    final distinct = List.generate(8, (i) => '$name$_n$i').join('，');
    return '$kMetaLine\n【$name】$kGroupBodyAnchor$_n：$distinct。';
  }

  /// 取 system 中**首个**「…」内的名字（roleBlock 里「你是本群组长/组员「X」」的 X）。
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
// Harness（含单聊 GenerationService + 群聊 GroupService）
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
    generation = GenerationService(
      repos,
      experts: experts,
      conversations: conversations,
      knowledge: knowledge,
      llmFactory: (_) => llm,
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
  late final GenerationService generation;
  late final GroupService group;

  WiringLlm get wiringLlm => llm as WiringLlm;

  /// 注册内置 Provider + 默认模型 + 凭据（否则 gen.unconfigured）。
  Future<void> bootstrapProvider() async {
    await providers.registerBuiltins();
    await credentials.saveDefault(
      apiKey: 'sk-test-not-a-real-key',
      providerProfileId: ProviderService.deepseekProviderId,
    );
  }
}

/// 跑一次单聊（消费完整事件流）。
Future<List<GenerationUpdate>> runSingle(
  Harness h, {
  required String conversationId,
  required String userText,
}) async {
  final msg = await h.conversations.appendUserMessage(conversationId, userText);
  final out = <GenerationUpdate>[];
  await for (final u in h.generation.runSingleChat(
    conversationId: conversationId,
    userMessageId: msg.id,
    userText: userText,
  )) {
    out.add(u);
  }
  return out;
}

/// 跑一次群聊（消费完整事件流）。
Future<List<GenerationUpdate>> runGroup(
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

/// 取会话内**最后一条**专家消息。
Future<Message?> lastExpertMessage(Harness h, String conversationId) async {
  final msgs = await h.repos.messages.listMessages(conversationId);
  final experts = msgs.where((m) => m.isFromExpert).toList();
  return experts.isEmpty ? null : experts.last;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 正文元叙述剥离「接线存在性」回归（F-1）');
  stdout.writeln('=' * 64);

  SpeakingStrategies.registerBuiltins();

  await _verifyDiscriminatingPower();
  await _verifySingleChatWiring();
  await _verifyGroupMemberWiring();
  await _verifyGroupSummaryWiring();

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
// 0. 区分力自证：假 LLM 原文确实含元叙述（否则"已剥离"断言可能是巧合）
// ---------------------------------------------------------------------------

Future<void> _verifyDiscriminatingPower() async {
  section('0. 区分力自证（假 LLM 原文含元叙述，strip 确有改变）');

  final llm = WiringLlm();
  final singleRaw =
      llm.respond(ChatRequest(model: 'm', messages: [const ChatMessage(ChatRole.system, '你是助手。')]));
  final memberRaw = llm.respond(ChatRequest(
    model: 'm',
    messages: [const ChatMessage(ChatRole.system, '你是本群组员「张三」。')],
  ));
  final summaryRaw = llm.respond(ChatRequest(
    model: 'm',
    messages: [const ChatMessage(ChatRole.system, '你是严谨的讨论主持人，只输出 JSON。')],
  ));

  check('单聊原文含元叙述', singleRaw.contains(kMetaLine), 'raw=$singleRaw');
  check('群成员原文含元叙述', memberRaw.contains(kMetaLine), 'raw=$memberRaw');
  check('总结者原文含元叙述', summaryRaw.contains(kSummaryMetaLine), 'raw=$summaryRaw');

  check('strip(single) 确有改变', ReasoningStripper.strip(singleRaw).text != singleRaw);
  check('strip(member) 确有改变', ReasoningStripper.strip(memberRaw).text != memberRaw);
  check('strip(summary) 确有改变', ReasoningStripper.strip(summaryRaw).text != summaryRaw);

  check('strip 后单聊不含元叙述',
      !ReasoningStripper.strip(singleRaw).text.contains(kMetaLine));
  check('strip 后单聊保留正文', ReasoningStripper.strip(singleRaw).text.contains(kSingleBodyAnchor));
}

// ---------------------------------------------------------------------------
// 1. 单聊端到端接线
// ---------------------------------------------------------------------------

Future<void> _verifySingleChatWiring() async {
  section('1. 单聊：落库 messages.content 已剥离（端到端接线）');

  final repos = inMemoryRepositories();
  final llm = WiringLlm();
  final h = Harness(repos, llm);
  await h.bootstrapProvider();

  final expert = await h.experts.createLocal(name: '单聊助手', systemPrompt: '你是单聊助手。');
  final conv = await h.conversations.createSingle(expert.id);

  final updates = await runSingle(h, conversationId: conv.id, userText: '帮我分析一下');
  final finished = updates.whereType<RunFinishedUpdate>().firstOrNull;
  check('单聊运行完成', finished != null);

  final stored = await lastExpertMessage(h, conv.id);
  check('存在专家落库消息', stored != null);
  final content = stored!.content;
  check('落库正文**不含**元叙述', !content.contains(kMetaLine), 'content=${_esc(content)}');
  check('落库正文**保留**真实内容', content.contains(kSingleBodyAnchor), 'content=${_esc(content)}');
  // 交付展示（StepFinishedUpdate.content）同样须为剥离后文本。
  final sfu = updates.whereType<StepFinishedUpdate>().firstOrNull;
  check('交付的 StepFinishedUpdate 不含元叙述',
      sfu != null && !sfu.content.contains(kMetaLine));
}

// ---------------------------------------------------------------------------
// 2. 群聊成员端到端接线
// ---------------------------------------------------------------------------

Future<void> _verifyGroupMemberWiring() async {
  section('2. 群聊成员：落库 messages.content 已剥离（端到端接线）');

  final repos = inMemoryRepositories();
  final llm = WiringLlm();
  final h = Harness(repos, llm);
  await h.bootstrapProvider();

  final leader = await h.experts.createLocal(name: '组长', systemPrompt: '你是本群负责人。');
  final law = await h.experts.createLocal(name: '法律顾问', systemPrompt: '你是法律顾问。');
  await h.experts.setTags(leader.id, ['综合管理']);
  await h.experts.setTags(law.id, ['法律', '合同', '条款']);

  final group = await h.conversations.createGroup(
    title: '顾问团',
    expertIds: [leader.id, law.id],
    speakStrategy: 'leader_led',
    leaderExpertId: leader.id,
  );

  final updates = await runGroup(h, conversationId: group.id, userText: '这份合同的条款风险怎么审');
  final finished = updates.whereType<RunFinishedUpdate>().firstOrNull;
  check('群聊运行完成', finished != null);
  check('至少 1 位成员发言', updates.whereType<StepFinishedUpdate>().any((u) => !u.skipped));

  final msgs = await h.repos.messages.listMessages(group.id);
  final memberMsgs = msgs.where((m) => m.isFromExpert).toList();
  check('存在群成员落库消息', memberMsgs.isNotEmpty);
  check('每位成员落库正文均**不含**元叙述',
      memberMsgs.every((m) => !m.content.contains(kMetaLine)),
      'contents=${memberMsgs.map((m) => _esc(m.content)).toList()}');
  check('至少一位成员落库正文**保留**真实内容',
      memberMsgs.any((m) => m.content.contains(kGroupBodyAnchor)));
}

// ---------------------------------------------------------------------------
// 3. 群聊总结者端到端接线
// ---------------------------------------------------------------------------

Future<void> _verifyGroupSummaryWiring() async {
  section('3. 群聊总结者：落库 messages.content 已剥离（端到端接线）');

  final repos = inMemoryRepositories();
  final llm = WiringLlm();
  final h = Harness(repos, llm);
  await h.bootstrapProvider();

  final leader = await h.experts.createLocal(name: '组长', systemPrompt: '你是本群负责人。');
  final law = await h.experts.createLocal(name: '法律顾问', systemPrompt: '你是法律顾问。');
  await h.experts.setTags(leader.id, ['综合管理']);
  await h.experts.setTags(law.id, ['法律', '合同', '条款']);

  final group = await h.conversations.createGroup(
    title: '顾问团',
    expertIds: [leader.id, law.id],
    speakStrategy: 'leader_led',
    leaderExpertId: leader.id,
  );

  final updates = await runGroup(h, conversationId: group.id, userText: '这份合同的条款风险怎么审');
  check('触发总结（accepted ≥ 2）', updates.whereType<SummaryUpdate>().isNotEmpty);

  final msgs = await h.repos.messages.listMessages(group.id);
  // 总结消息 = 含结构化 markdown 头部（**建议** / **共识**）的专家消息。
  final summaryMsg = msgs
      .where((m) => m.isFromExpert && (m.content.contains('**建议**') || m.content.contains('**共识**')))
      .firstOrNull;
  check('存在总结落库消息', summaryMsg != null, 'msgs=${msgs.map((m) => _esc(m.content)).toList()}');
  final s = summaryMsg!.content;
  check('总结落库正文**不含**元叙述', !s.contains(kSummaryMetaLine), 'content=${_esc(s)}');
  check('总结落库正文**保留**真实结论', s.contains(kSummaryBodyAnchor), 'content=${_esc(s)}');
}

/// 转义换行，便于失败明细阅读。
String _esc(String s) => s.replaceAll('\n', '\\n');
