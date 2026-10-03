/// 专家导入导出验证脚本（advisor_core 纯逻辑 · 任务 #69 T01–T03）。
///
/// 运行：`dart run tool/verify_expert_bundle.dart`
///
/// 覆盖：导出→导入 round-trip 一致、冲突三策略产物、含密钥被拒、
/// 高版本被拒、低版本补齐默认值、SHA256 篡改被拒、zip 越界路径被拒、
/// 单条失败补偿删除到位（不留半条）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';
import 'package:archive/archive.dart' as arc;

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
  check(name, '$actual' == '$expected', 'actual=$actual expected=$expected');
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List _zip(List<({String path, Uint8List bytes})> files) {
  final a = arc.Archive();
  for (final f in files) {
    a.addFile(arc.ArchiveFile(f.path, f.bytes.length, f.bytes));
  }
  return Uint8List.fromList(arc.ZipEncoder().encode(a)!);
}

Map<String, Uint8List> _unzip(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final a = arc.ZipDecoder().decodeBytes(data);
  final out = <String, Uint8List>{};
  for (final f in a.files) {
    if (f.isFile) out[f.name] = _fb(f);
  }
  return out;
}

Uint8List _fb(arc.ArchiveFile f) {
  final c = f.content;
  if (c is Uint8List) return c;
  return Uint8List.fromList(List<int>.from(c as List<int>));
}

/// 手工构造一个 `.expert` 包（用于篡改 / 越界 / 高低版本等负向用例）。
({Uint8List bytes, String manifest}) _buildPackage({
  required Map<String, List<int>> files,
  String entry = 'agents/main.md',
  String packageId = 'org.private-advisor.test',
  String slug = 'test-expert',
  String version = '1.0.0',
  String displayName = '测试专家',
  int schemaVersion = 1,
}) {
  final fileEntries = <PackageFileEntry>[
    for (final e in files.entries)
      PackageFileEntry(
          path: e.key, sha256: PackageManifest.sha256Hex(Uint8List.fromList(e.value))),
  ];
  final pkgHash = PackageManifest.computePackageHash(fileEntries);
  final manifest = <String, dynamic>{
    'schemaVersion': schemaVersion,
    'packageId': packageId,
    'slug': slug,
    'version': version,
    'appVersion': '>=1.3.0',
    'displayName': displayName,
    'categoryId': '12-IndustryConsultant',
    'entry': entry,
    'capabilities': {
      'network': false,
      'filesystem': false,
      'shell': false,
      'tools': false,
    },
    'sha256': pkgHash,
    'files': [for (final f in fileEntries) f.toJson()],
    'publishedAt': 1,
  };
  final manifestBytes = utf8.encode(jsonEncode(manifest));
  final a = arc.Archive();
  a.addFile(arc.ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
  for (final e in files.entries) {
    a.addFile(arc.ArchiveFile(e.key, e.value.length, e.value));
  }
  return (
    bytes: Uint8List.fromList(arc.ZipEncoder().encode(a)!),
    manifest: jsonEncode(manifest),
  );
}

/// 构造一套自定义 experts 仓储的 Repositories（补偿测试用）。
Repositories _reposWith(ExpertRepository experts) {
  final messages = InMemoryMessageRepository();
  return Repositories(
    experts: experts,
    groups: InMemoryGroupRepository(),
    conversations: InMemoryConversationRepository(messages: messages),
    messages: messages,
    generations: InMemoryGenerationRepository(),
    knowledge: InMemoryKnowledgeRepository(),
    providers: InMemoryProviderRepository(),
    credentials: InMemoryCredentialRepository(),
    secrets: InMemorySecretStore(),
    market: InMemoryMarketRepository(),
    settings: InMemorySettingsRepository(),
    jobs: InMemoryJobRepository(),
    attachments: InMemoryAttachmentRepository(),
  );
}

/// 在指定仓储上创建一个带运行配置 / 用户状态 / 标签 /（可选）知识库绑定的专家，
/// 返回该专家与（可选）知识库。
Future<({Expert expert, KnowledgeBase? kb})> _seedExpert(
  Repositories repos, {
  String name = '招标文件解读专家',
  String prompt = '你是政府采购与招投标顾问，逐条响应招标要求。',
  String profession = '政府采购与招投标顾问',
  bool withProfile = true,
  String? kbName,
}) async {
  final experts = ExpertService(repos);
  final providers = ProviderService(repos);
  final credentials = CredentialService(repos);
  final knowledge = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(),
    vectorStore: InMemoryVectorStore(repos.knowledge),
  );

  await providers.registerBuiltins();
  final cred = await credentials.saveDefault(
    apiKey: 'sk-test-placeholder-not-a-real-key-000',
    providerProfileId: ProviderService.deepseekProviderId,
    name: '默认凭据',
  );

  final expert = await experts.createLocal(
    name: name,
    systemPrompt: prompt,
    profession: profession,
    quickPrompts: const ['拆解这份招标文件', '提取评分办法'],
    welcomeMessage: '把文件发我。',
  );
  await experts.setTags(expert.id, ['招标文件', '资格条件']);

  if (withProfile) {
    await experts.updateRuntimeConfig(ExpertRuntimeConfig(
      expertId: expert.id,
      modelProfileId: 'mp_deepseek_chat',
      credentialProfileId: cred.id,
      temperature: 0.2,
      topP: 0.9,
      maxTokens: 2048,
      groundingPolicy: GroundingPolicy.preferred,
    ));
    await experts.updateUserState(ExpertUserState(
      expertId: expert.id,
      remark: '老王',
      styleId: 'professional',
      pinned: true,
    ));
  }

  KnowledgeBase? kb;
  if (kbName != null) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final created = KnowledgeBase(
        id: Ids.next('kb'), name: kbName, createdAt: now, updatedAt: now);
    await repos.knowledge.upsertBase(created);
    kb = created;
    await experts.bindKnowledge(expert.id, created.id, topK: 3, threshold: 0.4);
  }
  return (expert: expert, kb: kb);
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 专家导入导出验证（advisor_core）');
  stdout.writeln('=' * 60);

  await _t01Rules();
  await _t02Export();
  await _t03RoundTrip();
  await _t03Conflict();
  await _t03RejectSecret();
  await _t03SecretCaliber();
  await _t03RejectHighVersion();
  await _t03AcceptLowVersion();
  await _t03RejectTamper();
  await _t03RejectZipSlip();
  await _t03Compensate();

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
// T01 纯规则
// ---------------------------------------------------------------------------

