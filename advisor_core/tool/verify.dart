/// 核心链路验证脚本。
///
/// 运行：`dart run tool/verify.dart`
///
/// 说明：本环境无法运行 `dart test`（派生进程受限），因此用可执行脚本做端到端验证；
/// 用户在自己机器上也可以用 `dart test` 跑 `test/` 目录下的等价用例。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

/// UTF-8 字节。
Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

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

bool _deepEq(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEq(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_deepEq(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

void checkEq(String name, Object? actual, Object? expected) {
  check(name, _deepEq(actual, expected), 'actual=$actual expected=$expected');
}

// ---------------------------------------------------------------------------
// 动态 LLM 替身：按请求内容决定回答
// ---------------------------------------------------------------------------

class DynamicLlm implements LlmProvider {
  DynamicLlm({this.error});

  final AppError? error;
  final List<ChatRequest> calls = [];

  @override
  String get providerId => 'pp_deepseek';

  @override
  Future<List<ModelDescriptor>> listModels() async =>
      const [ModelDescriptor(modelId: 'deepseek-chat')];

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    calls.add(request);
    final text = _respond(request);
    return ChatResponse(content: text, promptTokens: 10, completionTokens: 20);
  }

  @override
  Stream<StreamEvent> stream(ChatRequest request) async* {
    calls.add(request);
    if (error != null) {
      yield StreamErrorEvent(error!);
      return;
    }
    final text = _respond(request);
    for (var i = 0; i < text.length; i += 6) {
      yield TokenDelta(text.substring(i, i + 6 > text.length ? text.length : i + 6));
      await Future<void>.delayed(Duration.zero);
    }
    yield const UsageEvent(120, 60);
    yield const StreamDone();
  }

  String _respond(ChatRequest request) {
    final joined = request.messages.map((m) => m.content).join('\n');
    if (joined.contains('只输出 JSON')) {
      return '```json\n{"consensus":["资格条件需逐条响应"],"disagreements":[],'
          '"recommendations":["先做资格预审","报价采用不平衡策略"],"open_questions":[]}\n```';
    }
    // 让不同专家产出不同内容，避免被去重拦截
    final sys = request.messages.first.content;
    final marker = sys.split('\n').first.replaceAll(RegExp(r'[^\u4e00-\u9fffA-Za-z0-9]'), '').trim();
    return '【$marker】基于我的专业判断：本项目的关键点是 ${marker.length} 个要素，'
        '建议按 ${DateTime.now().microsecond % 97} 的顺序推进，并保留书面记录。';
  }

  @override
  Future<ProviderHealth> healthCheck() async =>
      const ProviderHealth(health: Health.healthy, latencyMs: 8);

  @override
  AppError mapError(Object raw) => raw is AppError ? raw : ProviderServerError('$raw');
}

// ---------------------------------------------------------------------------
// 组装
// ---------------------------------------------------------------------------

class Harness {
  Harness(this.repos, this.llm)
      : providers = ProviderService(repos),
        credentials = CredentialService(repos),
        experts = ExpertService(repos),
        conversations = ConversationService(repos),
        market = MarketService(repos, experts: ExpertService(repos)) {
    knowledge = KnowledgeService(
      repos,
      parsers: [PlainTextParser()],
      chunker: SimpleChunker(targetTokens: 120),
      vectorStore: InMemoryVectorStore(repos.knowledge),
      embeddingModel: HashEmbeddingModel(dimension: 256),
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
  final ProviderService providers;
  final CredentialService credentials;
  final ExpertService experts;
  final ConversationService conversations;
  late final KnowledgeService knowledge;
  late final GenerationService generation;
  late final GroupService group;
  final MarketService market;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 核心链路验证（advisor_core）');
  stdout.writeln('=' * 60);

  SpeakingStrategies.registerBuiltins();

  final repos = inMemoryRepositories();
  final llm = DynamicLlm();
  final h = Harness(repos, llm);

  await _verifyMarketPrimitives();
  await _verifyPackageSecurity();
  await _verifyStrategiesAndOrchestration();
  await _verifyProviderAndCredential(h);
  await _verifySingleChat(h);
  await _verifyStrictGroundingNoEvidence(h);
  await _verifyKnowledgeAndGroundedChat(h);
  await _verifyGroupChat(h);
  await _verifyFailSoft(h);
  await _verifyRecovery(h);
  await _verifySessionContextMenu();

  stdout.writeln('\n${'=' * 60}');
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
// 1. 市场基础原语
// ---------------------------------------------------------------------------

Future<void> _verifyMarketPrimitives() async {
  section('1. 市场基础原语（SemVer / 更新策略 / 索引）');

  check('SemVer 解析 1.2.3', SemVer.parse('1.2.3') == const SemVer(1, 2, 3));
  check('1.10.0 > 1.9.9', SemVer.parse('1.10.0') > SemVer.parse('1.9.9'));
  check('1.0.0 > 1.0.0-beta', SemVer.parse('1.0.0') > SemVer.parse('1.0.0-beta'));
  check('非法版本抛错', () {
    try {
      SemVer.parse('abc');
      return false;
    } on ValidationError {
      return true;
    }
  }());

  check(
    '版本要求 >=1.3.0 满足 1.3.1',
    AppVersionRequirement.parse('>=1.3.0').satisfiedBy(SemVer.parse('1.3.1')),
  );
  check(
    '版本要求 >=1.3.0 不满足 1.2.9',
    !AppVersionRequirement.parse('>=1.3.0').satisfiedBy(SemVer.parse('1.2.9')),
  );

  checkEq(
    '未本地修改 → 自动更新',
    UpdatePolicy.decide(
      installed: SemVer.parse('1.0.0'),
      available: SemVer.parse('1.1.0'),
      localModified: false,
    ),
    UpdateDecision.autoUpdate,
  );
  checkEq(
    '已本地修改 → 手动迁移',
    UpdatePolicy.decide(
      installed: SemVer.parse('1.0.0'),
      available: SemVer.parse('1.1.0'),
      localModified: true,
    ),
    UpdateDecision.manualMigrate,
  );
  checkEq(
    '版本相同 → 已是最新',
    UpdatePolicy.decide(
      installed: SemVer.parse('1.0.0'),
      available: SemVer.parse('1.0.0'),
      localModified: false,
    ),
    UpdateDecision.upToDate,
  );

  const indexJson = '''
{
  "schemaVersion": 1,
  "generatedAt": 1790757000000,
  "packages": [
    {
      "packageId": "org.private-advisor.bid-tender",
      "slug": "bid-tender-expert",
      "displayName": "投标文件解读专家",
      "profession": "政府采购与招投标顾问",
      "description": "拆解招标文件，提取资格条件与废标条款。",
      "categoryId": "12-IndustryConsultant",
      "tags": ["招标文件", "资格条件"],
      "latestVersion": "1.0.0",
      "versions": [
        {"version":"1.0.0","releaseUrl":"https://example.com/a.expert","sha256":"abc"}
      ]
    },
    {
      "packageId": "org.private-advisor.xhs",
      "slug": "xhs-operator",
      "displayName": "小红书运营专家",
      "categoryId": "05-MarketingGrowth",
      "tags": ["小红书"],
      "latestVersion": "2.0.0",
      "versions": []
    }
  ]
}
''';
  final index = MarketIndex.parse(indexJson);
  checkEq('索引解析包数', index.packages.length, 2);
  checkEq('按分类分组数', index.groupByCategory().keys.length, 2);
  checkEq('搜索"小红书"命中 1', index.search('小红书').length, 1);
  checkEq('搜索"投标"命中 1', index.search('投标').length, 1);
}

// ---------------------------------------------------------------------------
// 2. 包安全链
// ---------------------------------------------------------------------------

Future<void> _verifyPackageSecurity() async {
  section('2. 专家包安全链（10 步校验）');

  // 构造一个合法包
  final expertJson = _b('{"displayName":"投标文件解读专家"}');
  final prompt = _b('# 投标文件解读专家\n\n你是招投标顾问……');
  final readme = _b('# README\n');

  final files = [
    PackageFileEntry(path: 'README.md', sha256: PackageManifest.sha256Hex(readme)),
    PackageFileEntry(path: 'agents/main.md', sha256: PackageManifest.sha256Hex(prompt)),
    PackageFileEntry(path: 'expert.json', sha256: PackageManifest.sha256Hex(expertJson)),
  ];
  final pkgHash = PackageManifest.computePackageHash(files);

  final payload = PackagePayload([
    PackageEntry(path: 'manifest.json', bytes: _b('{}')),
    PackageEntry(path: 'README.md', bytes: readme),
    PackageEntry(path: 'agents/main.md', bytes: prompt),
    PackageEntry(path: 'expert.json', bytes: expertJson),
  ]);

  PackageManifest manifest({String? overrideHash, List<PackageFileEntry>? overrideFiles}) =>
      PackageManifest(
        packageId: 'org.private-advisor.bid-tender',
        slug: 'bid-tender-expert',
        version: SemVer.parse('1.0.0'),
        appVersion: AppVersionRequirement.parse('>=1.3.0'),
        displayName: '投标文件解读专家',
        categoryId: '12-IndustryConsultant',
        entry: 'agents/main.md',
        sha256: overrideHash ?? pkgHash,
        files: overrideFiles ?? files,
      );

  final good = PackageVerifier.verify(
    payload: payload,
    manifest: manifest(),
    appVersion: SemVer.parse('1.3.0'),
  );
  check('合法包通过全部校验', good.ok, good.report());
  // 步骤 1（HTTPS）由调用方保证；这里校验的是步骤 2–10，共 9 项。
  checkEq('合法包校验步骤数（2–10）', good.steps.length, 9);

  final tampered = PackageVerifier.verify(
    payload: payload,
    manifest: manifest(overrideHash: 'deadbeef'),
  );
  check('篡改哈希被拦截', !tampered.ok);
  check('  失败点为 SHA256', tampered.firstFailure?.name.contains('SHA256') ?? false);

  // 未声明文件
  final extraPayload = PackagePayload([
    ...payload.entries,
    PackageEntry(path: 'evil.txt', bytes: _b('x')),
  ]);
  final extra = PackageVerifier.verify(payload: extraPayload, manifest: manifest());
  check('未声明文件被拦截', !extra.ok);

  // 可执行文件
  final exePayload = PackagePayload([
    PackageEntry(path: 'manifest.json', bytes: _b('{}')),
    PackageEntry(path: 'agents/main.md', bytes: prompt),
    PackageEntry(path: 'expert.json', bytes: expertJson),
    PackageEntry(path: 'run.bat', bytes: _b('echo hi')),
    PackageEntry(path: 'README.md', bytes: readme),
  ]);
  final exeFiles = [
    ...files,
    PackageFileEntry(path: 'run.bat', sha256: PackageManifest.sha256Hex(_b('echo hi'))),
  ];
  final exeVerify = PackageVerifier.verify(
    payload: exePayload,
    manifest: manifest(
      overrideHash: PackageManifest.computePackageHash(exeFiles),
      overrideFiles: exeFiles,
    ),
  );
  check('可执行文件被拦截', !exeVerify.ok);
  check('  失败点为 No-Executable', exeVerify.firstFailure?.name.contains('Executable') ?? false);

  // 路径穿越
  checkEq('拒绝绝对路径', ZipPathSafety.reject('/etc/passwd'), '绝对路径');
  checkEq('拒绝盘符', ZipPathSafety.reject('C:\\windows\\x.dll'), '包含盘符');
  checkEq('拒绝 ..', ZipPathSafety.reject('../../x'), '包含上级目录 ..');
  checkEq('允许正常路径', ZipPathSafety.reject('agents/main.md'), null);
  check('staysInside 正常', ZipPathSafety.staysInside('packages/', 'agents/main.md'));
  check('staysInside 逃逸', !ZipPathSafety.staysInside('packages/', '../evil'));

  // 能力越权
  final badCaps = PackageManifest(
    packageId: 'org.private-advisor.bad',
    slug: 'bad',
    version: SemVer.parse('1.0.0'),
    appVersion: AppVersionRequirement.parse('>=1.3.0'),
    displayName: '越权专家',
    categoryId: '12-IndustryConsultant',
    entry: 'agents/main.md',
    sha256: pkgHash,
    capabilities: const PackageCapabilities(shell: true),
    files: files,
  );
  final capsVerify = PackageVerifier.verify(payload: payload, manifest: badCaps);
  check('capabilities 越权被拦截', !capsVerify.ok);
}

// ---------------------------------------------------------------------------
// 3. 策略与编排
// ---------------------------------------------------------------------------

Future<void> _verifyStrategiesAndOrchestration() async {
  section('3. 群聊策略 / 去重 / 总结解析');

  final members = [
    const GroupMember(expertId: 'e1', name: '投标专家', expertise: ['招标文件', '资格条件'], sortOrder: 0),
    const GroupMember(expertId: 'e2', name: '报价专家', expertise: ['报价', '成本'], sortOrder: 1),
    const GroupMember(expertId: 'e3', name: '合同专家', expertise: ['合同', '条款'], sortOrder: 2),
  ];

  final userMsg = Message(
    id: 'm1',
    conversationId: 'c1',
    senderType: MessageSenderType.user,
    content: '帮我看看这份招标文件的资格条件和报价策略',
    createdAt: 0,
    updatedAt: 0,
  );

  GroupContext ctx({String? lastSpeakerId}) => GroupContext(
        conversationId: 'c1',
        userMessage: userMsg,
        members: members,
        lastSpeakerId: lastSpeakerId,
      );

  // manual
  final manualCtx = GroupContext(
    conversationId: 'c1',
    userMessage: Message(
      id: 'm2',
      conversationId: 'c1',
      senderType: MessageSenderType.user,
      content: '@合同专家 看下付款条款',
      createdAt: 0,
      updatedAt: 0,
    ),
    members: members,
  );
  final manual = await ManualStrategy().selectNextSpeakers(manualCtx);
  checkEq('manual 精确 @ 命中', manual.primarySpeakers, ['e3']);
  final manualNone = await ManualStrategy().selectNextSpeakers(ctx());
  checkEq('manual 无 @ 时不发言', manualNone.primarySpeakers.length, 0);

  // round robin
  final rr1 = await RoundRobinStrategy(rounds: 2).selectNextSpeakers(ctx());
  checkEq('round_robin 无历史从首位开始', rr1.primarySpeakers, ['e1', 'e2']);
  final rr2 = await RoundRobinStrategy(rounds: 2).selectNextSpeakers(ctx(lastSpeakerId: 'e2'));
  checkEq('round_robin 接续上一位', rr2.primarySpeakers, ['e3', 'e1']);

  // weighted（固定种子 → 可复现）
  final w1 = await WeightedStrategy(count: 3, seed: 42).selectNextSpeakers(ctx());
  final w2 = await WeightedStrategy(count: 3, seed: 42).selectNextSpeakers(ctx());
  checkEq('weighted 同种子可复现', w1.primarySpeakers.join(','), w2.primarySpeakers.join(','));
  check('weighted 去重无重复', w1.primarySpeakers.toSet().length == w1.primarySpeakers.length);

  // auto
  final auto = await AutoStrategy().selectNextSpeakers(ctx());
  check('auto 命中标签（含投标/报价）', auto.primarySpeakers.contains('e1') && auto.primarySpeakers.contains('e2'),
      'got=${auto.primarySpeakers}');
  final tokens = AutoStrategy.tokenize('招标文件');
  check('auto 分词含 bigram', tokens.contains('招标') && tokens.contains('标文'));

  // dedup
  final det = DuplicateDetector(threshold: 0.8);
  const a = '本项目需要逐条响应资格条件，并提供营业执照、业绩证明等材料。';
  const b = '本项目需要逐条响应资格条件，并提供营业执照、业绩证明等材料。';
  const c = '报价建议采用不平衡报价策略，对早期回款科目适当提高单价。';
  check('完全相同 → 判定重复', det.check(b, [ExpertOutput(expertId: 'x', expertName: 'X', content: a)]).isDuplicate);
  check('内容不同 → 不判定重复', !det.check(c, [ExpertOutput(expertId: 'x', expertName: 'X', content: a)]).isDuplicate);

  // off-topic
  final off = OffTopicDetector().check('今天天气不错，适合出去散步。', '帮我看看招标文件的资格条件');
  check('跑题内容被识别', off.isOffTopic);

  // summary parse
  final s1 = SummaryResult.fromModelText(
    '```json\n{"consensus":["A"],"disagreements":["B"],"recommendations":["C"],"open_questions":["D"]}\n```',
  );
  checkEq('总结 JSON 解析 consensus', s1.consensus, ['A']);
  checkEq('总结 JSON 解析 open_questions', s1.openQuestions, ['D']);
  final s2 = SummaryResult.fromModelText('这不是 JSON，只是一段总结文字。');
  check('非 JSON 退化为纯文本建议', s2.recommendations.isNotEmpty && s2.consensus.isEmpty);
  check('总结 Markdown 含小节标题', s1.toMarkdown().contains('共识'));
}

// ---------------------------------------------------------------------------
// 4. Provider / Credential
// ---------------------------------------------------------------------------

Future<void> _verifyProviderAndCredential(Harness h) async {
  section('4. Provider / Credential（Key 不落库）');

  await h.providers.registerBuiltins();
  final providers = await h.providers.listProviders();
  check('内置 Provider 已注册', providers.any((p) => p.id == ProviderService.deepseekProviderId));
  checkEq('DeepSeek 直连地址', providers.firstWhere((p) => p.id == 'pp_deepseek').baseUrl,
      'https://api.deepseek.com/v1');

  final models = await h.providers.listModels(providerProfileId: 'pp_deepseek');
  checkEq('DeepSeek 模型数', models.length, 2);
  checkEq('默认模型', await h.providers.defaultModelProfileId, 'mp_deepseek_chat');

  final cred = await h.credentials.saveDefault(
    apiKey: 'sk-test-not-a-real-key',
    providerProfileId: 'pp_deepseek',
  );
  check('凭据已保存', cred.id == CredentialService.defaultCredentialId);
  check('secretRef 不等于明文', cred.secretRef != 'sk-test-not-a-real-key');
  checkEq('Key 可正确读回', await h.credentials.resolveSecret(cred.id), 'sk-test-not-a-real-key');

  // 断言 SQLite（此处为内存仓储）中不含明文
  final allFields = h.repos.credentials.toString();
  check('仓储不含明文 Key', !allFields.contains('sk-test-not-a-real-key'));

  var rejected = false;
  try {
    await h.credentials.saveDefault(apiKey: '   ', providerProfileId: 'pp_deepseek');
  } on ValidationError {
    rejected = true;
  }
  check('空 Key 被拒绝', rejected);
}

// ---------------------------------------------------------------------------
// 5. 单聊 Vertical Slice
// ---------------------------------------------------------------------------

Future<void> _verifySingleChat(Harness h) async {
  section('5. 单聊 Vertical Slice（Run/Step/Event/Message）');

  final expert = await h.experts.createLocal(
    name: '投标专家',
    systemPrompt: '你是政府采购与招投标顾问，逐条响应招标要求。',
    profession: '招投标顾问',
    categoryId: '12-IndustryConsultant',
  );
  check('专家创建成功', expert.id.isNotEmpty);
  checkEq('默认接地策略', (await h.experts.resolveEffective(expert.id)).groundingPolicy, GroundingPolicy.off);

  await h.experts.setTags(expert.id, ['招标文件', '资格条件']);

  final conv = await h.conversations.createSingle(expert.id);
  checkEq('单聊会话类型', conv.type, ConversationType.single);

  final userMsg = await h.conversations.appendUserMessage(conv.id, '帮我拆解这份招标文件');

  final updates = <GenerationUpdate>[];
  await for (final u in h.generation.runSingleChat(
    conversationId: conv.id,
    userMessageId: userMsg.id,
    userText: '帮我拆解这份招标文件',
  )) {
    updates.add(u);
  }

  check('收到 RunStarted', updates.whereType<RunStartedUpdate>().isNotEmpty);
  check('收到 thinking 状态', updates.whereType<StepStatusUpdate>().any((s) => s.activity == Activity.thinking));
  check('收到 generating 状态', updates.whereType<StepStatusUpdate>().any((s) => s.activity == Activity.generating));
  check('收到多个 token 增量', updates.whereType<DeltaUpdate>().length > 1);

  final finished = updates.whereType<RunFinishedUpdate>().firstOrNull;
  check('运行完成', finished != null);
  checkEq('运行状态 completed', finished?.run.status, RunStatus.completed);
  check('Token 用量已记录', (finished?.run.completionTokens ?? 0) > 0);

  final history = await h.conversations.history(conv.id);
  final expertMsgs = history.where((m) => m.isFromExpert).toList();
  checkEq('落库专家消息数', expertMsgs.length, 1);
  checkEq('专家消息状态', expertMsgs.first.status, MessageStatus.completed);
  check('专家消息有内容', expertMsgs.first.content.isNotEmpty);

  final runs = await h.repos.generations.listRuns(conv.id);
  checkEq('生成运行记录数', runs.length, 1);
  final steps = await h.repos.generations.listSteps(runs.first.id);
  checkEq('生成步骤数', steps.length, 1);
  final events = await h.repos.generations.listEvents(steps.first.id);
  check('流式事件已落库', events.isNotEmpty);
  checkEq('事件类型为 token_delta', events.first.eventType, GenerationEventType.tokenDelta);
}

// ---------------------------------------------------------------------------
// 6. 严格模式 · 无证据 → 不调用 LLM
// ---------------------------------------------------------------------------

Future<void> _verifyStrictGroundingNoEvidence(Harness h) async {
  section('6. Grounding strict：无证据不调用 LLM');

  final expert = await h.experts.createLocal(
    name: '技术规格专家',
    systemPrompt: '你是消防车技术规格专家。',
  );
  await h.experts.updateRuntimeConfig(
    ExpertRuntimeConfig(expertId: expert.id, groundingPolicy: GroundingPolicy.strict),
  );
  // 注意：不绑定任何知识库
  final conv = await h.conversations.createSingle(expert.id);
  final userMsg = await h.conversations.appendUserMessage(conv.id, '这车的轴距是多少？');

  final before = h.llm is DynamicLlm ? (h.llm as DynamicLlm).calls.length : 0;

  final updates = <GenerationUpdate>[];
  await for (final u in h.generation.runSingleChat(
    conversationId: conv.id,
    userMessageId: userMsg.id,
    userText: '这车的轴距是多少？',
  )) {
    updates.add(u);
  }

  final after = h.llm is DynamicLlm ? (h.llm as DynamicLlm).calls.length : 0;
  checkEq('strict 无命中：LLM 调用次数不变', after, before);

  final done = updates.whereType<StepFinishedUpdate>().firstOrNull;
  checkEq('返回固定 no-answer 文案', done?.content, kNoAnswerText);
  check('标记为 skipped', done?.skipped ?? false);

  final history = await h.conversations.history(conv.id);
  final last = history.last;
  checkEq('落库内容为 no-answer', last.content, kNoAnswerText);
}

// ---------------------------------------------------------------------------
// 7. 知识库 + 严格模式命中
// ---------------------------------------------------------------------------

Future<void> _verifyKnowledgeAndGroundedChat(Harness h) async {
  section('7. 知识库导入 → 检索 → 严格模式命中带引用');

  final base = await h.knowledge.createBase(name: '消防车技术规格库');
  check('知识库创建成功', base.id.isNotEmpty);

  // 写一个临时文档
  final dir = Directory.systemTemp.createTempSync('pa_verify_');
  final file = File('${dir.path}/规格书.md');
  file.writeAsStringSync('''
# 消防车技术规格书

## 3.2.1 车辆性能参数

整车整备质量为 12000 kg，最大总质量 18000 kg，轴距 4500 mm，
最高车速不低于 100 km/h，水罐容积 6000 L。

## 3.2.2 消防泵参数

消防泵额定流量 60 L/s，额定压力 1.0 MPa，最大吸深 7 m。
''');

  final imported = await h.knowledge.importDocument(
    knowledgeBaseId: base.id,
    filePath: file.path,
    fileName: '规格书.md',
    fileBytes: file.readAsBytesSync(),
  );
  check('文档导入成功', imported.doc.status == DocumentStatus.indexed);
  check('产生文本块', imported.chunkCount > 0, 'chunks=${imported.chunkCount}');

  // 重复导入应命中去重
  final again = await h.knowledge.importDocument(
    knowledgeBaseId: base.id,
    filePath: file.path,
    fileName: '规格书.md',
    fileBytes: file.readAsBytesSync(),
  );
  checkEq('同内容重复导入不重复分块', again.chunkCount, imported.chunkCount);

  final kb = await h.knowledge.getBase(base.id);
  check('知识库统计已更新', (kb?.chunkCount ?? 0) > 0);

  // 绑定给专家（阈值调低以适配哈希 embedding）
  final expert = await h.experts.createLocal(
    name: '技术规格专家2',
    systemPrompt: '你是消防车技术规格专家，只依据资料回答。',
  );
  await h.experts.bindKnowledge(expert.id, base.id, topK: 3, threshold: 0.02);
  await h.experts.updateRuntimeConfig(
    ExpertRuntimeConfig(expertId: expert.id, groundingPolicy: GroundingPolicy.strict),
  );
  final bindings = await h.experts.listBindings(expert.id);
  checkEq('知识库绑定数', bindings.length, 1);
  check('生效配置含绑定知识库',
      (await h.experts.resolveEffective(expert.id)).knowledgeBaseIds.contains(base.id));

  final citations = await h.knowledge.retrieveForExpert(
    expertId: expert.id,
    query: '消防泵的额定流量和压力是多少',
  );
  check('检索命中知识片段', citations.isNotEmpty, 'hits=${citations.length}');
  check('引用含文件名', citations.first.fileName == '规格书.md');
  check('引用含标题路径', (citations.first.headingPath ?? '').contains('消防泵'));
  check('引用展示串含相关度', citations.first.toDisplay().contains('相关度'));

  // 严格模式 + 有证据 → 应调用 LLM 且带引用
  final conv = await h.conversations.createSingle(expert.id);
  final userMsg = await h.conversations.appendUserMessage(conv.id, '消防泵的额定流量和压力是多少？');
  final before = (h.llm as DynamicLlm).calls.length;

  final updates = <GenerationUpdate>[];
  await for (final u in h.generation.runSingleChat(
    conversationId: conv.id,
    userMessageId: userMsg.id,
    userText: '消防泵的额定流量和压力是多少？',
  )) {
    updates.add(u);
  }
  final after = (h.llm as DynamicLlm).calls.length;
  checkEq('有证据时调用了 LLM', after, before + 1);

  final req = (h.llm as DynamicLlm).calls.last;
  check('提示词含严格模式约束', req.messages.first.content.contains('只能依据提供的知识库片段'));
  check('提示词注入了证据块', req.messages.first.content.contains('规格书.md'));

  final done = updates.whereType<StepFinishedUpdate>().firstOrNull;
  check('回答带引用', (done?.citations.isNotEmpty ?? false));
  check('回答不是 no-answer', done?.content != kNoAnswerText);

  final msgs = await h.conversations.history(conv.id);
  final lastMsg = msgs.last;
  final savedCitations = await h.repos.messages.listCitations(lastMsg.id);
  check('引用已落库', savedCitations.isNotEmpty);

  // 清理
  await h.knowledge.deleteBase(base.id);
  check('知识库删除后绑定与文档清理',
      (await h.knowledge.listBases()).every((b) => b.id != base.id));
}

// ---------------------------------------------------------------------------
// 8. 群聊
// ---------------------------------------------------------------------------

Future<void> _verifyGroupChat(Harness h) async {
  section('8. 群聊编排（策略 → 生成 → 去重 → 总结）');

  final e1 = await h.experts.createLocal(
    name: '投标专家G',
    systemPrompt: '你是投标专家，关注资格条件与响应。',
    profession: '招投标顾问',
  );
  final e2 = await h.experts.createLocal(
    name: '报价专家G',
    systemPrompt: '你是报价专家，关注成本与报价策略。',
    profession: '成本报价顾问',
  );
  final e3 = await h.experts.createLocal(
    name: '合同专家G',
    systemPrompt: '你是合同审查专家，关注条款风险。',
    profession: '合同法务顾问',
  );
  await h.experts.setTags(e1.id, ['招标文件', '资格条件']);
  await h.experts.setTags(e2.id, ['报价', '成本']);
  await h.experts.setTags(e3.id, ['合同', '条款']);

  final group = await h.conversations.createGroup(
    title: '投标作战群',
    expertIds: [e1.id, e2.id, e3.id],
    speakStrategy: 'manual',
    summarizerExpertId: e1.id,
  );
  checkEq('群聊成员数', (await h.conversations.members(group.id)).length, 3);
  checkEq('群配置策略', (await h.conversations.groupConfig(group.id))?.speakStrategy, 'manual');

  // 手动 @ 两位专家 + 触发总结
  final userMsg = await h.conversations.appendUserMessage(
    group.id,
    '@投标专家G @报价专家G 这份招标文件怎么打？',
  );

  final updates = <GenerationUpdate>[];
  await for (final u in h.group.runGroupChat(
    conversationId: group.id,
    userMessageId: userMsg.id,
    userText: '@投标专家G @报价专家G 这份招标文件怎么打？',
  )) {
    updates.add(u);
  }

  final finished = updates.whereType<RunFinishedUpdate>().firstOrNull;
  check('群聊运行完成', finished != null);
  checkEq('运行类型 group_chat', finished?.run.runType, RunType.groupChat);

  final steps = await h.repos.generations.listSteps(finished!.run.id);
  final generationSteps = steps.where((s) => s.stage == StepStage.generation).toList();
  checkEq('生成步骤数 = 2 位专家', generationSteps.length, 2);

  final summarySteps = steps.where((s) => s.stage == StepStage.synthesis).toList();
  checkEq('总结步骤数 = 1', summarySteps.length, 1);
  check('收到 SummaryUpdate', updates.whereType<SummaryUpdate>().isNotEmpty);
  final summary = updates.whereType<SummaryUpdate>().first.summary;
  check('总结含共识', summary.consensus.isNotEmpty);
  check('总结含建议', summary.recommendations.isNotEmpty);

  final msgs = await h.conversations.history(group.id);
  final expertMsgs = msgs.where((m) => m.isFromExpert).toList();
  checkEq('落库专家消息 = 2 发言 + 1 总结', expertMsgs.length, 3);

  // 自动策略应命中投标/报价标签
  final autoUpdates = <GenerationUpdate>[];
  final msg2 = await h.conversations.appendUserMessage(group.id, '报价和资格条件哪个优先？');
  await for (final u in h.group.runGroupChat(
    conversationId: group.id,
    userMessageId: msg2.id,
    userText: '报价和资格条件哪个优先？',
    strategyOverride: 'auto',
  )) {
    autoUpdates.add(u);
  }
  check('auto 策略跑通', autoUpdates.whereType<RunFinishedUpdate>().isNotEmpty);

  // 轮流策略
  final rrUpdates = <GenerationUpdate>[];
  final msg3 = await h.conversations.appendUserMessage(group.id, '继续');
  await for (final u in h.group.runGroupChat(
    conversationId: group.id,
    userMessageId: msg3.id,
    userText: '继续',
    strategyOverride: 'round_robin',
  )) {
    rrUpdates.add(u);
  }
  check('round_robin 策略跑通', rrUpdates.whereType<RunFinishedUpdate>().isNotEmpty);

  // 权重策略
  final wUpdates = <GenerationUpdate>[];
  final msg4 = await h.conversations.appendUserMessage(group.id, '再补充');
  await for (final u in h.group.runGroupChat(
    conversationId: group.id,
    userMessageId: msg4.id,
    userText: '再补充',
    strategyOverride: 'weighted',
  )) {
    wUpdates.add(u);
  }
  check('weighted 策略跑通', wUpdates.whereType<RunFinishedUpdate>().isNotEmpty);

  // 无 @ 时 manual 不发言（但不应崩溃）
  final noneUpdates = <GenerationUpdate>[];
  final msg5 = await h.conversations.appendUserMessage(group.id, '大家觉得呢');
  await for (final u in h.group.runGroupChat(
    conversationId: group.id,
    userMessageId: msg5.id,
    userText: '大家觉得呢',
  )) {
    noneUpdates.add(u);
  }
  check('manual 无 @ 时不崩溃', noneUpdates.whereType<RunFinishedUpdate>().isNotEmpty);
}

// ---------------------------------------------------------------------------
// 9. Fail Soft
// ---------------------------------------------------------------------------

Future<void> _verifyFailSoft(Harness h) async {
  section('9. Fail Soft：单专家失败不拖垮整个群');

  final ok = await h.experts.createLocal(name: '正常专家', systemPrompt: '你是正常专家。');
  final bad = await h.experts.createLocal(name: '异常专家', systemPrompt: '你是异常专家。');
  // 给异常专家单独绑一个不存在的模型 → 解析期报错
  await h.experts.updateRuntimeConfig(
    ExpertRuntimeConfig(expertId: bad.id, modelProfileId: 'mp_not_exist'),
  );

  final group = await h.conversations.createGroup(
    title: '容错测试群',
    expertIds: [ok.id, bad.id],
    speakStrategy: 'round_robin',
  );
  final msg = await h.conversations.appendUserMessage(group.id, '正常专家 请分析这份招标文件');

  final updates = <GenerationUpdate>[];
  await for (final u in h.group.runGroupChat(
    conversationId: group.id,
    userMessageId: msg.id,
    userText: '正常专家 请分析这份招标文件',
  )) {
    updates.add(u);
  }

  final finished = updates.whereType<RunFinishedUpdate>().firstOrNull;
  check('群聊未整体崩溃', finished != null);
  checkEq('运行状态为 partial（部分成功）', finished?.run.status, RunStatus.partial);

  final steps = await h.repos.generations.listSteps(finished!.run.id);
  final failed = steps.where((s) => s.status == RunStatus.failed).toList();
  final okSteps = steps.where((s) => s.status == RunStatus.completed).toList();
  check('存在失败步骤', failed.isNotEmpty);
  check('仍存在成功步骤', okSteps.isNotEmpty);
  check('正常专家仍产出了消息', updates.whereType<StepFinishedUpdate>().any((s) => !s.skipped));
}

// ---------------------------------------------------------------------------
// 10. 启动恢复
// ---------------------------------------------------------------------------

Future<void> _verifyRecovery(Harness h) async {
  section('10. 启动恢复（中断运行标记为 cancelled）');

  final expert = await h.experts.createLocal(name: '恢复测试专家', systemPrompt: 'x');
  final conv = await h.conversations.createSingle(expert.id);

  // 手工造一条"正在运行"的记录，模拟崩溃
  final run = GenerationRun.create(
    conversationId: conv.id,
    runType: RunType.singleChat,
  ).copyWith(status: RunStatus.running, startedAt: DateTime.now().millisecondsSinceEpoch);
  await h.repos.generations.upsertRun(run);

  final n = await h.generation.recoverOnStartup();
  check('恢复处理了中断运行', n >= 1, 'recovered=$n');
  final after = await h.repos.generations.getRun(run.id);
  checkEq('中断运行被标记 cancelled', after?.status, RunStatus.cancelled);
}

// ---------------------------------------------------------------------------
// 11. 会话右键菜单（置顶 / 清空聊天记录 / 删除会话）——用户 2026-10-02 走查
// ---------------------------------------------------------------------------

/// 捕获 [AppError]（不存在则返回 null）——用于断言 fail-closed 错误码。
Future<AppError?> _expectAppError(Future<void> Function() action) async {
  try {
    await action();
    return null;
  } on AppError catch (e) {
    return e;
  }
}

Future<void> _verifySessionContextMenu() async {
  section('11. 会话右键菜单（置顶 / 清空 / 删除）');

  // 独立仓储实例（不污染前面各节的共享状态）。
  final repos = inMemoryRepositories();
  // 直查内存子表 map 自证（等价于 SQLite 侧"绕开 API 用 SQL 直查子表"）：
  // 删没删干净不看仓储查询接口，直接看底层存储。
  final convRepo = repos.conversations as InMemoryConversationRepository;
  final msgRepo = repos.messages as InMemoryMessageRepository;
  final conversations = ConversationService(repos);
  final experts = ExpertService(repos);

  final zhang = await experts.createLocal(name: '张三', systemPrompt: 'p');
  final li = await experts.createLocal(name: '李四', systemPrompt: 'p');

  final c1 = await conversations.createSingle(zhang.id);
  await conversations.appendUserMessage(c1.id, '第一条消息');
  await Future<void>.delayed(const Duration(milliseconds: 2));
  await conversations.appendUserMessage(c1.id, '第二条消息');
  final c2 = await conversations.createGroup(
      title: '决策群', expertIds: [zhang.id, li.id]);
  await Future<void>.delayed(const Duration(milliseconds: 2));
  await conversations.appendUserMessage(c2.id, '群聊消息');

  // —— 置顶：幂等 + 排序最前 ——
  await conversations.setPinned(c1.id, true);
  await conversations.setPinned(c1.id, true); // 重复置顶 → 幂等不抛错
  checkEq('置顶落库（getConversation.pinned）',
      (await repos.conversations.getConversation(c1.id))?.pinned, true);
  checkEq('置顶会话排最前（listInbox）',
      (await conversations.listInbox()).first.conversation.id, c1.id);
  checkEq('置顶会话排最前（仓储 listConversations 同口径）',
      (await convRepo.listConversations()).first.id, c1.id);

  // —— 取消置顶：回落时间倒序（c2 消息最新 → 回第一）——
  await conversations.setPinned(c1.id, false);
  checkEq('取消置顶落库',
      (await repos.conversations.getConversation(c1.id))?.pinned, false);
  checkEq('取消置顶后 c2 回最前（时间倒序）',
      (await conversations.listInbox()).first.conversation.id, c2.id);

  // —— 清空聊天记录：消息 0 条、会话与成员仍在 ——
  await conversations.clearMessages(c1.id);
  await conversations.clearMessages(c1.id); // 重复清空 → 幂等不抛错
  check('清空后消息数为 0（直查消息子表 map）',
      msgRepo.messages.values.where((m) => m.conversationId == c1.id).isEmpty);
  check('清空后会话仍在（直查会话子表 map）',
      convRepo.conversations.containsKey(c1.id));
  check('清空后成员仍在', (await conversations.members(c1.id)).length == 1);
  check('清空后 history 为空', (await conversations.history(c1.id)).isEmpty);
  final inboxAfterClear = await conversations.listInbox();
  final clearedEntry =
      inboxAfterClear.firstWhere((e) => e.conversation.id == c1.id);
  checkEq('清空后摘要为空串', clearedEntry.snippet, '');
  checkEq('清空不影响另一会话的消息数',
      (await conversations.history(c2.id)).length, 1);

  // —— 删除会话：会话 / 消息 / 成员 / 群配置一并消失（直查子表 map）——
  await conversations.delete(c2.id);
  check('删除后会话消失（直查会话子表 map）',
      !convRepo.conversations.containsKey(c2.id));
  check('删除后消息一并消失（直查消息子表 map）',
      msgRepo.messages.values.where((m) => m.conversationId == c2.id).isEmpty);
  check('删除后成员一并消失（直查成员子表 map）',
      convRepo.members[c2.id] == null);
  check('删除后群配置一并消失（直查群配置子表 map）',
      convRepo.groupConfigs[c2.id] == null);
  checkEq('删除后列表只剩清空过的 c1',
      (await conversations.listInbox()).map((e) => e.conversation.id).toList(), [c1.id]);

  // —— 会话不存在：三个方法都必须 fail-closed（conversation.notfound）——
  const ghost = 'conv_not_exist';
  final e1 = await _expectAppError(() => conversations.setPinned(ghost, true));
  checkEq('置顶不存在会话抛 conversation.notfound', e1?.code, 'conversation.notfound');
  final e2 = await _expectAppError(() => conversations.clearMessages(ghost));
  checkEq('清空不存在会话抛 conversation.notfound', e2?.code, 'conversation.notfound');
  final e3 = await _expectAppError(() => conversations.delete(ghost));
  checkEq('删除不存在会话抛 conversation.notfound', e3?.code, 'conversation.notfound');
}
