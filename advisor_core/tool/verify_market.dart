/// 市场客户端验证脚本（第 4 轮 · 待办 #4；纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_core && dart run tool/verify_market.dart`
///
/// 覆盖：
/// 1. 索引拉取（HTTP 端口假实现）→ 解析 → 仓储（分类筛选 / 搜索 / latest 元数据）；
/// 2. 安装编排成功路径：10 步校验链全过 → 提示词提取 → 落盘 → installPackage 落库；
/// 3. 失败分支逐一覆盖（**校验失败绝不安装、绝不落盘**）：
///    空下载体 / 超尺寸 / 索引哈希不符 / 非 ZIP / 缺 manifest / 内容篡改
///    （seal 内容口径下步骤 1 即拒 + 隔离验证步骤 4）/ 可执行文件 / Zip Slip /
///    schemaVersion / 能力越权 / 入口缺失 / 服务层拒装 / 旧口径（ZIP 字节
///    哈希作期望）必拒回归；
/// 4. **真实市场包回归**：用真实上线的 `tech-spec-expert-1.0.0.expert`
///    （`test/fixtures/real_expert_sample.expert`，2466 字节）走完整校验链
///    （ZIP 字节哈希仅作传输口径事实记录，安装校验用 seal 内容口径）；
/// 5. **真实资产 ecr.expert（任务 #27 口径统一实证）**：`过程文件/ecr.expert`
///    解包后按 seal 内容口径重算 == 线上索引声明 `81d3b107…`，端到端安装成功。
/// 6. **emoji/color 数据链**：§6 域模型解析/旧索引兼容/脏值归一（第 7 轮 T06）；
///    §7 `MarketRepository` 端口存取契约（第 #58 轮，InMemory 替身——
///    replacePackages → listPackages/getPackage 逐字一致 / null 透传 / 脏值原样 /
///    二次替换不残留；SQLite 真库同契约见 advisor_storage 的 v6→v7 迁移节）；
/// 7. **slug 存取契约**：§8 `MarketRepository` 端口（第 #59 轮，InMemory 替身——
///    slug 逐字一致 / 空串透读（不是 null）/ 同源二次替换更新不残留 /
///    getPackage 单查带得到 / emoji+color+slug 同时在防回归；SQLite 真库上的
///    slug 持久化与 v7→v8 迁移见 advisor_storage 的 v7→v8 迁移节）。
///
/// HTTP 层（真实网络）在沙箱内不可验证，在用户机器走查（见交付报告）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';
import 'package:archive/archive.dart' as arc;

// ---------------------------------------------------------------------------
// 迷你断言框架（与 verify_round3 同款）
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

void checkEq(String name, Object? actual, Object? expected) =>
    check(name, actual == expected, 'actual=$actual expected=$expected');

// ---------------------------------------------------------------------------
// 假 HTTP 客户端（端口假实现）
// ---------------------------------------------------------------------------

class FakeMarketHttpClient implements MarketHttpClient {
  FakeMarketHttpClient(this.texts, this.bytes);

  final Map<String, String> texts;
  final Map<String, List<int>> bytes;

  @override
  Future<String> fetchText(String url) async {
    final v = texts[url];
    if (v == null) throw ValidationError('http.404', '假客户端未配置：$url');
    return v;
  }

  @override
  Future<List<int>> fetchBytes(String url) async {
    final v = bytes[url];
    if (v == null) throw ValidationError('http.404', '假客户端未配置：$url');
    return v;
  }
}

// ---------------------------------------------------------------------------
// fixture：内存构造合法 .expert 包
// ---------------------------------------------------------------------------

const _promptText = '# 测试专家\n\n你是一名测试用顾问，负责验证市场安装链路。';
const _expertJsonText =
    '{"displayName":"测试专家","welcomeMessage":"你好，我是测试专家。",'
    '"quickPrompts":["帮我验一下","再验一次"],"profession":"测试顾问"}';

/// 构造一个合法包（可通过 [tamper] 注入缺陷）。
List<int> buildExpertPackage({
  String slug = 'test-pkg',
  String entryPath = 'agents/main.md',
  int schemaVersion = 1,
  bool networkCapability = false,
  bool addExecutable = false,
  bool addSlipPath = false,
  bool tamperEntryContent = false,
  bool omitManifest = false,
  List<int>? corruptBytes,
}) {
  // 声明哈希始终按【原始】内容计算；tamperEntryContent 只篡改 ZIP 内字节，
  // 这样「文件篡改」才会被步骤 4（SHA256 逐文件）检出。
  final originalBytes = utf8.encode(_promptText);
  final entryBytes = utf8.encode(
      tamperEntryContent ? '$_promptText\n（被篡改的一行）' : _promptText);
  final expertBytes = utf8.encode(_expertJsonText);

  final declared = <PackageFileEntry>[
    PackageFileEntry(path: 'agents/main.md', sha256: PackageManifest.sha256Hex(originalBytes)),
    PackageFileEntry(path: 'expert.json', sha256: PackageManifest.sha256Hex(expertBytes)),
  ];
  if (addExecutable) {
    final exe = utf8.encode('MZ fake binary');
    declared.add(PackageFileEntry(path: 'agents/tool.exe', sha256: PackageManifest.sha256Hex(exe)));
  }
  if (addSlipPath) {
    final evil = utf8.encode('evil');
    declared.add(PackageFileEntry(path: '../evil.txt', sha256: PackageManifest.sha256Hex(evil)));
  }
  final sorted = List<PackageFileEntry>.from(declared)
    ..sort((a, b) => a.path.compareTo(b.path));

  final manifest = <String, dynamic>{
    'schemaVersion': schemaVersion,
    'packageId': 'org.test.$slug',
    'slug': slug,
    'version': '1.0.0',
    'appVersion': '>=1.0.0',
    'displayName': '测试专家',
    'categoryId': '12-IndustryConsultant',
    'entry': entryPath,
    'sha256': PackageManifest.computePackageHash(sorted),
    'capabilities': {'network': networkCapability, 'filesystem': false, 'shell': false, 'tools': false},
    'files': sorted.map((f) => f.toJson()).toList(),
  };
  final manifestBytes = utf8.encode(jsonEncode(manifest));

  final archive = arc.Archive();
  void add(String path, List<int> content) {
    archive.addFile(arc.ArchiveFile(path, content.length, content));
  }

  if (!omitManifest) add('manifest.json', manifestBytes);
  add('agents/main.md', entryBytes);
  add('expert.json', expertBytes);
  if (addExecutable) add('agents/tool.exe', utf8.encode('MZ fake binary'));
  if (addSlipPath) add('../evil.txt', utf8.encode('evil'));

  final zipBytes = arc.ZipEncoder().encode(archive)!;
  return corruptBytes ?? zipBytes;
}