Future<void> _t01Rules() async {
  section('T01 纯规则（slug / 敏感串 / 版本 / 冲突命名）');

  checkEq('ASCII 名 slug', SlugRule.fromName('Bid Tender Expert'), 'bid-tender-expert');
  checkEq('混合名保留 ASCII', SlugRule.fromName('AI 专家 01'), 'ai-01');
  check('纯中文名降级 expert-<id8>',
      SlugRule.fromName('人类学家', fallbackId: 'e_abc12345xyz').startsWith('expert-'),
      SlugRule.fromName('人类学家', fallbackId: 'e_abc12345xyz'));
  check('合法 slug 通过', SlugRule.isValid('bid-tender-expert'));
  check('中文 slug 非法', !SlugRule.isValid('人类学家'));
  check('含空格 slug 非法', !SlugRule.isValid('bad slug'));
  check('大写 slug 非法', !SlugRule.isValid('Bid'));

  check('含 sk- 密钥被识别', SecretLeakScan.contains('key = sk-abcdefghijklmnop1234'));
  check('普通中文文本干净', !SecretLeakScan.contains('这是一段普通的专家提示词，没有密钥。'));
  check('长随机串被识别', SecretLeakScan.contains('token ' + 'A' * 48));

  checkEq('高版本 → newer', VersionCompat.decide(2), SpecCompat.newer);
  checkEq('同版本 → equal', VersionCompat.decide(1), SpecCompat.equal);
  checkEq('低版本 → older', VersionCompat.decide(0), SpecCompat.older);

  checkEq('副本命名从 2 起', ConflictResolver.copyName('人类学家', <String>{}), '人类学家（导入 2）');
  checkEq('副本命名避让既有',
      ConflictResolver.copyName('人类学家', {'人类学家（导入 2）'}), '人类学家（导入 3）');
}

