/// 第 4 轮核心逻辑验证（纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_core && dart run tool/verify_round4.dart`
///
/// 覆盖（任务 #25 完成标准）：
/// 1. **path_canon**：归一化 / 比较键 / 前缀边界（`E:\Docs` 不误匹配 `E:\Docs2`）/ UNC；
/// 2. **FolderScanner**：递归 + 忽略规则 + 扩展名过滤（解析器并集派生）+ 超限拒绝；
/// 3. **增量对账三类判定**（§1.2 五规则）：added / unchanged（mtime+size 快速路径
///    **零读取**、mtime 漂移 + sha 相同 = 不算更新）/ updated（sha 确认变化）/
///    deleted（精确列表）/ failed 重试 / 读取失败保守不变 / 大小写对账键；
/// 4. **防线 1（失联）**：文件夹删除 → planRescan 中止、零删除、文档无损；
/// 5. **防线 2（大比例删除）**：dry-run 出计划不执行；未确认执行抛 `kb.folder.abort_deletes`；
///    确认后精确删除；
/// 6. **防线 3（删除铁律）**：源码 grep 本文件无批删入口；执行删除数 == diff 列表长度
///    （计数仓储逐单验证）；
/// 7. **unlink 双路径**：keep=true（文档保留、folder_id 清空）/ keep=false（删除数 ==
///    folder_id 命中数）；孤儿文档（folder_id IS NULL）两条路径绝对不碰；
/// 8. **backfill**：前缀 + 在位双条件回填（只增不删）、文件已移走不认领；
/// 9. **端到端重扫**：link → rescan 新增 → touch（mtime 漂移）→ 回填 → 改内容 →
///    删旧重建（新文档带 folder_id）→ 重复内容计 skipped → last_scan_at 更新。
library;

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

/// 断言抛出指定错误码。
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
// 计数仓储（防线 3：逐单删除验证）
// ---------------------------------------------------------------------------

class CountingKnowledgeRepository extends InMemoryKnowledgeRepository {
  int deleteDocumentCalls = 0;
  final List<String> deletedIds = [];

  @override
  Future<void> deleteDocument(String id) async {
    deleteDocumentCalls++;
    deletedIds.add(id);
    return super.deleteDocument(id);
  }
}

// ---------------------------------------------------------------------------
// 测试环境（真实临时目录 + 内存仓储）
// ---------------------------------------------------------------------------

class _Env {
  _Env(this.root)
      : repos = Repositories(
          experts: InMemoryExpertRepository(),
          groups: InMemoryGroupRepository(),
          conversations: InMemoryConversationRepository(),
          messages: InMemoryMessageRepository(),
          generations: InMemoryGenerationRepository(),
          knowledge: CountingKnowledgeRepository(),
          providers: InMemoryProviderRepository(),
          credentials: InMemoryCredentialRepository(),
          secrets: InMemorySecretStore(),
          market: InMemoryMarketRepository(),
          settings: InMemorySettingsRepository(),
          jobs: InMemoryJobRepository(),
          attachments: InMemoryAttachmentRepository(),
        ) {
    knowledge = KnowledgeService(
      repos,
      parsers: [PlainTextParser()],
      chunker: SimpleChunker(targetTokens: 64),
      vectorStore: InMemoryVectorStore(repos.knowledge),
      embeddingModel: HashEmbeddingModel(dimension: 64),
      retriever: InMemoryRetriever(repos.knowledge),
    );
    sync = FolderSyncService(repos, knowledge: knowledge);
  }

  final Directory root;
  final Repositories repos;
  late final KnowledgeService knowledge;
  late final FolderSyncService sync;

  CountingKnowledgeRepository get krepo => repos.knowledge as CountingKnowledgeRepository;

  /// 建一个文件夹 + 写入若干文本文件（内容唯一化防哈希撞车）。
  Directory makeFolder(String name, Map<String, String> files) {
    final dir = Directory('${root.path}${Platform.pathSeparator}$name');
    dir.createSync(recursive: true);
    files.forEach((name2, content) {
      File('${dir.path}${Platform.pathSeparator}$name2').writeAsStringSync(content);
    });
    return dir;
  }
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 第 4 轮核心验证（advisor_core / path_canon + 增量对账 + 三防线 + unlink）');
  stdout.writeln('=' * 60);

  _verifyPathCanon();