/// fixture index.json（3 个包、2 个分类）。
String buildIndexJson(String releaseUrl, String sha256) => jsonEncode({
      'schemaVersion': 1,
      'generatedAt': 1790785441428,
      'packages': [
        {
          'packageId': 'org.test.test-pkg',
          'slug': 'test-pkg',
          'displayName': '测试专家',
          'profession': '测试顾问',
          'description': '用于验证市场链路的测试包',
          'categoryId': '12-IndustryConsultant',
          'tags': ['测试部'],
          'latestVersion': '1.0.0',
          'versions': [
            {'version': '1.0.0', 'releaseUrl': releaseUrl, 'sha256': sha256, 'publishedAt': 1}
          ],
        },
        {
          'packageId': 'org.test.bid-reader',
          'slug': 'bid-reader',
          'displayName': '标书解读助手',
          'profession': '商务合规顾问',
          'description': '逐条拆解长篇要求与评分办法',
          'categoryId': '12-IndustryConsultant',
          'tags': ['长篇部', '标书'],
          'latestVersion': '1.0.0',
          'versions': [
            {'version': '1.0.0', 'releaseUrl': releaseUrl, 'sha256': sha256, 'publishedAt': 2}
          ],
        },
        {
          'packageId': 'org.test.kb-writer',
          'slug': 'kb-writer',
          'displayName': '知识库整理员',
          'profession': '文档工程师',
          'description': '整理与归档知识库文档',
          'categoryId': '05-MarketingGrowth',
          'tags': ['文档'],
          'latestVersion': '2.0.1',
          'versions': [
            {'version': '2.0.1', 'releaseUrl': releaseUrl, 'sha256': sha256, 'publishedAt': 3}
          ],
        },
      ],
    });

// ---------------------------------------------------------------------------
// 口径工具（任务 #27）：seal 内容口径重算 + 包内 manifest 解析
// ---------------------------------------------------------------------------

/// 解包后按 **seal 内容口径** 重算整包哈希（与 `market_client` 步骤 1、
/// 服务端 `package_utils.computePackageHash` 逐字同口径）：
/// 包内除 `manifest.json` 外每个文件的**实际内容字节** sha256 → 按 path
/// 字典序拼 `path\0sha256\n` → 整包 sha256（hex 小写）。
String payloadContentSha(List<int> packageBytes) {
  final archive = arc.ZipDecoder().decodeBytes(packageBytes);
  final entries = <PackageEntry>[];
  for (final f in archive.files) {
    if (f.isFile) {
      final content = f.content;
      entries.add(PackageEntry(
        path: f.name,
        bytes: content is Uint8List
            ? content
            : Uint8List.fromList(List<int>.from(content as List<int>)),
      ));
    }
  }
  return PackageManifest.contentHashFromPayload(
      PackagePayload(entries).dataEntries);
}