// ---------------------------------------------------------------------------
// T02 导出
// ---------------------------------------------------------------------------

Future<void> _t02Export() async {
  section('T02 导出（单专家 / 批量 / 包结构）');

  final repos = inMemoryRepositories();
  final seeded = await _seedExpert(repos, kbName: '投标知识库');
  final exportSvc = ExpertExportService(repos);

  // 默认：无 profile、无头像。
  final one = await exportSvc.build(expertIds: [seeded.expert.id]);
  final expectedSlug =
      SlugRule.fromName(seeded.expert.name, fallbackId: seeded.expert.id);
  check('单专家 → 非批量', !one.isBundle);
  check('单专家文件名 = <slug>-<version>.expert',
      one.fileName == '$expectedSlug-1.0.0.expert', one.fileName);
  check('纯中文名 slug 降级为 expert-<id8>',
      RegExp(r'^expert-[a-z0-9]{8}$').hasMatch(expectedSlug), expectedSlug);
  final inner = _unzip(one.bytes);
  check('包内含 manifest.json', inner.containsKey('manifest.json'));
  check('包内含 expert.json', inner.containsKey('expert.json'));
  check('包内含 agents/main.md', inner.containsKey('agents/main.md'));
  check('包内含 README.md', inner.containsKey('README.md'));
  check('默认不含 profile.json', !inner.containsKey('profile.json'));

  // 含本机设置 → 有 profile.json，且**不含明文 Key**。
  final withLocal = await exportSvc.build(
      expertIds: [seeded.expert.id], includeLocal: true);
  final innerLocal = _unzip(withLocal.bytes);
  check('勾选本机设置 → 含 profile.json', innerLocal.containsKey('profile.json'));
  final profileText = utf8.decode(innerLocal['profile.json']!);
  final profile = ExpertProfile.parse(profileText);
  checkEq('profile 规范版本', profile.specVersion, kExportSpecVersion);
  checkEq('profile 只写凭据引用名（非明文）', profile.runtime?.credentialRefName, '默认凭据');
  check('profile 不含明文 Key',
      !profileText.contains('sk-test-placeholder-not-a-real-key-000'));
  check('profile 携带知识库绑定（按名）',
      profile.knowledgeBindings.isNotEmpty &&
          profile.knowledgeBindings.first.knowledgeBaseName == '投标知识库');

  // 批量。
  final second = await ExpertService(repos).createLocal(
    name: '报价专家',
    systemPrompt: '你是报价专家。',
  );
  final batch = await exportSvc.build(expertIds: [seeded.expert.id, second.id]);
  check('批量 → isBundle', batch.isBundle);
  check('批量文件名格式 experts-YYYYMMDD-HHmm.zip',
      RegExp(r'^experts-\d{8}-\d{4}\.zip$').hasMatch(batch.fileName), batch.fileName);
  checkEq('批量 count', batch.count, 2);
  final outer = _unzip(batch.bytes);
  check('批量含 bundle.json', outer.containsKey('bundle.json'));
  checkEq('批量含 2 个 .expert',
      outer.keys.where((k) => k.endsWith('.expert')).length, 2);
  final bundle = BundleManifest.parse(utf8.decode(outer['bundle.json']!));
  checkEq('bundle.json count', bundle.count, 2);
}

// ---------------------------------------------------------------------------
// T03 round-trip
// ---------------------------------------------------------------------------