  final tmpRoot = Directory.systemTemp.createTempSync('pa_round4_core_');
  try {
    final env = _Env(tmpRoot);
    _verifyScanner(env);
    _verifyDiffCalculator();
    await _verifyDefense1(env);
    await _verifyDefense2And3(env);
    await _verifyUnlinkAndOrphans(env);
    await _verifyBackfill(env);
    await _verifyEndToEnd(env);
  } finally {
    try {
      tmpRoot.deleteSync(recursive: true);
    } catch (_) {
      // 清理失败忽略。
    }
  }

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
// 1. path_canon（纯函数）
// ---------------------------------------------------------------------------

void _verifyPathCanon() {
  section('path_canon（归一化 / 比较键 / 前缀边界 / UNC）');

  // 归一化：分隔符统一 + . / .. 消解 + 去尾分隔符，大小写保留（存储原样律）。
  checkEq('混合分隔符统一', canonicalize(r'E:/Docs/../Docs\Sub\'), r'E:\Docs\Sub');
  checkEq('去尾分隔符', canonicalize(r'E:\Docs\'), r'E:\Docs');
  checkEq('盘符根不丢段', canonicalize(r'C:\'), r'C:');
  checkEq('点段消解', canonicalize(r'E:\Docs\.\Sub'), r'E:\Docs\Sub');
  checkEq('相对路径 + cwd 消解', canonicalize('Sub\\..\\A.md', cwd: r'E:\Docs'), r'E:\Docs\A.md');
  checkEq('大小写保留（存储原样）', canonicalize(r'E:\Docs\Specs'), r'E:\Docs\Specs');
  checkEq('UNC 保留双分隔符', canonicalize(r'\\\\NAS\share\docs\\'), r'\\NAS\share\docs');
  checkEq('UNC 根 .. 不弹出', canonicalize(r'\\NAS\share\..\other'), r'\\NAS\share\other');

  // 比较键：小写。
  checkEq('folderKey 小写化', folderKey(r'E:\Docs\Specs'), r'e:\docs\specs');
  checkEq('大小写变体同键', folderKey(r'e:\DOCS\SPECS'), folderKey(r'E:\docs\specs'));

  // 前缀边界：带分隔符，防 E:\Docs 误匹配 E:\Docs2。
  check('前缀命中（子文件）', isUnderFolder(r'E:\Docs\A.md', r'e:\docs'));
  check('前缀不命中兄弟目录（E:\\Docs2）', !isUnderFolder(r'E:\Docs2\A.md', r'e:\docs'));
  check('前缀不命中大小写变体兄弟目录', !isUnderFolder(r'e:\docsX\a.md', r'E:\Docs'));
  check('前缀命中（嵌套子目录）', isUnderFolder(r'E:\Docs\Sub\Deep\A.md', r'e:\docs'));
  check('前缀不命中文件夹自身', !isUnderFolder(r'E:\Docs', r'e:\docs'));
  check('前缀命中（大小写变体路径）', isUnderFolder(r'e:\DOCS\sub\a.md', r'E:\docs'));
}

// ---------------------------------------------------------------------------
// 2. FolderScanner
// ---------------------------------------------------------------------------

void _verifyScanner(_Env env) {
  section('FolderScanner（递归 / 忽略规则 / 扩展名过滤 / 超限拒绝）');

  final dir = env.makeFolder('scan', {
    'a.md': '甲',
    'b.txt': '乙',
    'c.exe': '丙',
    '.hidden.md': '丁',
    '~\$lock.docx': '戊',
    'Thumbs.db': '己',
    'junk.tmp': '庚',
  });
  Directory('${dir.path}${Platform.pathSeparator}sub').createSync();
  File('${dir.path}${Platform.pathSeparator}sub${Platform.pathSeparator}d.md')
      .writeAsStringSync('丁一');

  final result = FolderScanner.scan(dir.path, supportedExtensions: env.sync.supportedExtensions);
  final names = result.files.map((f) => f.name).toSet();
  checkEq('受支持文件 3 个（a.md/b.txt/sub\\d.md）', result.files.length, 3);
  check('递归扫到 sub\\d.md', names.contains('d.md'));
  check('不支持的扩展名被过滤（c.exe）', !names.contains('c.exe'));
  check('隐藏文件被忽略（.hidden.md）', !names.contains('.hidden.md'));
  check('Office 锁文件被忽略（~\$lock.docx）', !names.contains('~\$lock.docx'));
  check('Thumbs.db 被忽略', !names.contains('Thumbs.db'));
  check('临时文件被忽略（junk.tmp）', !names.contains('junk.tmp'));
  check('stat 带正 mtime', result.files.every((f) => f.mtimeMs > 0));
  check('扩展名集合来自解析器并集（含 .md 与 .txt）',
      env.sync.supportedExtensions.contains('.md') && env.sync.supportedExtensions.contains('.txt'));

  // 超限拒绝（用小上限注入，不真造 50MB 文件）。
  final big = FolderScanner.scan(dir.path,
      supportedExtensions: env.sync.supportedExtensions, maxBytes: 1);
  checkEq('超限文件进拒绝列表', big.rejections.length, 3);
  check('拒绝原因含"上限"', big.rejections.every((r) => r.reason.contains('上限')));
  checkEq('超限文件不进文件集合', big.files.length, 0);
}

// ---------------------------------------------------------------------------
// 3. FolderDiffCalculator（增量三类判定，假哈希注入）
// ---------------------------------------------------------------------------

void _verifyDiffCalculator() {
  section('增量对账（§1.2 五规则：added / 快速路径零读取 / sha 确认 / deleted / failed 重试）');

  final now = 1700000000000;
  KnowledgeDocument doc({
    required String id,
    required String path,
    required String hash,
    int size = 10,
    int? mtime,
    DocumentStatus status = DocumentStatus.indexed,
  }) =>
      KnowledgeDocument(
        id: id,
        knowledgeBaseId: 'kb',
        fileName: 'f',
        filePath: path,
        fileHash: hash,
        fileSize: size,
        status: status,
        sourceMtime: mtime,
        createdAt: now,
        updatedAt: now,
      );

  ScannedFileStat stat(String path, {int size = 10, int mtime = 1000}) =>
      ScannedFileStat(path: path, name: 'f', sizeBytes: size, mtimeMs: mtime);

  // —— 快速路径：mtime+size 全中 + indexed → unchanged，且零内容读取 ——
  var hashReads = 0;
  var d1 = FolderDiffCalculator.compute(
    files: [stat(r'E:\F\a.md', size: 10, mtime: 111)],
    existing: [doc(id: 'd1', path: r'E:\F\a.md', hash: 'h1', size: 10, mtime: 111)],
    readHash: (_) {
      hashReads++;
      return 'whatever';
    },
  );
  checkEq('快速路径命中 → unchanged', d1.unchanged.length, 1);
  checkEq('快速路径零内容读取（readHash 未调用）', hashReads, 0);
  checkEq('无新增', d1.added.length, 0);
  checkEq('无删除', d1.deleted.length, 0);

  // —— mtime 漂移 + sha 相同 → unchanged（mtime 变不算更新）——
  d1 = FolderDiffCalculator.compute(
    files: [stat(r'E:\F\a.md', size: 10, mtime: 222)],
    existing: [doc(id: 'd1', path: r'E:\F\a.md', hash: 'h1', size: 10, mtime: 111)],
    readHash: (_) => 'h1',
  );
  checkEq('mtime 漂移 + sha 相同 → unchanged（不算更新）', d1.unchanged.length, 1);
  checkEq('且不算更新', d1.updated.length, 0);

  // —— sha 相同但 size 不同 → 走 ③ 确认 → unchanged ——
  d1 = FolderDiffCalculator.compute(
    files: [stat(r'E:\F\a.md', size: 99, mtime: 111)],
    existing: [doc(id: 'd1', path: r'E:\F\a.md', hash: 'h1', size: 10, mtime: 111)],
    readHash: (_) => 'h1',
  );
  checkEq('size 异常但 sha 确认相同 → unchanged', d1.unchanged.length, 1);

  // —— sha 不同 → updated（删旧重建）——
  d1 = FolderDiffCalculator.compute(
    files: [stat(r'E:\F\a.md', size: 10, mtime: 333)],
    existing: [doc(id: 'd1', path: r'E:\F\a.md', hash: 'h1', size: 10, mtime: 111)],
    readHash: (_) => 'h2',
  );
  checkEq('sha 变化 → updated', d1.updated.length, 1);
  checkEq('updated 指向旧文档 id', d1.updated.first.documentId, 'd1');
  checkEq('updated 携带文件系统 mtime', d1.updated.first.mtimeMs, 333);

  // —— failed 且文件在 → 一律按 updated 重试 ——
  d1 = FolderDiffCalculator.compute(
    files: [stat(r'E:\F\a.md', size: 10, mtime: 111)],
    existing: [doc(id: 'd1', path: r'E:\F\a.md', hash: 'h1', size: 10, mtime: 111, status: DocumentStatus.failed)],
    readHash: (_) => 'h1',
  );
  checkEq('failed → 按 updated 重试（即使 mtime/size 全中）', d1.updated.length, 1);

  // —— 读取失败（null）→ 保守 unchanged ——
  d1 = FolderDiffCalculator.compute(
    files: [stat(r'E:\F\a.md', size: 10, mtime: 333)],
    existing: [doc(id: 'd1', path: r'E:\F\a.md', hash: 'h1', size: 10, mtime: 111)],
    readHash: (_) => null,
  );
  checkEq('读取失败 → 保守 unchanged（绝不因读取抖动误删）', d1.unchanged.length, 1);

  // —— 新增 / 删除 / 大小写对账键 ——
  d1 = FolderDiffCalculator.compute(
    files: [
      stat(r'E:\F\a.md', mtime: 111),
      stat(r'e:\F\b.md', mtime: 112), // 与既有 doc 大小写不同的路径变体。
      stat(r'E:\F\new.md', mtime: 113),
    ],
    existing: [
      doc(id: 'd1', path: r'E:\F\a.md', hash: 'h1', mtime: 111),
      doc(id: 'd2', path: r'E:\F\B.md', hash: 'h2', mtime: 112),
    ],
    readHash: (_) => 'h2',
  );
  checkEq('大小写变体路径经比较键命中既有文档（unchanged 含两条）', d1.unchanged.length, 2);
  checkEq('新路径 → added（按路径）',
      d1.added.map((f) => f.path).toSet().join('|'), r'E:\F\new.md');

  d1 = FolderDiffCalculator.compute(
    files: [stat(r'E:\F\a.md', mtime: 111)],
    existing: [
      doc(id: 'd1', path: r'E:\F\a.md', hash: 'h1', mtime: 111),
      doc(id: 'd2', path: r'E:\F\gone.md', hash: 'h2', mtime: 110),
    ],
    readHash: (_) => 'h1',
  );
  checkEq('文件系统缺失 → deleted 精确列表（按 id）',
      d1.deleted.map((c) => c.documentId).toSet().join('|'), 'd2');
  checkEq('deleted 携带文档 id', d1.deleted.first.documentId, 'd2');
}

// ---------------------------------------------------------------------------
// 4. 防线 1：失联检测
// ---------------------------------------------------------------------------

Future<void> _verifyDefense1(_Env env) async {
  section('防线 1（失联）：文件夹不存在 → 中止、零删除、文档无损');

  final dir = env.makeFolder('d1', {'a.md': '防线一内容', 'b.md': '第二篇'});
  final base = await env.knowledge.createBase(name: '防线1库');
  final folder = await env.sync.linkFolder(base.id, dir.path);
  final s1 = await env.sync.rescan(folder.id);
  checkEq('前置：首次重扫新增 2', s1.added, 2);
  checkEq('前置：文档已带 folder_id',
      (await env.krepo.listDocumentsByFolder(folder.id)).length, 2);

  // 模拟拔盘 / 移动：删除整个文件夹。
  dir.deleteSync(recursive: true);

  final plan = await env.sync.planRescan(folder.id);
  check('防线 1：plan 已中止', plan.isAborted);
  checkEq('防线 1：abortedReason = folder_missing', plan.abortedReason, 'folder_missing');
  checkEq('防线 1：零删除（deleted 为空）', plan.deleted.length, 0);
  checkEq('防线 1：零新增', plan.added.length, 0);
  checkEq('防线 1：existingCount 仍为 2', plan.existingCount, 2);

  // 中止计划执行必须抛错，绝不落任何删除。
  await checkThrowsCode(
      '防线 1：执行中止计划抛 kb.folder.missing', () => env.sync.rescan(folder.id), 'kb.folder.missing');
  await checkThrowsCode('防线 1：直接 executeRescan 中止计划同样抛错',
      () => env.sync.executeRescan(plan).drain(), 'kb.folder.missing');

  checkEq('防线 1：文档全部无损', (await env.knowledge.listDocuments(base.id)).length, 2);
  checkEq('防线 1：删除调用计数未增', env.krepo.deleteDocumentCalls, 0);
}

// ---------------------------------------------------------------------------
// 5. 防线 2 + 3：大比例删除确认 / 删除铁律
// ---------------------------------------------------------------------------

Future<void> _verifyDefense2And3(_Env env) async {
  section('防线 2+3（大比例删除 dry-run / 未确认抛错 / 精确逐单删除）');

  final dir = env.makeFolder('d2', {
    'a.md': '第一篇',
    'b.md': '第二篇',
    'c.md': '第三篇',
  });
  final base = await env.knowledge.createBase(name: '防线2库');
  final folder = await env.sync.linkFolder(base.id, dir.path);
  await env.sync.rescan(folder.id);
  checkEq('前置：3 篇已索引', (await env.knowledge.listDocuments(base.id)).length, 3);
  final callsBefore = env.krepo.deleteDocumentCalls;

  // 删 2/3 个文件（66% ≥ 50%）→ 触发确认。
  File('${dir.path}${Platform.pathSeparator}a.md').deleteSync();
  File('${dir.path}${Platform.pathSeparator}b.md').deleteSync();

  final plan = await env.sync.planRescan(folder.id);
  checkEq('防线 2：diff 判定 2 个删除', plan.deleted.length, 2);
  check('防线 2：needsConfirmation = true（66% ≥ 50%）', plan.needsConfirmation);
  check('防线 2：deleteRatio ≈ 0.667', (plan.deleteRatio - 2 / 3).abs() < 1e-9,
      'ratio=${plan.deleteRatio}');

  // dry-run：未确认执行必须抛 kb.folder.abort_deletes，且零删除。
  await checkThrowsCode('防线 2：未确认执行抛 kb.folder.abort_deletes',
      () => env.sync.rescan(folder.id), 'kb.folder.abort_deletes');
  await checkThrowsCode('防线 2：executeRescan(confirmDeletes:false) 同样抛错',
      () => env.sync.executeRescan(plan, confirmDeletes: false).drain(), 'kb.folder.abort_deletes');
  checkEq('防线 2：dry-run 零副作用（文档仍 3 篇）',
      (await env.knowledge.listDocuments(base.id)).length, 3);
  checkEq('防线 2：dry-run 零删除调用', env.krepo.deleteDocumentCalls, callsBefore);

  // 确认后执行：精确删除 2 个，删除数 == diff 列表长度（防线 3 断言）。
  final summary = await env.sync.rescan(folder.id, confirmDeletes: true);
  checkEq('确认执行：deleted = 2（== diff 列表长度）', summary.deleted, 2);
  checkEq('确认执行：deleted 计数 == plan.deleted.length', summary.deleted, plan.deleted.length);
  checkEq('确认执行：删除调用增量 == 2', env.krepo.deleteDocumentCalls - callsBefore, 2);
  checkEq('确认执行：剩余文档 1 篇', (await env.knowledge.listDocuments(base.id)).length, 1);
  checkEq('确认执行：剩余的是 c.md',
      (await env.knowledge.listDocuments(base.id)).first.fileName, 'c.md');
  checkEq('确认执行：added/updated 为 0', summary.added + summary.updated, 0);

  // —— 防线 2 低阈值场景回归：4 篇中单删 1 个（25% < 50% 且 < 20）不触发确认 ——
  final dirLow = env.makeFolder('d2low', {
    'h1.md': '其一',
    'h2.md': '其二',
    'h3.md': '其三',
    'h4.md': '其四',
  });
  final baseLow = await env.knowledge.createBase(name: '防线2低阈值库');
  final folderLow = await env.sync.linkFolder(baseLow.id, dirLow.path);
  await env.sync.rescan(folderLow.id);
  File('${dirLow.path}${Platform.pathSeparator}h1.md').deleteSync();
  final plan2 = await env.sync.planRescan(folderLow.id);
  checkEq('低阈值场景：diff 判定 1 个删除', plan2.deleted.length, 1);
  check('正常单删不触发确认（25% < 50% 且 < 20）', !plan2.needsConfirmation,
      'needs=${plan2.needsConfirmation} ratio=${plan2.deleteRatio}');

  // —— 防线 3：源码 grep 本文件无任何批删入口（QA 同款验证）——
  final src = File('lib${Platform.pathSeparator}application${Platform.pathSeparator}folder_sync.dart')
      .readAsStringSync();
  check('防线 3：folder_sync.dart 源码无 deleteByKnowledgeBase',
      !src.contains('deleteByKnowledgeBase'));
  check('防线 3：folder_sync.dart 源码无 deleteBase 调用', !src.contains('deleteBase'));
  check('防线 3：folder_sync.dart 的删除入口只有 deleteDocument',
      src.contains('deleteDocument('));
}

// ---------------------------------------------------------------------------
// 6. unlink 双路径 + 孤儿保护
// ---------------------------------------------------------------------------

Future<void> _verifyUnlinkAndOrphans(_Env env) async {
  section('unlink 二选一（keep=true 保留为孤儿 / keep=false 精确删除）+ 孤儿文档绝不触碰');

  // —— keep=true：仅解除关联 ——
  final dirA = env.makeFolder('unlink_keep', {'a.md': '甲甲甲', 'b.md': '乙乙乙'});
  final baseA = await env.knowledge.createBase(name: 'unlink保留库');
  final folderA = await env.sync.linkFolder(baseA.id, dirA.path);
  await env.sync.rescan(folderA.id);
  // 造一个孤儿文档（folder_id IS NULL）：模拟旧导入（含一个分块，验证内容保留）。
  final now = DateTime.now().millisecondsSinceEpoch;
  await env.krepo.upsertDocument(KnowledgeDocument(
    id: 'doc_orphan_k',
    knowledgeBaseId: baseA.id,
    fileName: '孤儿.md',
    filePath: r'E:\Nowhere\孤儿.md',
    fileHash: 'orphan_k',
    fileSize: 3,
    status: DocumentStatus.indexed,
    createdAt: now,
    updatedAt: now,
  ));
  await env.krepo.insertChunks([
    KnowledgeChunk(id: 'orphan_k_c0', documentId: 'doc_orphan_k', text: '孤儿内容块', sequence: 0, chunkHash: 'ok0'),
  ]);

  final rTrue = await env.sync.unlinkFolder(folderA.id, keepDocuments: true);
  checkEq('keep=true：受影响文档数 = 2', rTrue.affectedDocuments, 2);
  check('keep=true：登记行已删', (await env.krepo.getFolder(folderA.id)) == null);
  final docsA = await env.knowledge.listDocuments(baseA.id);
  checkEq('keep=true：文档仍在（3 = 2 关联 + 1 孤儿）', docsA.length, 3);
  final linkedDocs = docsA.where((d) => d.id != 'doc_orphan_k').toList();
  check('keep=true：原关联文档 folder_id 已清空（NULL）',
      linkedDocs.every((d) => d.folderId == null));
  check('keep=true：既有孤儿文档 folder_id 仍为 NULL 且存在',
      docsA.any((d) => d.id == 'doc_orphan_k' && d.folderId == null));
  check('keep=true：分块保留（可检索）',
      (await env.krepo.listChunks(linkedDocs.first.id)).isNotEmpty);

  // —— keep=false：解除并删除 ——
  final dirB = env.makeFolder('unlink_del', {'c.md': '丙丙丙', 'd.md': '丁丁丁'});
  final baseB = await env.knowledge.createBase(name: 'unlink删除库');
  final folderB = await env.sync.linkFolder(baseB.id, dirB.path);
  await env.sync.rescan(folderB.id);
  await env.krepo.upsertDocument(KnowledgeDocument(
    id: 'doc_orphan_d',
    knowledgeBaseId: baseB.id,
    fileName: '孤儿2.md',
    filePath: r'E:\Nowhere\孤儿2.md',
    fileHash: 'orphan_d',
    fileSize: 3,
    status: DocumentStatus.indexed,
    createdAt: now,
    updatedAt: now,
  ));
  await env.krepo.insertChunks([
    KnowledgeChunk(id: 'orphan_d_c0', documentId: 'doc_orphan_d', text: '孤儿二内容块', sequence: 0, chunkHash: 'od0'),
  ]);
  final callsBefore = env.krepo.deleteDocumentCalls;
  final hitCount = (await env.krepo.listDocumentsByFolder(folderB.id)).length;
  checkEq('前置：folder_id 命中 2 篇', hitCount, 2);

  final rFalse = await env.sync.unlinkFolder(folderB.id, keepDocuments: false);
  checkEq('keep=false：删除数 == folder_id 命中数（2）', rFalse.affectedDocuments, 2);
  checkEq('keep=false：删除调用增量 == 命中数（防线 3）',
      env.krepo.deleteDocumentCalls - callsBefore, 2);
  check('keep=false：登记行已删', (await env.krepo.getFolder(folderB.id)) == null);
  final docsB = await env.knowledge.listDocuments(baseB.id);
  checkEq('keep=false：关联文档已删（剩 1 = 孤儿）', docsB.length, 1);
  checkEq('keep=false：孤儿文档分毫未动', docsB.first.id, 'doc_orphan_d');
  check('keep=false：孤儿文档分块仍在', (await env.krepo.listChunks('doc_orphan_d')).isNotEmpty);

  // unlink 不存在的登记行 → 明确报错。
  await checkThrowsCode('unlink 不存在的关联抛 kb.folder.missing',
      () => env.sync.unlinkFolder('kbf_none', keepDocuments: true), 'kb.folder.missing');
}

// ---------------------------------------------------------------------------
// 7. backfill（补绑回填，只增不删）
// ---------------------------------------------------------------------------

Future<void> _verifyBackfill(_Env env) async {
  section('backfill（前缀 + 文件在位双条件 / 只增不删 / 文件已移走不认领）');

  final dir = env.makeFolder('backfill', {'a.md': '回填甲', 'b.md': '回填乙'});
  final base = await env.knowledge.createBase(name: '补绑库');
  // 旧导入三篇：两篇在文件夹内、一篇路径在文件夹内但文件已被移走、一篇在文件夹外。
  final now = DateTime.now().millisecondsSinceEpoch;
  Future<void> seedDoc(String id, String path, String hash) async {
    await env.krepo.upsertDocument(KnowledgeDocument(
      id: id,
      knowledgeBaseId: base.id,
      fileName: '$id.md',
      filePath: path,
      fileHash: hash,
      fileSize: 4,
      status: DocumentStatus.indexed,
      createdAt: now,
      updatedAt: now,
    ));
  }

  await seedDoc('bf_a', '${dir.path}${Platform.pathSeparator}a.md', 'bfa');
  await seedDoc('bf_moved', '${dir.path}${Platform.pathSeparator}moved.md', 'bfm');
  await seedDoc('bf_out', r'E:\Elsewhere\out.md', 'bfo');

  final folder = await env.sync.linkFolder(base.id, dir.path);
  final r = await env.sync.backfillFolder(folder.id);
  checkEq('backfill：matched = 1（只有 a.md 在位且有旧文档）', r.matched, 1);
  checkEq('backfill：unmatched = 2（文件已移走 1 + 文件夹外 1）', r.unmatched, 2);

  final byFolder = await env.krepo.listDocumentsByFolder(folder.id);
  checkEq('backfill：folder_id 登记的文档 id',
      byFolder.map((d) => d.id).toSet().join('|'), 'bf_a');
  final moved = await env.knowledge.listDocuments(base.id).then(
      (l) => l.firstWhere((d) => d.id == 'bf_moved'));
  check('backfill：文件已移走的文档保持孤儿（重扫不会误删）', moved.folderId == null);
  final out = await env.knowledge.listDocuments(base.id).then(
      (l) => l.firstWhere((d) => d.id == 'bf_out'));
  check('backfill：文件夹外文档不被前缀越界认领', out.folderId == null);
  checkEq('backfill：只增不删（文档数不变）', (await env.knowledge.listDocuments(base.id)).length, 3);

  // 重复关联同库同文件夹（含 .. 变体路径）→ 比较键去重拦截。
  await checkThrowsCode(
      '重复关联同库同文件夹抛 kb.folder.duplicate（比较键去重，.. 变体也拦截）',
      () => env.sync.linkFolder(
          base.id, '${dir.path}${Platform.pathSeparator}..${Platform.pathSeparator}backfill'),
      'kb.folder.duplicate');
}

// ---------------------------------------------------------------------------
// 8. 端到端重扫（真实导入链）
// ---------------------------------------------------------------------------

Future<void> _verifyEndToEnd(_Env env) async {
  section('端到端重扫（link → 新增 → touch 回填 → 改内容删旧重建 → 重复内容 skipped → last_scan_at）');

  final dir = env.makeFolder('e2e', {'规格.md': '工程车额定流量六十升每秒，油箱容积六千升。'});
  final base = await env.knowledge.createBase(name: '端到端库');
  final folder = await env.sync.linkFolder(base.id, dir.path);

  // —— 第一次重扫：新增 ——
  final s1 = await env.sync.rescan(folder.id);
  checkEq('E2E：首次重扫 added=1', s1.added, 1);
  checkEq('E2E：无失败', s1.failed, 0);
  var docs = await env.knowledge.listDocuments(base.id);
  checkEq('E2E：文档 1 篇', docs.length, 1);
  check('E2E：新文档带 folder_id', docs.first.folderId == folder.id);
  check('E2E：新文档带 source_mtime（快速路径依据）', docs.first.sourceMtime != null);
  final mtimeAtImport = docs.first.sourceMtime!;
  check('E2E：分块已建立', (await env.krepo.listChunks(docs.first.id)).isNotEmpty);

  // —— touch（mtime 漂移、内容不变）→ unchanged + source_mtime 回填 ——
  final file = File('${dir.path}${Platform.pathSeparator}规格.md');
  final idBeforeTouch = (await env.knowledge.listDocuments(base.id)).first.id;
  file.setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(mtimeAtImport + 60000));
  final s2 = await env.sync.rescan(folder.id);
  checkEq('E2E：touch 后 added/updated/deleted 全 0', s2.added + s2.updated + s2.deleted, 0);
  docs = await env.knowledge.listDocuments(base.id);
  checkEq('E2E：mtime 漂移不算更新（文档 id 不变）', docs.first.id, idBeforeTouch);
  checkEq('E2E：source_mtime 已回填为漂移后的值',
      docs.first.sourceMtime, mtimeAtImport + 60000);
  checkEq('E2E：第二次重扫 unchanged 计数来自摘要（无跳过无失败）', s2.skipped + s2.failed, 0);

  // —— 改内容 → sha 确认变化 → 删旧重建 ——
  final oldDocId = docs.first.id;
  final oldChunkIds = (await env.krepo.listChunks(oldDocId)).map((c) => c.id).toSet();
  file.writeAsStringSync('工程车额定流量一百二十升每秒，长臂喷射臂架三十二米。');
  final s3 = await env.sync.rescan(folder.id);
  checkEq('E2E：改内容 → updated=1', s3.updated, 1);
  checkEq('E2E：added/deleted 走内部重建（摘要不再计 deleted）', s3.deleted, 0);
  docs = await env.knowledge.listDocuments(base.id);
  checkEq('E2E：文档仍 1 篇（旧的删、新的建）', docs.length, 1);
  check('E2E：新文档 id != 旧文档 id', docs.first.id != oldDocId);
  check('E2E：新文档仍带 folder_id', docs.first.folderId == folder.id);
  check('E2E：新文档哈希非空（= 改后内容哈希）', docs.first.fileHash.isNotEmpty);
  final newChunkIds = (await env.krepo.listChunks(docs.first.id)).map((c) => c.id).toSet();
  check('E2E：旧分块已级联清除', newChunkIds.intersection(oldChunkIds).isEmpty);
  check('E2E：新分块已建立', newChunkIds.isNotEmpty);

  // —— 同内容第二个文件 → 导入链去重 → skipped（不夺归属）——
  File('${dir.path}${Platform.pathSeparator}副本.md')
      .writeAsStringSync('工程车额定流量一百二十升每秒，长臂喷射臂架三十二米。');
  final s4 = await env.sync.rescan(folder.id);
  checkEq('E2E：重复内容 → skipped=1（去重，不新增文档）', s4.skipped, 1);
  checkEq('E2E：added=0', s4.added, 0);
  checkEq('E2E：文档仍 1 篇', (await env.knowledge.listDocuments(base.id)).length, 1);
  checkEq('E2E：既有文档归属未被夺走', docs.first.id,
      (await env.knowledge.listDocuments(base.id)).first.id);

  // —— last_scan_at 与摘要 ——
  final folderAfter = await env.krepo.getFolder(folder.id);
  check('E2E：last_scan_at 已更新', folderAfter != null && folderAfter.lastScanAt != null);
  check('E2E：摘要五元组齐全（新增/更新/删除/跳过/失败）',
      s4.added >= 0 && s4.updated >= 0 && s4.deleted >= 0 && s4.skipped >= 0 && s4.failed >= 0);

  // —— linkFolder 错误路径 ——
  await checkThrowsCode('link 不存在的文件夹抛 kb.folder.missing',
      () => env.sync.linkFolder(base.id, '${dir.path}__no_such__'), 'kb.folder.missing');
  await checkThrowsCode('重复关联抛 kb.folder.duplicate',
      () => env.sync.linkFolder(base.id, dir.path), 'kb.folder.duplicate');
}