/// 从包内解析 `manifest.json`（供口径一致性断言）。
PackageManifest parseManifestFromBytes(List<int> packageBytes) {
  final archive = arc.ZipDecoder().decodeBytes(packageBytes);
  for (final f in archive.files) {
    if (f.isFile && f.name == 'manifest.json') {
      return PackageManifest.parse(utf8.decode(f.content as List<int>));
    }
  }
  throw StateError('包内缺少 manifest.json');
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 市场客户端验证（advisor_core / 待办 #4）');

  final flow = MarketInstallFlow();
  final packageBytes = buildExpertPackage();
  // 索引/manifest 声明的整包哈希 = **seal 内容口径**（任务 #27 口径统一）：
  // 解包后按包内实际内容字节重算，与 market_client 步骤 1 逐字同口径。
  // ZIP 文件字节的哈希是另一口径，不用于安装校验。
  final packageSha = payloadContentSha(packageBytes);

  // ── §1 索引拉取（HTTP 假实现 → 仓储） ──────────────────────────
  section('§1 索引拉取与仓储');
  final repos = inMemoryRepositories();
  final experts = ExpertService(repos);
  final market = MarketService(repos, experts: experts);
  await market.registerDefaultSource();

  const indexUrl = '${MarketService.defaultBaseUrl}/catalog/index.json';
  const releaseUrl =
      'https://github.com/TZW1982/private-advisor-market/releases/download/test-pkg/test-pkg-1.0.0.expert';
  final fake = FakeMarketHttpClient(
    {indexUrl: buildIndexJson(releaseUrl, packageSha)},
    {releaseUrl: packageBytes},
  );

  final refreshed = await market.refreshIndex(client: fake);
  final fixtureManifest = parseManifestFromBytes(packageBytes);
  checkEq('fixture 内容口径哈希 == manifest.sha256（seal 口径一致）',
      packageSha, fixtureManifest.sha256);
  checkEq('refreshIndex 返回包数', refreshed, 3);
  checkEq('仓储中包数', (await market.listPackages()).length, 3);

  final byCat = await market.listPackages(categoryId: '12-IndustryConsultant');
  checkEq('分类筛选（12-IndustryConsultant）', byCat.length, 2);
  final byCat2 = await market.listPackages(categoryId: '05-MarketingGrowth');
  checkEq('分类筛选（05-MarketingGrowth）', byCat2.length, 1);

  final searchHit = await market.listPackages();
  checkEq('仓储包数（再确认）', searchHit.length, 3);

  final indexObj = MarketIndex.parse(buildIndexJson(releaseUrl, packageSha));
  checkEq('搜索（按名称「标书解读」命中 1）', indexObj.search('标书解读').length, 1);
  checkEq('搜索（按标签「文档」命中 1）', indexObj.search('文档').length, 1);
  checkEq('搜索（按职业「顾问」命中 2）', indexObj.search('顾问').length, 2);
  checkEq('搜索（无命中）', indexObj.search('不存在关键词xyz').length, 0);
  checkEq('分组（分类数）', indexObj.groupByCategory().keys.length, 2);

  final pkg = await market.getPackage('org.test.test-pkg');
  check('包存在', pkg != null);
  check('latest 版本 1.0.0', pkg!.latest?.version.toString() == '1.0.0');
  checkEq('latest releaseUrl', pkg.latest!.releaseUrl, releaseUrl);
  checkEq('latest sha256', pkg.latest!.sha256, packageSha);

  try {
    await market.refreshIndex(client: fake, sourceId: 'src_unknown');
    check('未知市场源应报错', false);
  } on AppError catch (e) {
    check('未知市场源应报错', e.code == 'market.source.notfound', e.code);
  }

  // ── §2 安装成功路径 ──────────────────────────────────────────
  section('§2 安装编排成功路径（10 步全过 → 落盘 → 落库）');
  final tmp = await Directory.systemTemp.createTemp('verify_market_');
  final installDir = '${tmp.path}${Platform.pathSeparator}market${Platform.pathSeparator}packages${Platform.pathSeparator}test-pkg-1.0.0';

  final outcome = await flow.runFromBytes(
    packageBytes: packageBytes,
    expectedSha256: packageSha,
    installDir: installDir,
  );
  check('校验通过（ok）', outcome.ok, outcome.verification.report());
  // 步骤 10（appVersion 兼容）需调用方传入当前应用版本，安装流默认不启用
  // → 1（HTTPS 记录）+ 2–9 = 9 步。
  checkEq('校验步骤数（1–9，步骤 10 需传 appVersion）', outcome.verification.steps.length, 9);
  check('步骤 1 HTTPS 记录通过', outcome.verification.steps[0].passed);
  check('步骤 1 记录为 seal 内容口径',
      outcome.verification.steps[0].detail?.contains('内容口径') ?? false,
      outcome.verification.steps[0].detail);
  check('步骤 2 Manifest 通过',
      outcome.verification.steps.any((s) => s.name.startsWith('2.') && s.passed));
  check('步骤 3 签名跳过（未签名且不强制）',
      outcome.verification.steps.any((s) => s.name.startsWith('3.') && s.passed && s.detail != null));
  check('步骤 4 SHA256 通过',
      outcome.verification.steps.any((s) => s.name.startsWith('4.') && s.passed));
  check('步骤 5 Schema 通过',
      outcome.verification.steps.any((s) => s.name.startsWith('5.') && s.passed));
  check('步骤 6 尺寸通过',
      outcome.verification.steps.any((s) => s.name.startsWith('6.') && s.passed));
  check('步骤 7 路径安全通过',
      outcome.verification.steps.any((s) => s.name.startsWith('7.') && s.passed));
  check('步骤 8 能力通过',
      outcome.verification.steps.any((s) => s.name.startsWith('8.') && s.passed));
  check('步骤 9 无可执行通过',
      outcome.verification.steps.any((s) => s.name.startsWith('9.') && s.passed));

  checkEq('系统提示词 = entry 内容', outcome.systemPrompt, _promptText);
  checkEq('欢迎语（expert.json）', outcome.welcomeMessage, '你好，我是测试专家。');
  checkEq('快捷提示词', outcome.quickPrompts.join('|'), '帮我验一下|再验一次');
  checkEq('manifest.slug', outcome.manifest.slug, 'test-pkg');
  checkEq('落盘文件数', outcome.extractedFileCount, 3);

  final writtenEntry = File('$installDir${Platform.pathSeparator}agents${Platform.pathSeparator}main.md');
  check('entry 文件已落盘', writtenEntry.existsSync());
  checkEq('落盘内容一致', utf8.decode(writtenEntry.readAsBytesSync()), _promptText);
  check('expert.json 已落盘', File('$installDir${Platform.pathSeparator}expert.json').existsSync());

  final expert = await market.installPackage(
    manifest: outcome.manifest,
    verification: outcome.verification,
    systemPrompt: outcome.systemPrompt,
    installPath: outcome.installPath,
  );
  checkEq('专家名 = manifest.displayName', expert.name, '测试专家');
  checkEq('专家 systemPrompt', expert.systemPrompt, _promptText);
  checkEq('专家来源 market', expert.source.name, 'market');
  checkEq('专家 packageId', expert.packageId, 'org.test.test-pkg');
  check('专家状态已初始化', await repos.experts.getUserState(expert.id) != null);
  checkEq('已安装记录数', (await market.installed()).length, 1);
  check('安装记录 packageId 匹配',
      (await market.installed()).first.packageId == 'org.test.test-pkg');

  await tmp.delete(recursive: true);

  // ── §3 失败分支（每个都不落库、不落盘） ────────────────────────
  // 隔离纪律（第 4 轮走查反馈修复）：
  // - **负分支一律 `writeFiles: false`**——失败的用例绝不允许产生副作用；
  // - **每个分支独立临时目录**，用完即清理，互不共享；
  // - 3.3 的「错误期望哈希」用**必然不同**的 64 个 '0'，不再用
  //   `'0' + substring(1)` 这种「若真实 sha 首字符恰为 '0' 则期望==实际、
  //   被拒断言失效并连锁落盘污染后续用例」的脆弱构造。
  section('§3 失败分支（校验失败绝不安装）');
  Directory makeBranchTmp(String tag) => Directory.systemTemp.createTempSync('verify_market_${tag}_');

  // 3.1 空下载体
  final t31 = makeBranchTmp('e31');
  try {
    await flow.runFromBytes(
        packageBytes: const [],
        expectedSha256: packageSha,
        installDir: t31.path,
        writeFiles: false);
    check('空下载体被拒', false);
  } on AppError catch (e) {
    check('空下载体被拒', e is UnsafePackageError && e.message.contains('为空'), e.message);
  } finally {
    t31.deleteSync(recursive: true);
  }

  // 3.2 超尺寸（用极小上限的 flow 实例）
  final t32 = makeBranchTmp('e32');
  try {
    await MarketInstallFlow(maxDownloadBytes: 8).runFromBytes(
        packageBytes: packageBytes,
        expectedSha256: packageSha,
        installDir: t32.path,
        writeFiles: false);
    check('超尺寸被拒', false);
  } on AppError catch (e) {
    check('超尺寸被拒', e is UnsafePackageError && e.message.contains('上限'), e.message);
  } finally {
    t32.deleteSync(recursive: true);
  }

  // 3.3 索引哈希不符（期望 = 64 个 '0'，与任何真实 sha256 必然不同）
  final t33 = makeBranchTmp('e33');
  try {
    await flow.runFromBytes(
        packageBytes: packageBytes,
        expectedSha256: '0' * 64,
        installDir: t33.path,
        writeFiles: false);
    check('索引哈希不符被拒', false);
  } on AppError catch (e) {
    check('索引哈希不符被拒', e is UnsafePackageError && e.message.contains('完整性'), e.message);
  }
  // 隔离断言：被拒后绝无任何落盘。
  check('索引哈希不符 → 未落盘（隔离断言）', t33.listSync().isEmpty,
      '分支临时目录非空：${t33.listSync().map((e) => e.path)}');
  t33.deleteSync(recursive: true);

  // 3.4 非 ZIP
  final t34 = makeBranchTmp('e34');
  try {
    await flow.runFromBytes(
        packageBytes: utf8.encode('this is not a zip file'),
        expectedSha256: PackageManifest.sha256Hex(utf8.encode('this is not a zip file')),
        installDir: t34.path,
        writeFiles: false);
    check('非 ZIP 被拒', false);
  } on AppError catch (e) {
    check('非 ZIP 被拒', e is UnsafePackageError && e.message.contains('ZIP'), e.message);
  } finally {
    t34.deleteSync(recursive: true);
  }

  // 3.5 缺 manifest.json（期望哈希用内容口径 → 步骤 1 通过，命中 market.manifest）
  final noManifest = buildExpertPackage(omitManifest: true);
  final t35 = makeBranchTmp('e35');
  try {
    await flow.runFromBytes(
        packageBytes: noManifest,
        expectedSha256: payloadContentSha(noManifest),
        installDir: t35.path,
        writeFiles: false);
    check('缺 manifest 被拒', false);
  } on AppError catch (e) {
    check('缺 manifest 被拒', e is UnsafePackageError && e.message.contains('manifest'), e.message);
  } finally {
    t35.deleteSync(recursive: true);
  }

  // 3.6 内容篡改（ZIP 内字节改了，索引仍声明原内容哈希）
  // seal 内容口径下，篡改内容即改变重算哈希 → **步骤 1（索引对照）即拒**。
  final tampered = buildExpertPackage(tamperEntryContent: true);
  final t36 = makeBranchTmp('e36');
  try {
    await flow.runFromBytes(
        packageBytes: tampered,
        expectedSha256: packageSha,
        installDir: t36.path,
        writeFiles: false);
    check('内容篡改 → 步骤 1 即拒', false);
  } on AppError catch (e) {
    check('内容篡改 → 步骤 1 即拒',
        e is UnsafePackageError && e.message.contains('完整性'), e.message);
  }
  check('内容篡改 → 未落盘（隔离断言）', t36.listSync().isEmpty,
      '分支临时目录非空：${t36.listSync().map((e) => e.path)}');
  t36.deleteSync(recursive: true);

  // 3.6b 旧口径回归：若有人把口径改回「ZIP 文件字节哈希」（bug #27 的根因），
  // 用 ZIP 字节哈希作期望也**必被拒**——防止口径回退导致 282 包再次全挂。
  final t36b = makeBranchTmp('e36b');
  try {
    await flow.runFromBytes(
        packageBytes: packageBytes,
        expectedSha256: PackageManifest.sha256Hex(packageBytes),
        installDir: t36b.path,
        writeFiles: false);
    check('旧口径（ZIP 字节哈希作期望）必被拒', false);
  } on AppError catch (e) {
    check('旧口径（ZIP 字节哈希作期望）必被拒',
        e is UnsafePackageError && e.message.contains('完整性'), e.message);
  } finally {
    t36b.deleteSync(recursive: true);
  }

  // 3.7 内容篡改（模拟索引同被改为篡改内容的哈希）→ 步骤 1 通过，
  // 由步骤 4（manifest 逐文件哈希 vs 实际字节）单独拦下（隔离验证）。
  final t37 = makeBranchTmp('e37');
  final tamperedOutcome = await flow.runFromBytes(
      packageBytes: tampered,
      expectedSha256: payloadContentSha(tampered),
      installDir: t37.path,
      writeFiles: false);
  final step4 = tamperedOutcome.verification.steps.firstWhere((s) => s.name.startsWith('4.'));
  check('篡改内容 → 步骤 4 失败', !step4.passed, step4.detail);
  check('篡改内容 → 整包校验不通过', !tamperedOutcome.ok);
  check('篡改内容 → 未落盘（独立目录断言）', t37.listSync().isEmpty,
      '分支临时目录非空：${t37.listSync().map((e) => e.path)}');
  t37.deleteSync(recursive: true);

  // 3.8 可执行文件（已声明且哈希一致 → 只挂步骤 9）
  final withExe = buildExpertPackage(addExecutable: true);
  final t38 = makeBranchTmp('e38');
  final exeOutcome = await flow.runFromBytes(
      packageBytes: withExe,
      expectedSha256: payloadContentSha(withExe),
      installDir: t38.path,
      writeFiles: false);
  final step9 = exeOutcome.verification.steps.firstWhere((s) => s.name.startsWith('9.'));
  check('可执行文件 → 步骤 9 失败', !step9.passed, step9.detail);
  check('可执行文件 → 步骤 4 仍通过（隔离验证）',
      exeOutcome.verification.steps.firstWhere((s) => s.name.startsWith('4.')).passed);
  t38.deleteSync(recursive: true);

  // 3.9 Zip Slip（../ 路径 → 步骤 7 失败）
  final slip = buildExpertPackage(addSlipPath: true);
  final t39 = makeBranchTmp('e39');
  final slipOutcome = await flow.runFromBytes(
      packageBytes: slip,
      expectedSha256: payloadContentSha(slip),
      installDir: t39.path,
      writeFiles: false);
  final step7 = slipOutcome.verification.steps.firstWhere((s) => s.name.startsWith('7.'));
  check('Zip Slip → 步骤 7 失败', !step7.passed, step7.detail);
  t39.deleteSync(recursive: true);

  // 3.10 schemaVersion 非法
  final badSchema = buildExpertPackage(schemaVersion: 2);
  final t310 = makeBranchTmp('e310');
  final schemaOutcome = await flow.runFromBytes(
      packageBytes: badSchema,
      expectedSha256: payloadContentSha(badSchema),
      installDir: t310.path,
      writeFiles: false);
  final step5 = schemaOutcome.verification.steps.firstWhere((s) => s.name.startsWith('5.'));
  check('schemaVersion=2 → 步骤 5 失败', !step5.passed, step5.detail);
  t310.deleteSync(recursive: true);

  // 3.11 能力越权
  final netCap = buildExpertPackage(networkCapability: true);
  final t311 = makeBranchTmp('e311');
  final capOutcome = await flow.runFromBytes(
      packageBytes: netCap,
      expectedSha256: payloadContentSha(netCap),
      installDir: t311.path,
      writeFiles: false);
  final step8 = capOutcome.verification.steps.firstWhere((s) => s.name.startsWith('8.'));
  check('network 能力 → 步骤 8 失败', !step8.passed, step8.detail);
  t311.deleteSync(recursive: true);

  // 3.12 入口缺失
  final noEntry = buildExpertPackage(entryPath: 'agents/missing.md');
  final t312 = makeBranchTmp('e312');
  try {
    await flow.runFromBytes(
        packageBytes: noEntry,
        expectedSha256: payloadContentSha(noEntry),
        installDir: t312.path,
        writeFiles: false);
    check('入口缺失被拒', false);
  } on AppError catch (e) {
    check('入口缺失被拒', e is UnsafePackageError && e.message.contains('入口'), e.message);
  } finally {
    t312.deleteSync(recursive: true);
  }

  // 3.13 服务层拒装（verification 不通过 → UnsafePackageError，不写库）
  final beforeCount = (await market.installed()).length;
  final t313 = makeBranchTmp('e313');
  try {
    await market.installPackage(
      manifest: tamperedOutcome.manifest,
      verification: tamperedOutcome.verification,
      systemPrompt: 'x',
      installPath: t313.path,
    );
    check('服务层拒装失败包', false);
  } on AppError catch (e) {
    check('服务层拒装失败包', e is UnsafePackageError && e.message.contains('校验未通过'), e.message);
  }
  checkEq('拒装后安装记录数不变', (await market.installed()).length, beforeCount);
  // 隔离断言：拒装不产生任何落盘。
  check('服务层拒装 → 未落盘（隔离断言）', t313.listSync().isEmpty);
  t313.deleteSync(recursive: true);

  // ── §4 真实市场包回归 ────────────────────────────────────────
  section('§4 真实市场包回归（tech-spec-expert-1.0.0.expert）');
  const realFixturePath = 'test/fixtures/real_expert_sample.expert';
  const realWholeSha =
      'bdd5ebcdb4ca2bc1e4aacb262ee34744e448950ceb97491f75fc7a3b925068d7';
  final realFile = File(realFixturePath);
  if (!realFile.existsSync()) {
    check('真实包 fixture 存在', false, '缺少 $realFixturePath');
  } else {
    final realBytes = realFile.readAsBytesSync();
    // ZIP 字节哈希 = **传输口径事实**（与 api.github.com 下载字节一致），
    // 不再用于安装校验——仅作口径差异实证保留。
    checkEq('真实包 ZIP 字节 sha256（传输口径事实，与下载一致）',
        PackageManifest.sha256Hex(realBytes), realWholeSha);
    final realManifest = parseManifestFromBytes(realBytes);
    final realContentSha = payloadContentSha(realBytes);
    checkEq('真实包内容口径哈希 == manifest.sha256（seal 口径）',
        realContentSha, realManifest.sha256);
    // 安装校验用 **seal 内容口径**（与线上索引 versions[].sha256 同口径）。
    final realOutcome =
        await flow.verifyOnly(packageBytes: realBytes, expectedSha256: realContentSha);
    check('真实包 10 步校验链全过', realOutcome.ok, realOutcome.verification.report());
    check('真实包 entry = agents/main.md', realOutcome.manifest.entry == 'agents/main.md');
    check('真实包提示词含「技术规格」语义', realOutcome.systemPrompt.contains('技术规格'));
    check('真实包 appVersion >=1.3.0', realOutcome.manifest.appVersion.raw == '>=1.3.0');
    check('真实包能力位全 false', realOutcome.manifest.capabilities.isClean);
  }

  // ── §5 真实资产 ecr.expert（任务 #27 口径统一实证） ─────────────
  section('§5 真实资产 ecr.expert（engineering-code-reviewer）');
  // 线上索引声明（seal 内容口径）。此前客户端误用 ZIP 字节口径对比
  // → 282 个包全部「下载完整性校验失败」。
  const ecrContentSha =
      '81d3b107a930123971fc26a50e73ba01fc370f5f5f64627e0699bb14da0b90d8';
  const ecrBytesShaPrefix = '038490c9d2891c93';
  const ecrFixturePath = '../过程文件/ecr.expert';
  final ecrFile = File(ecrFixturePath);
  if (!ecrFile.existsSync()) {
    check('ecr.expert 存在', false, '缺少 $ecrFixturePath');
  } else {
    final ecrBytes = ecrFile.readAsBytesSync();
    final ecrBytesSha = PackageManifest.sha256Hex(ecrBytes);
    // 口径差异实证：同一包两种口径哈希不同，ZIP 字节口径 ≠ 线上声明。
    check('ecr.expert ZIP 字节哈希以已知前缀开头（口径差异实证）',
        ecrBytesSha.startsWith(ecrBytesShaPrefix), ecrBytesSha);
    check('ecr.expert ZIP 字节哈希 ≠ 线上声明（bug 根因实证）',
        ecrBytesSha != ecrContentSha);
    final ecrContent = payloadContentSha(ecrBytes);
    checkEq('ecr.expert 解包后按 seal 内容口径重算 == 线上索引声明',
        ecrContent, ecrContentSha);
    final ecrManifest = parseManifestFromBytes(ecrBytes);
    checkEq('ecr.expert manifest.sha256 == 内容口径哈希（seal 封包口径）',
        ecrManifest.sha256, ecrContentSha);
    // 端到端：完整安装编排（校验链 + 落盘）成功——「用户能装上专家」的最终证明。
    final ecrTmp = Directory.systemTemp.createTempSync('verify_market_ecr_');
    try {
      final ecrOutcome = await flow.runFromBytes(
          packageBytes: ecrBytes,
          expectedSha256: ecrContentSha,
          installDir: '${ecrTmp.path}${Platform.pathSeparator}ecr-1.0.0');
      check('ecr.expert 端到端安装成功（校验链全过）', ecrOutcome.ok,
          ecrOutcome.verification.report());
      check('ecr.expert 落盘文件数 > 0', ecrOutcome.extractedFileCount > 0,
          '实际 ${ecrOutcome.extractedFileCount}');
      check('ecr.expert 提示词非空', ecrOutcome.systemPrompt.trim().isNotEmpty);
    } on AppError catch (e) {
      check('ecr.expert 端到端安装成功（校验链全过）', false, '${e.code}：${e.message}');
    } finally {
      ecrTmp.deleteSync(recursive: true);
    }
  }

  // ── §6 市场 emoji/color（第 7 轮 T06，additive 字段） ──────────
  section('§6 MarketPackage emoji/color（additive；旧索引兼容）');
  // ① 有 emoji/color → 正确解析
  final withEmoji = MarketPackage.fromJson({
    'packageId': 'org.private-advisor.emoji-ok',
    'slug': 'emoji-ok',
    'displayName': '有 emoji 专家',
    'categoryId': '09-OperationsHR',
    'latestVersion': '1.0.0',
    'emoji': '👔',
    'color': '#6B7280',
  });
  checkEq('emoji 解析正确', withEmoji.emoji, '👔');
  checkEq('color 解析正确', withEmoji.color, '#6B7280');
  // ② 两者缺失 → null 且不抛（旧索引兼容，行为不变）
  final noEmoji = MarketPackage.fromJson({
    'packageId': 'org.private-advisor.emoji-none',
    'slug': 'emoji-none',
    'displayName': '无 emoji 专家',
    'categoryId': '09-OperationsHR',
    'latestVersion': '1.0.0',
  });
  check('旧索引无 emoji → emoji == null', noEmoji.emoji == null);
  check('旧索引无 color → color == null', noEmoji.color == null);
  // ③ 空串 / 非字符串脏值 → null，不抛异常
  final dirty = MarketPackage.fromJson({
    'packageId': 'org.private-advisor.emoji-dirty',
    'slug': 'emoji-dirty',
    'displayName': '脏值专家',
    'categoryId': '09-OperationsHR',
    'latestVersion': '1.0.0',
    'emoji': '   ',
    'color': 123,
  });
  check('emoji 空白串 → null', dirty.emoji == null, 'actual=${dirty.emoji}');
  check('color 非字符串（int）→ null 且不抛', dirty.color == null, 'actual=${dirty.color}');

  // ── §7 MarketRepository 端口 emoji/color 存取契约（第 #58 轮） ──
  // §6 覆盖域模型（fromJson 解析 / 旧索引兼容 / 脏值归一）；本节覆盖
  // **仓储端口**（InMemory 替身）replacePackages → listPackages / getPackage
  // 的存取契约。SQLite 真库上的同契约由
  // `advisor_storage/tool/verify_storage.dart` 的 v6→v7 迁移节验证。
  section('§7 MarketRepository emoji/color 存取（replacePackages/listPackages/getPackage）');
  final rt = inMemoryRepositories().market;
  MarketPackage rtPkg(String id, {String? emoji, String? color}) => MarketPackage(
        packageId: id,
        slug: id,
        displayName: '专家 $id',
        categoryId: '09-OperationsHR',
        latestVersion: SemVer.parse('1.0.0'),
        emoji: emoji,
        color: color,
      );
  MarketPackage rtById(List<MarketPackage> list, String id) =>
      list.firstWhere((p) => p.packageId == id);

  // ① replacePackages 后 listPackages 读回 emoji/color 逐字一致。
  await rt.replacePackages('src_emoji', [
    rtPkg('org.rt.one', emoji: '👔', color: '#6B7280'),
    rtPkg('org.rt.two', emoji: '🧭', color: '#0EA5E9'),
    rtPkg('org.rt.none'),
  ]);
  final rtList = await rt.listPackages(sourceId: 'src_emoji');
  checkEq('① replacePackages 后 listPackages 数量', rtList.length, 3);
  checkEq('① listPackages 读回 emoji 逐字一致', rtById(rtList, 'org.rt.one').emoji, '👔');
  checkEq('① listPackages 读回 color 逐字一致', rtById(rtList, 'org.rt.one').color, '#6B7280');
  checkEq('① 第二个包 emoji 逐字一致', rtById(rtList, 'org.rt.two').emoji, '🧭');
  checkEq('① 第二个包 color 逐字一致', rtById(rtList, 'org.rt.two').color, '#0EA5E9');

  // ② 包不带 emoji/color → 读回 null（不是空串）。
  final rtNone = rtById(rtList, 'org.rt.none');
  check('② 不带 emoji → 读回 null（不是空串）', rtNone.emoji == null, 'actual=${rtNone.emoji}');
  check('② 不带 color → 读回 null（不是空串）', rtNone.color == null, 'actual=${rtNone.color}');

  // ⑤ getPackage 单查同样带得到（须在 ④ 的二次替换之前断言）。
  final rtGot = await rt.getPackage('org.rt.one');
  check('⑤ getPackage 单查读回', rtGot != null);
  checkEq('⑤ getPackage 单查 emoji', rtGot?.emoji, '👔');
  checkEq('⑤ getPackage 单查 color', rtGot?.color, '#6B7280');

  // ④ 同 source 二次 replacePackages 不残留旧 emoji/color。
  await rt.replacePackages('src_emoji', [rtPkg('org.rt.one')]);
  final rtSecond = await rt.listPackages(sourceId: 'src_emoji');
  checkEq('④ 同 source 二次 replacePackages 后包数', rtSecond.length, 1);
  check('④ 二次替换（不带 emoji）不残留旧 emoji', rtSecond.first.emoji == null,
      'actual=${rtSecond.first.emoji}');
  check('④ 二次替换（不带 color）不残留旧 color', rtSecond.first.color == null,
      'actual=${rtSecond.first.color}');

  // ③ 脏值（空串 / 超长 / 非法色值字符串）→ 原样存取不抛、不改写。
  final longEmoji = '👔' * 4096;
  await rt.replacePackages('src_dirty', [
    rtPkg('org.rt.long', emoji: longEmoji, color: '这不是合法色值'),
    rtPkg('org.rt.empty', emoji: '', color: ''),
  ]);
  final dirtyList = await rt.listPackages(sourceId: 'src_dirty');
  final dLong = rtById(dirtyList, 'org.rt.long');
  final dEmpty = rtById(dirtyList, 'org.rt.empty');
  checkEq('③ 超长 emoji 串原样存取（不抛、不改写）', dLong.emoji, longEmoji);
  checkEq('③ 非法色值字符串原样存取', dLong.color, '这不是合法色值');
  check('③ 空串 emoji 原样存取（不被改写为 null）', dEmpty.emoji == '', 'actual=${dEmpty.emoji}');
  check('③ 空串 color 原样存取（不被改写为 null）', dEmpty.color == '', 'actual=${dEmpty.color}');

  // ── §8 MarketRepository 端口 slug 存取契约（第 #59 轮） ──
  // §6 覆盖域模型解析；§7 覆盖 emoji/color 端口契约；本节覆盖 **slug** 的
  // 端口契约（InMemory 替身）。SQLite 真库上的 slug 持久化（v7→v8 迁移 +
  // roundtrip + 「升级后既有行 slug 为空 → refreshIndex 后写入」关键路径）由
  // `advisor_storage/tool/verify_storage.dart` 的 v7→v8 迁移节验证——根因
  // （sqlite_market_repository 从未写/读 slug 列）只在 SQLite 实现上存在。
  section('§8 MarketPackage slug 存取（replacePackages/listPackages/getPackage）');
  final slugRepo = inMemoryRepositories().market;
  MarketPackage slugPkg(String id,
          {String slug = '', String? emoji, String? color}) =>
      MarketPackage(
        packageId: id,
        slug: slug,
        displayName: '专家 $id',
        categoryId: '09-OperationsHR',
        latestVersion: SemVer.parse('1.0.0'),
        emoji: emoji,
        color: color,
      );
  MarketPackage slugById(List<MarketPackage> list, String id) =>
      list.firstWhere((p) => p.packageId == id);

  // ① replacePackages 后 listPackages 读回 slug 逐字一致（含安装目录形式断言：
  //    slug 是 `packages/<slug>-<version>` 的组成部分，#59 根因之二的字段）。
  await slugRepo.replacePackages('src_slug', [
    slugPkg('org.slug.mentor',
        slug: 'life-mentor', emoji: '🧭', color: '#0EA5E9'),
    slugPkg('org.slug.reader', slug: 'bid-reader'),
  ]);
  final slugList = await slugRepo.listPackages(sourceId: 'src_slug');
  checkEq('① replacePackages 后 listPackages 数量', slugList.length, 2);
  checkEq('① listPackages 读回 slug 逐字一致',
      slugById(slugList, 'org.slug.mentor').slug, 'life-mentor');
  checkEq('① 第二个包 slug 逐字一致', slugById(slugList, 'org.slug.reader').slug,
      'bid-reader');
  check(
      '① 安装目录形式 = packages/<slug>-<version>（不坍缩为 /-1.0.0）',
      'packages/${slugById(slugList, 'org.slug.mentor').slug}-'
              '${slugById(slugList, 'org.slug.mentor').latestVersion}' ==
          'packages/life-mentor-1.0.0');

  // ② 不带 slug（空串）→ 读回空串（不是 null；域模型 slug 为非空 String，
  //    仓储映射口径 `?? ''`，与 MarketPackage.fromJson 的 (j['slug'] ?? '') 一致）。
  await slugRepo
      .replacePackages('src_slug_empty', [slugPkg('org.slug.empty', slug: '')]);
  final slugEmpty = await slugRepo.listPackages(sourceId: 'src_slug_empty');
  check('② 空串 slug → 读回空串（不是 null）', slugEmpty.first.slug == '',
      'actual=${slugEmpty.first.slug}');

  // ⑤ emoji/color 与 slug 同时在（防回归：证明 v7 两列没被 v8 弄丢）。
  check(
      '⑤ emoji/color 与 slug 同时在',
      slugById(slugList, 'org.slug.mentor').emoji == '🧭' &&
          slugById(slugList, 'org.slug.mentor').color == '#0EA5E9' &&
          slugById(slugList, 'org.slug.mentor').slug == 'life-mentor');

  // ④ getPackage 单查同样带得到 slug。
  final slugGot = await slugRepo.getPackage('org.slug.mentor');
  check('④ getPackage 单查读回', slugGot != null);
  checkEq('④ getPackage 单查带得到 slug', slugGot?.slug, 'life-mentor');
  checkEq('④ getPackage 单查 emoji 仍在（防回归）', slugGot?.emoji, '🧭');

  // ③ 同 source 二次 replacePackages 更新 slug 不残留旧值。
  await slugRepo.replacePackages('src_slug', [
    slugPkg('org.slug.mentor',
        slug: 'life-mentor-v2', emoji: '🧭', color: '#0EA5E9'),
  ]);
  final slugSecond = await slugRepo.listPackages(sourceId: 'src_slug');
  checkEq('③ 同 source 二次 replacePackages 后包数', slugSecond.length, 1);
  checkEq('③ 二次替换更新 slug 不残留旧值', slugSecond.first.slug, 'life-mentor-v2');

  // ── §9 删除专家 → 卸载 installed_packages + 安装幂等（第 #80 轮缺陷 B） ──
  // 覆盖：① 删市场来源专家且无同包他人 → installed 消失 / market 不再含该包 / 可重装；
  //       ② 同包多专家删其一 → installed 仍在；
  //       ③ 非 market 来源（local / imported）删除 → installed 表零变化；
  //       ④ 同包重复安装 → installed 仅 1 行（应用层去重，不加 schema 约束）。
  section('§9 ExpertService.delete 卸载 installed + 安装幂等（缺陷 B）');
  final delRepos = inMemoryRepositories();
  final delExperts = ExpertService(delRepos);
  final delMarket = MarketService(delRepos, experts: delExperts);

  const execId = 'org.private-advisor.executive-assistant';
  await delRepos.market.replacePackages(MarketService.defaultSourceId, [
    MarketPackage(
      packageId: execId,
      slug: 'executive-assistant',
      displayName: '总裁助理',
      profession: '行政管理',
      categoryId: '09-OperationsHR',
      tags: const ['总裁助理', '行政'],
      latestVersion: SemVer.parse('1.0.0'),
      versions: [
        MarketVersion(
          packageId: execId,
          version: SemVer.parse('1.0.0'),
          releaseUrl: 'https://example.test/executive-assistant-1.0.0.expert',
          sha256: '',
        ),
      ],
      emoji: '🧑‍💼',
      color: '#0EA5E9',
    ),
  ]);

  Future<Expert> addExec() => delExperts.installFromPackage(
        packageId: execId,
        version: '1.0.0',
        displayName: '总裁助理',
        systemPrompt: '你是总裁助理。',
        installPath: '/tmp/market/packages/executive-assistant-1.0.0',
      );

  // ① 首次安装 → installed 恰 1 行。
  final exec1 = await addExec();
  checkEq('① 首次安装后 installed 行数',
      (await delRepos.market.listInstalled()).length, 1);

  // ④ 同包重复安装 → installed 仍仅 1 行（应用层去重；不再追加重复行）。
  final exec2 = await addExec();
  final afterDup = await delRepos.market.listInstalled();
  checkEq('④ 同包重复安装后 installed 行数（去重）', afterDup.length, 1);
  checkEq('④ 去重后所剩 1 行确为该包', afterDup.single.packageId, execId);
  check('④ 同包现共 2 位专家（e1 ≠ e2）', exec1.id != exec2.id);

  // ② 同包多专家删其一 → installed 仍在（仍有他人引用该 packageId）。
  await delExperts.delete(exec1.id);
  checkEq('② 删其一后 installed 仍在',
      (await delRepos.market.listInstalled()).length, 1);
  check('② 删其一后 market.installed 仍含该包',
      (await delMarket.installed()).any((i) => i.packageId == execId));
  check('② 删其一后另一位专家仍在', (await delExperts.get(exec2.id)) != null);

  // ①（续）删最后一位同包专家 → installed 清空 + 市场不再认定「已添加」+ 可重装。
  await delExperts.delete(exec2.id);
  checkEq('① 删最后一位后 installed 清空',
      (await delRepos.market.listInstalled()).length, 0);
  check('① 删最后一位后 market.installed 为空',
      (await delMarket.installed()).isEmpty);
  check('① packageId 单查已安装 → null',
      (await delRepos.market.getInstalledByPackageId(execId)) == null);
  final reinstalled = await addExec();
  checkEq('① 可再次安装（不再被「已添加」永久卡死）',
      reinstalled.packageId, execId);
  checkEq('① 重装后 installed 回到 1 行',
      (await delRepos.market.listInstalled()).length, 1);

  // ③ 非 market 来源专家删除 → installed 表零变化。
  final localExpert = await delExperts.createLocal(
      name: '本地专家', systemPrompt: '本地的提示词');
  final beforeLocalDel = (await delRepos.market.listInstalled()).length;
  await delExperts.delete(localExpert.id);
  checkEq('③ 删本地（local）专家后 installed 行数不变',
      (await delRepos.market.listInstalled()).length, beforeLocalDel);
  check('③ 删本地专家不影响该包的已安装状态',
      (await delRepos.market.getInstalledByPackageId(execId)) != null);

  const importedExpert = Expert(
    id: 'e_imported_probe',
    name: '导入专家',
    systemPrompt: '导入的提示词',
    source: ExpertSource.imported,
    createdAt: 0,
    updatedAt: 0,
  );
  await delRepos.experts.upsertExpert(importedExpert);
  final beforeImpDel = (await delRepos.market.listInstalled()).length;
  await delExperts.delete(importedExpert.id);
  checkEq('③ 删导入（imported）专家后 installed 行数不变',
      (await delRepos.market.listInstalled()).length, beforeImpDel);

  // ── §9.5 市场搜索过滤契约（缺陷 A 配套：MarketController 与核心同源） ──
  // app 的 `MarketController` 已改为调用 core 的 [filterMarketPackagesByKeyword]，
  // 与 `MarketIndex.search` 是**同一事实源**；此处锁死该过滤契约（空关键词=全部 /
  // 名称·职业·描述·标签跨字段命中 / 大小写不敏感 / 无命中为空 / 与 search 逐项一致）。
  // （控制器内的 TextEditingController 绑定属 app 层，由 appcheck 静态门禁担保。）
  section('§9.5 市场搜索过滤契约（filterMarketPackagesByKeyword / MarketIndex.search 同源）');
  MarketPackage mk(String name,
          {String? profession, String? description, List<String> tags = const []}) =>
      MarketPackage(
        packageId: 'org.mk.$name',
        slug: name,
        displayName: name,
        profession: profession,
        description: description,
        categoryId: '09-OperationsHR',
        tags: tags,
        latestVersion: SemVer.parse('1.0.0'),
      );
  final searchList = <MarketPackage>[
    mk('总裁助理', profession: '行政管理', description: '帮总裁打理日程', tags: const ['行政']),
    mk('人生导师', profession: '咨询顾问', tags: const ['导师']),
    mk('SQL 优化师', profession: '数据库工程师', tags: const ['SQL']),
  ];
  final searchIndex = MarketIndex(generatedAt: 0, packages: searchList);
  checkEq('⑤ 空关键词 → 全部', filterMarketPackagesByKeyword(searchList, '').length, 3);
  checkEq('⑤ 全空白关键词 → 全部', filterMarketPackagesByKeyword(searchList, '   ').length, 3);
  checkEq('⑤ 按名称命中 1', filterMarketPackagesByKeyword(searchList, '总裁助理').length, 1);
  checkEq('⑤ 按职业命中 1', filterMarketPackagesByKeyword(searchList, '顾问').length, 1);
  checkEq('⑤ 按描述命中 1', filterMarketPackagesByKeyword(searchList, '日程').length, 1);
  checkEq('⑤ 按标签命中 1', filterMarketPackagesByKeyword(searchList, '导师').length, 1);
  checkEq('⑤ 无命中 → 空', filterMarketPackagesByKeyword(searchList, '不存在关键词xyz').length, 0);
  checkEq('⑤ 大小写不敏感（sql / SQL 命中数一致）',
      filterMarketPackagesByKeyword(searchList, 'sql').length,
      filterMarketPackagesByKeyword(searchList, 'SQL').length);
  checkEq('⑤ MarketIndex.search 与核心过滤器结果逐项一致（同源）',
      searchIndex.search('顾问').map((p) => p.packageId).join('|'),
      filterMarketPackagesByKeyword(searchList, '顾问').map((p) => p.packageId).join('|'));

  // ── 汇总 ────────────────────────────────────────────────────
  stdout.writeln('\n============================================================');
  stdout.writeln('结果：通过 $_passed ／ 失败 $_failed');
  if (_failed > 0) {
    for (final f in _failures) {
      stdout.writeln('  ✗ $f');
    }
    exit(1);
  }
  stdout.writeln('全部通过 ✅');
}