Future<void> _t03RoundTrip() async {
  section('T03 round-trip（导出 → 导入 一致）');

  final src = inMemoryRepositories();
  final seeded = await _seedExpert(src, kbName: '投标知识库');
  final one = await ExpertExportService(src)
      .build(expertIds: [seeded.expert.id], includeLocal: true);

  // 目标机：注册内置 provider + 同名凭据 + 同名知识库（验证"沿用"）。
  final dst = inMemoryRepositories();
  await ProviderService(dst).registerBuiltins();
  await CredentialService(dst).saveDefault(
    apiKey: 'sk-dst-0000000000000000',
    providerProfileId: ProviderService.deepseekProviderId,
    name: '默认凭据',
  );
  final dstKb = KnowledgeBase(
      id: Ids.next('kb'), name: '投标知识库', createdAt: 0, updatedAt: 0);
  await dst.knowledge.upsertBase(dstKb);

  final importSvc = ExpertImportService(dst);
  final plan = await importSvc.plan(one.bytes);
  checkEq('plan 条目数', plan.total, 1);
  check('无冲突 → ready', plan.items.first.isReady, plan.items.first.reason);
  check('携带 profile', plan.items.first.hasProfile);

  final report = await importSvc.apply(plan);
  checkEq('导入新增 1 位', report.added, 1);
  checkEq('导入失败 0 位', report.failed, 0);

  final imported = (await ExpertService(dst).list()).single;
  checkEq('名称一致', imported.name, '招标文件解读专家');
  checkEq('系统提示词一致', imported.systemPrompt, seeded.expert.systemPrompt);
  checkEq('来源 = imported', imported.source, ExpertSource.imported);
  final tags = await dst.experts.getTags(imported.id);
  checkEq('标签一致', tags.toSet(), {'招标文件', '资格条件'}.toSet());
  final state = await dst.experts.getUserState(imported.id);
  checkEq('备注一致', state?.remark, '老王');
  checkEq('风格一致', state?.styleId, 'professional');
  final cfg = await dst.experts.getRuntimeConfig(imported.id);
  checkEq('模型沿用', cfg?.modelProfileId, 'mp_deepseek_chat');
  checkEq('接地策略一致', cfg?.groundingPolicy, GroundingPolicy.preferred);
  final bindings = await dst.experts.listKnowledgeBindings(imported.id);
  checkEq('知识库绑定按名解析（1 条）', bindings.length, 1);
  checkEq('绑定指向目标机同名库', bindings.first.knowledgeBaseId, dstKb.id);
}

// ---------------------------------------------------------------------------
// T03 冲突三策略
// ---------------------------------------------------------------------------

Future<void> _t03Conflict() async {
  section('T03 冲突三策略（新建副本 / 覆盖 / 跳过）');

  final src = inMemoryRepositories();
  final seeded = await _seedExpert(src, kbName: '投标知识库');
  final one = await ExpertExportService(src)
      .build(expertIds: [seeded.expert.id], includeLocal: true);

  // —— 新建副本（默认） ——
  final copyRepos = inMemoryRepositories();
  await ProviderService(copyRepos).registerBuiltins();
  final copyExpertSvc = ExpertService(copyRepos);
  await copyExpertSvc.createLocal(
      name: '招标文件解读专家', systemPrompt: '既有专家，占位。');
  final copySvc = ExpertImportService(copyRepos);
  final copyPlan = await copySvc.plan(one.bytes);
  check('重复导入 → conflict', copyPlan.items.first.isConflict);
  checkEq('冲突命中同名既有专家',
      copyPlan.items.first.conflict?.matchedName, '招标文件解读专家');
  final copyReport = await copySvc.apply(copyPlan, decisions: {
    copyPlan.items.first.key: ConflictStrategy.newCopy,
  });
  checkEq('副本新增 1 位', copyReport.added, 1);
  final copyNames = (await copyExpertSvc.list()).map((e) => e.name).toSet();
  check('副本名带「（导入 2）」', copyNames.contains('招标文件解读专家（导入 2）'), '$copyNames');
  final copyImported = (await copyExpertSvc.list())
      .firstWhere((e) => e.name == '招标文件解读专家（导入 2）');
  final copyBindings =
      await copyRepos.experts.listKnowledgeBindings(copyImported.id);
  check('副本不携带知识库绑定', copyBindings.isEmpty);

  // —— 覆盖 ——
  final overRepos = inMemoryRepositories();
  await ProviderService(overRepos).registerBuiltins();
  final overExpertSvc = ExpertService(overRepos);
  final existing =
      await overExpertSvc.createLocal(name: '招标文件解读专家', systemPrompt: '旧提示词。');
  final overSvc = ExpertImportService(overRepos);
  final overPlan = await overSvc.plan(one.bytes);
  check('覆盖前 → conflict', overPlan.items.first.isConflict);
  final overReport = await overSvc.apply(overPlan, decisions: {
    overPlan.items.first.key: ConflictStrategy.overwrite,
  });
  checkEq('覆盖 1 位', overReport.overwritten, 1);
  final overList = await overExpertSvc.list();
  checkEq('覆盖后仍只有 1 位（不新建）', overList.length, 1);
  checkEq('覆盖保留原 id', overList.single.id, existing.id);
  check('覆盖更新内容', overList.single.systemPrompt == seeded.expert.systemPrompt);

  // —— 跳过 ——
  final skipRepos = inMemoryRepositories();
  await ProviderService(skipRepos).registerBuiltins();
  final skipExpertSvc = ExpertService(skipRepos);
  await skipExpertSvc.createLocal(name: '招标文件解读专家', systemPrompt: '旧。');
  final skipSvc = ExpertImportService(skipRepos);
  final skipPlan = await skipSvc.plan(one.bytes);
  final skipReport = await skipSvc.apply(skipPlan, decisions: {
    skipPlan.items.first.key: ConflictStrategy.skip,
  });
  checkEq('跳过 1 位', skipReport.skipped, 1);
  checkEq('跳过后仍只有 1 位', (await skipExpertSvc.list()).length, 1);
}

// ---------------------------------------------------------------------------
// T03 含密钥被拒
// ---------------------------------------------------------------------------

Future<void> _t03RejectSecret() async {
  section('T03 敏感串护栏（命中即拒）');

  final pkg = _buildPackage(files: {
    'expert.json': utf8.encode(jsonEncode({'displayName': '密钥专家'})),
    'agents/main.md': utf8.encode('你是助手。API 泄露测试：key=sk-abcdefghijklmnop1234'),
    'README.md': utf8.encode('# r\n'),
  }, displayName: '密钥专家', slug: 'secret-expert');
  final repos = inMemoryRepositories();
  final plan = await ExpertImportService(repos).plan(pkg.bytes);
  check('含密钥 → rejected', plan.items.first.isRejected);
  check('拒绝原因含"密钥"', plan.items.first.reason?.contains('密钥') ?? false,
      plan.items.first.reason);
  final report = await ExpertImportService(repos).apply(plan);
  checkEq('含密钥不算成功', report.success, 0);
  checkEq('含密钥记失败', report.failed, 1);
}

// ---------------------------------------------------------------------------
// T03 敏感串口径（收窄后正反例 + 端到端）
// ---------------------------------------------------------------------------

Future<void> _t03SecretCaliber() async {
  section('T03 敏感串口径收窄（正例命中 / 散文不误伤）');

  // —— 反例：合法英文散文不得命中（收窄前会误伤）——
  check(
      '反例·散文 "secret: keep it private" 不命中',
      !SecretLeakScan.contains(
          'You are a careful assistant. Never reveal the user secret: keep it private.'));
  check('反例·"the password is a good habit" 不命中',
      !SecretLeakScan.contains('the password is a good habit'));

  // —— 正例：真正的赋值必须命中 ——
  check('正例·API_KEY=sk-abcdef123456 命中',
      SecretLeakScan.contains('API_KEY=sk-abcdef123456'));
  check('正例·password=hunter2xyzabc 命中',
      SecretLeakScan.contains('password=hunter2xyzabc'));
  check('正例·SECRET: 8f3a9c2b7d1e 命中',
      SecretLeakScan.contains('SECRET: 8f3a9c2b7d1e'));
  check('正例·access_token=abcdefgh1234 命中',
      SecretLeakScan.contains('access_token=abcdefgh1234'));

  // —— 端到端 A：含 "secret:" 散文的合法专家**可导出**（不被中止）——
  final reposA = inMemoryRepositories();
  final en = await ExpertService(reposA).createLocal(
      name: '英文助手',
      systemPrompt: 'Never reveal the user secret: keep it private.');
  var threw = false;
  String? err;
  ExportResult? exp;
  try {
    exp = await ExpertExportService(reposA).build(expertIds: [en.id]);
  } catch (e) {
    threw = true;
    err = '$e';
  }
  check('端到端A·含散文 secret: 的专家可导出（不被中止）', !threw, err);
  check('端到端A·导出产物非空', !threw && exp!.bytes.isNotEmpty);

  // —— 端到端 B：同一形态的包**可被导入**（不被拒收）——
  final benignEn = _buildPackage(files: {
    'expert.json': utf8.encode(jsonEncode({'displayName': '英文助手'})),
    'agents/main.md': utf8.encode(
        'You are a careful assistant. Never reveal the user secret: keep it private.'),
    'README.md': utf8.encode('# 英文助手\n'),
  }, displayName: '英文助手', slug: 'english-helper');
  final planEn =
      await ExpertImportService(inMemoryRepositories()).plan(benignEn.bytes);
  check('端到端B·含散文 secret: 的包 → ready（不拒收）',
      planEn.items.first.isReady, planEn.items.first.reason);

  // —— 端到端 C：真正的赋值仍被拒（红线不松）——
  final badPkg = _buildPackage(files: {
    'expert.json': utf8.encode(jsonEncode({'displayName': '密钥专家'})),
    'agents/main.md': utf8.encode('配置如下：password=hunter2xyzabc'),
    'README.md': utf8.encode('# r\n'),
  }, displayName: '密钥专家', slug: 'still-secret-expert');
  final badPlan =
      await ExpertImportService(inMemoryRepositories()).plan(badPkg.bytes);
  check('端到端C·真赋值 password=... 仍被拒', badPlan.items.first.isRejected);
}

// ---------------------------------------------------------------------------
// T03 高版本被拒
// ---------------------------------------------------------------------------

Future<void> _t03RejectHighVersion() async {
  section('T03 高版本文件被拒');

  final pkg = _buildPackage(files: {
    'expert.json': utf8.encode(jsonEncode({'displayName': '未来专家'})),
    'agents/main.md': utf8.encode('你是未来专家。'),
    'profile.json': utf8.encode(jsonEncode({'specVersion': 2, 'exportedAt': 1})),
  }, displayName: '未来专家', slug: 'future-expert');
  final plan = await ExpertImportService(inMemoryRepositories()).plan(pkg.bytes);
  check('高版本 → rejected', plan.items.first.isRejected);
  check('高版本提示含升级引导',
      plan.items.first.reason?.contains('请升级应用') ?? false,
      plan.items.first.reason);
}

// ---------------------------------------------------------------------------
// T03 低版本补齐默认值
// ---------------------------------------------------------------------------

Future<void> _t03AcceptLowVersion() async {
  section('T03 低版本补齐默认值');

  final pkg = _buildPackage(files: {
    'expert.json': utf8.encode(jsonEncode({'displayName': '旧版专家'})),
    'agents/main.md': utf8.encode('你是旧版专家。'),
    'profile.json': utf8.encode(jsonEncode({'specVersion': 0, 'exportedAt': 1})),
  }, displayName: '旧版专家', slug: 'legacy-expert');
  final repos = inMemoryRepositories();
  final svc = ExpertImportService(repos);
  final plan = await svc.plan(pkg.bytes);
  check('低版本 → 不拒绝', !plan.items.first.isRejected, plan.items.first.reason);
  checkEq('低版本判定', plan.items.first.compat, SpecCompat.older);
  final report = await svc.apply(plan);
  checkEq('低版本仍可导入', report.added, 1);
  check('结果记录"旧版规范"提示',
      report.results.first.notes.any((n) => n.contains('旧版规范')),
      '${report.results.first.notes}');
  final imported = (await ExpertService(repos).list()).single;
  checkEq('缺失字段补默认（接地=off）',
      (await repos.experts.getRuntimeConfig(imported.id))?.groundingPolicy,
      GroundingPolicy.off);
  check('缺失字段补默认（quickPrompts 为空）', imported.quickPrompts.isEmpty);
}

// ---------------------------------------------------------------------------
// T03 SHA256 篡改被拒
// ---------------------------------------------------------------------------

Future<void> _t03RejectTamper() async {
  section('T03 SHA256 篡改被拒');

  final src = inMemoryRepositories();
  final seeded = await _seedExpert(src);
  final one = await ExpertExportService(src).build(expertIds: [seeded.expert.id]);
  final files = _unzip(one.bytes);

  // 篡改 agents/main.md 内容，但保留原 manifest（哈希不符 → 步骤 4 拦截）。
  final tampered = _zip([
    for (final e in files.entries)
      (
        path: e.key,
        bytes: e.key == 'agents/main.md'
            ? _b('你是被篡改的专家内容。')
            : e.value,
      ),
  ]);

  final plan = await ExpertImportService(inMemoryRepositories()).plan(tampered);
  check('篡改 → rejected', plan.items.first.isRejected);
  check('失败点为 SHA256',
      plan.items.first.reason?.contains('SHA256') ?? false,
      plan.items.first.reason);
  check('携校验报告', (plan.items.first.verifyReport ?? '').contains('SHA256'));
}

// ---------------------------------------------------------------------------
// T03 zip 越界路径被拒
// ---------------------------------------------------------------------------

Future<void> _t03RejectZipSlip() async {
  section('T03 zip 越界路径（../）被拒');

  final pkg = _buildPackage(files: {
    'expert.json': utf8.encode(jsonEncode({'displayName': '越界专家'})),
    'agents/main.md': utf8.encode('你是越界专家。'),
    '../evil.txt': utf8.encode('逃逸内容'),
  }, displayName: '越界专家', slug: 'slip-expert');

  final plan = await ExpertImportService(inMemoryRepositories()).plan(pkg.bytes);
  check('越界路径 → rejected', plan.items.first.isRejected);
  check('失败点含 Path Safety',
      plan.items.first.reason?.contains('Path Safety') ?? false,
      plan.items.first.reason);
}

// ---------------------------------------------------------------------------
// T03 单条失败补偿删除
// ---------------------------------------------------------------------------

/// 首次写运行配置即抛错的专家仓储（模拟落库中途失败）。
class _FailOnceExpertRepo extends InMemoryExpertRepository {
  bool failNextRuntime = false;

  @override
  Future<void> upsertRuntimeConfig(ExpertRuntimeConfig config) async {
    if (failNextRuntime) {
      failNextRuntime = false;
      throw const StorageError('test.write', '模拟写入失败');
    }
    return super.upsertRuntimeConfig(config);
  }
}

Future<void> _t03Compensate() async {
  section('T03 单条原子：失败补偿删除（不留半条）');

  final src = inMemoryRepositories();
  final seeded = await _seedExpert(src);
  final one = await ExpertExportService(src).build(expertIds: [seeded.expert.id]);

  final failRepo = _FailOnceExpertRepo()..failNextRuntime = true;
  final dst = _reposWith(failRepo);
  final svc = ExpertImportService(dst);
  final plan = await svc.plan(one.bytes);
  check('plan ready', plan.items.first.isReady, plan.items.first.reason);

  final report = await svc.apply(plan);
  checkEq('落库中途失败 → 记失败', report.failed, 1);
  checkEq('不留专家行', failRepo.experts.length, 0);
  checkEq('不留运行配置', failRepo.configs.length, 0);
  checkEq('不留用户状态', failRepo.states.length, 0);
  checkEq('不留标签', failRepo.tags.length, 0);
  checkEq('不留知识库绑定', failRepo.bindings.length, 0);
}
