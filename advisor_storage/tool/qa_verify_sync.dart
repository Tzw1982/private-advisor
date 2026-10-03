/// QA 独立验证脚本（严过关）—— 第 3/4 轮缺口填补（任务 #35 选项 A）。
///
/// 运行：`cd advisor_storage && dart run tool/qa_verify_sync.dart`
///
/// 覆盖（**不重跑工程师脚本**，独立构造断言）：
/// A. `import_batch`：扫描/过滤/递归、扩展名分类、50MB 边界、失败隔离、sha 去重、分批 yield
/// B. `FolderDiffCalculator`（纯逻辑）：五规则 + 保守性 + 路径键 + 前缀边界
/// C. `FolderSyncService`（集成）：link/unlink、**删除三防线**、孤儿文档保护、回填、
///    FTS 级联、以及**静态 grep 证明同步路径无整体批删入口**。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart'
    show InMemorySecretStore, SimpleChunker, InMemoryVectorStore;
import 'package:advisor_storage/advisor_storage.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架
// ---------------------------------------------------------------------------

class C {
  C(this.id, this.name, this.expected, this.actual, this.pass, [this.note]);
  final String id, name;
  final Object? expected, actual;
  final bool pass;
  final String? note;
}

final List<C> _res = [];
int _pass = 0, _fail = 0;

void t(String id, String name, Object? expected, Object? actual, {String? note}) {
  final ok = expected == actual;
  if (ok) {
    _pass++;
  } else {
    _fail++;
  }
  _res.add(C(id, name, expected, actual, ok, note));
  stdout.writeln('  ${ok ? '✓' : '✗'} [$id] $name  (期望=$expected 实际=$actual)');
}

void section(String s) => stdout.writeln('\n── $s ──────────────────────────');

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// **async\* 惰性护栏**：`executeRescan` 是 `async*`（惰性 Stream），
/// `await stream` 只是拿到 Stream 对象，**函数体（含删除三防线 guard）根本不会执行**。
/// 必须消费它（`foreach`/`toList`/`await for`）才会真正跑，错误也才在此处抛出。
/// 所有 `executeRescan` 调用点统一走本 helper，杜绝“未消费 → 假绿/假红”。
Future<void> _drain(Stream<dynamic> stream) => stream.forEach((_) {});

late Directory _tmp;

String _p(String rel) => '${_tmp.path}${Platform.pathSeparator}$rel';

void _writeFile(String path, String content) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
}

int _countDocRows(Database db, {String? kb, String? folderId, bool orphanOnly = false}) {
  final where = <String>[];
  final params = <Object?>[];
  if (kb != null) {
    where.add('knowledge_base_id = ?');
    params.add(kb);
  }
  if (folderId != null) {
    where.add('folder_id = ?');
    params.add(folderId);
  }
  if (orphanOnly) where.add('folder_id IS NULL');
  final w = where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';
  return (db.select('SELECT COUNT(*) AS c FROM knowledge_documents$w', params).first['c'] as num)
      .toInt();
}

FolderSyncService _mkSync(Database db) {
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final knowledge = KnowledgeService(
    repos,
    parsers: [const PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 120),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    retriever: Fts5Retriever(db),
  );
  return FolderSyncService(repos, knowledge: knowledge);
}

ScannedFile _sf(String path, int size, [String? ext]) => ScannedFile(
      path: path,
      name: path.split(RegExp(r'[\\/]')).last,
      sizeBytes: size,
      extension: ext ?? DirectoryScanner.extensionOf(path),
    );

Future<List<ImportProgress>> _collect(
  BatchImporter importer,
  ImportPlan plan, {
  required Future<ImportFileResult> Function(ScannedFile) importFile,
}) async {
  final fs = <ImportProgress>[];
  await for (final fr in importer.run(plan: plan, importFile: importFile)) {
    fs.add(fr);
  }
  return fs;
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  stdout.writeln('严过关 · QA 独立验证（import_batch + folder_sync）');
  stdout.writeln('=' * 62);
  stdout.writeln('sqlite3 = ${sqlite3.version.libVersion}');

  _tmp = Directory.systemTemp.createTempSync('pa_qa_sync_');

  await _a_importBatch();
  _b_diffCalculator();
  await _c_staticNoBatchDelete();
  await _c_linkAndRescan();
  await _c_deleteDefenses();
  await _c_orphansAndUnlink();
  await _c_backfill();

  _print();
  try {
    _tmp.deleteSync(recursive: true);
  } catch (_) {}
  exitCode = _fail == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// A. import_batch（纯逻辑 + 异步流）
// ---------------------------------------------------------------------------

Future<void> _a_importBatch() async {
  section('A import_batch：扫描/过滤/分类/50MB/失败隔离/去重/分批');

  final root = _p('A/root');
  _writeFile('$root${Platform.pathSeparator}a.md', 'A');
  _writeFile('$root${Platform.pathSeparator}b.txt', 'B');
  _writeFile('$root${Platform.pathSeparator}c.doc', 'C');
  _writeFile('$root${Platform.pathSeparator}.hidden.md', 'H');
  _writeFile('$root${Platform.pathSeparator}~\$lock.docx', 'L');
  _writeFile('$root${Platform.pathSeparator}Thumbs.db', 'T');
  _writeFile('$root${Platform.pathSeparator}desktop.ini', 'D');
  _writeFile('$root${Platform.pathSeparator}x.tmp', 'X');
  _writeFile('$root${Platform.pathSeparator}sub${Platform.pathSeparator}d.md', 'D2');
  _writeFile('$root${Platform.pathSeparator}.git${Platform.pathSeparator}e.md', 'E');

  // A1 isIgnored
  t('A1.1', 'isIgnored(.hidden.md)', true, DirectoryScanner.isIgnored('.hidden.md'));
  t('A1.2', r'isIgnored(~$lock.docx)', true, DirectoryScanner.isIgnored(r'~$lock.docx'));
  t('A1.3', 'isIgnored(Thumbs.db)', true, DirectoryScanner.isIgnored('Thumbs.db'));
  t('A1.4', 'isIgnored(desktop.ini)', true, DirectoryScanner.isIgnored('desktop.ini'));
  t('A1.5', 'isIgnored(x.tmp)', true, DirectoryScanner.isIgnored('x.tmp'));
  t('A1.6', 'isIgnored(a.md)', false, DirectoryScanner.isIgnored('a.md'));

  // A2 递归扫描
  final rec = DirectoryScanner.scan([root]).map((f) => f.name).toList()..sort();
  t('A2.1', '递归扫描命中文件数', 4, rec.length, note: '$rec');
  t('A2.2', '递归扫描跳过 .git 目录', false, rec.contains('e.md'));

  // A3 非递归
  final flat = DirectoryScanner.scan([root], recursive: false).map((f) => f.name).toList()..sort();
  t('A3.1', '非递归只取顶层', 3, flat.length, note: '$flat');

  // A4 扩展名分类（supported = {.md}）
  final plan = ImportPlanner.plan([root], supportedExtensions: {'.md'});
  t('A4.1', 'supported 数', 2, plan.supported.length);
  t('A4.2', 'unsupported 数', 2, plan.unsupported.length);
  t('A4.3', 'total', 4, plan.total);

  // A5 50MB 边界（恰好 = 上限 → 支持；+1 → 超限）
  const cap = kMaxImportBytes;
  final bPlan = ImportPlanner.planFiles(
    [_sf(r'E:\x\exact.md', cap), _sf(r'E:\x\over.md', cap + 1)],
    supportedExtensions: {'.md'},
  );
  t('A5.1', '恰好 50MB → supported', 1, bPlan.supported.length);
  t('A5.2', '50MB+1 → oversize', 1, bPlan.oversize.length);

  final mixPlan = ImportPlanner.planFiles(
    [_sf(r'E:\x\ok.md', 10), _sf(r'E:\x\big.md', cap + 1), _sf(r'E:\x\bad.doc', 10)],
    supportedExtensions: {'.md'},
  );
  t('A5.3', 'rejectedCount = oversize + unsupported', 2, mixPlan.rejectedCount);

  // A6 分批 yield：120 文件，batchSize=50 → 帧数 = 初始 + 50 + 100 + done
  final many = ImportPlan(
    supported: List.generate(120, (i) => _sf('E:\\x\\f$i.md', 1)),
    unsupported: const [],
    oversize: const [],
  );
  final frames = await _collect(BatchImporter(batchSize: 50), many,
      importFile: (f) async => ImportFileResult.success(chunkCount: 1));
  t('A6.1', '120 文件（batchSize=50）yield 帧数', 4, frames.length);
  t('A6.2', '末帧 done=true', true, frames.last.done);
  t('A6.3', '末帧 processed=120', 120, frames.last.processed);
  t('A6.4', '末帧 success=120', 120, frames.last.success);

  // A7 失败隔离：第 2 个抛异常，整批不中断
  final three = ImportPlan(
    supported: [_sf(r'E:\x\1.md', 1), _sf(r'E:\x\2.md', 1), _sf(r'E:\x\3.md', 1)],
    unsupported: const [],
    oversize: const [],
  );
  var call = 0;
  final fs7 = await _collect(BatchImporter(), three, importFile: (f) async {
    call++;
    if (call == 2) throw StateError('boom');
    return ImportFileResult.success(chunkCount: 2);
  });
  t('A7.1', '失败隔离：整批跑完 done', true, fs7.last.done);
  t('A7.2', 'success=2', 2, fs7.last.success);
  t('A7.3', 'failed=1（异常记为 failed 且不中断）', 1, fs7.last.failed);
  t('A7.4', 'processed=3', 3, fs7.last.processed);

  // A8 去重跳过
  final fs8 = await _collect(BatchImporter(), three,
      importFile: (f) async => ImportFileResult.skipped('sha 重复'));
  t('A8.1', 'skipped=3', 3, fs8.last.skipped);
  t('A8.2', 'success=0', 0, fs8.last.success);

  // A9 计划阶段拒绝项：进 entries、计 failed、置于 perFile 之前
  final mix = ImportPlanner.planFiles(
    [_sf(r'E:\x\ok.md', 10), _sf(r'E:\x\big.md', kMaxImportBytes + 1), _sf(r'E:\x\bad.doc', 10)],
    supportedExtensions: {'.md'},
  );
  final fs9 =
      await _collect(BatchImporter(), mix, importFile: (f) async => ImportFileResult.success());
  t('A9.1', '初始帧已含 2 条拒绝项（processed=2）', 2, fs9.first.processed);
  t('A9.2', '初始帧 failed=2', 2, fs9.first.failed);
  t('A9.3', '末帧 processed=3', 3, fs9.last.processed);
  t('A9.4', '末帧 success=1 / failed=2', '1/2', '${fs9.last.success}/${fs9.last.failed}');
}

// ---------------------------------------------------------------------------
// B. FolderDiffCalculator（纯逻辑）
// ---------------------------------------------------------------------------

KnowledgeDocument _doc(String id, String path,
        {int size = 5,
        int? mtime,
        DocumentStatus status = DocumentStatus.indexed,
        String hash = 'H'}) =>
    KnowledgeDocument(
      id: id,
      knowledgeBaseId: 'kb',
      fileName: path.split(RegExp(r'[\\/]')).last,
      filePath: path,
      fileHash: hash,
      fileSize: size,
      status: status,
      sourceMtime: mtime,
      createdAt: 0,
      updatedAt: 0,
    );

ScannedFileStat _stat(String path, int size, int mtime) => ScannedFileStat(
    path: path, name: path.split(RegExp(r'[\\/]')).last, sizeBytes: size, mtimeMs: mtime);

void _b_diffCalculator() {
  section('B FolderDiffCalculator（纯逻辑：五规则 / 保守性 / 路径键 / 前缀边界）');

  final r1 = FolderDiffCalculator.compute(
    files: [_stat(r'E:\D\new.md', 5, 100)],
    existing: const [],
    readHash: (_) => 'H',
  );
  t('B1.1', '新文件 → added', 1, r1.added.length);
  t('B1.2', '无既有 → deleted=0', 0, r1.deleted.length);

  var readCalls = 0;
  final r2 = FolderDiffCalculator.compute(
    files: [_stat(r'E:\D\a.md', 5, 100)],
    existing: [_doc('d_a', r'E:\D\a.md', size: 5, mtime: 100)],
    readHash: (_) {
      readCalls++;
      return 'H';
    },
  );
  t('B2.1', '快速路径 → unchanged', 1, r2.unchanged.length);
  t('B2.2', '快速路径零内容读取（readHash 未调用）', 0, readCalls);

  readCalls = 0;
  final r3 = FolderDiffCalculator.compute(
    files: [_stat(r'E:\D\a.md', 5, 999)],
    existing: [_doc('d_a', r'E:\D\a.md', size: 5, mtime: 100, hash: 'SAME')],
    readHash: (_) {
      readCalls++;
      return 'SAME';
    },
  );
  t('B3.1', 'mtime 漂移 + sha 同 → unchanged', 1, r3.unchanged.length);
  t('B3.2', '此路径读取了 sha（readHash 调用 1 次）', 1, readCalls);

  final r4 = FolderDiffCalculator.compute(
    files: [_stat(r'E:\D\a.md', 7, 200)],
    existing: [_doc('d_a', r'E:\D\a.md', size: 5, mtime: 100, hash: 'OLD')],
    readHash: (_) => 'NEW',
  );
  t('B4.1', 'sha 变 → updated=1', 1, r4.updated.length);
  t('B4.2', 'updated 携带精确 documentId', 'd_a',
      r4.updated.isEmpty ? null : r4.updated.first.documentId);

  final r5 = FolderDiffCalculator.compute(
    files: [_stat(r'E:\D\a.md', 5, 100)],
    existing: [_doc('d_f', r'E:\D\a.md', size: 5, mtime: 100, status: DocumentStatus.failed)],
    readHash: (_) => 'H',
  );
  t('B5.1', 'failed 且文件在 → updated（重试）', 1, r5.updated.length);

  final r6 = FolderDiffCalculator.compute(
    files: [_stat(r'E:\D\b.md', 5, 100)],
    existing: [_doc('d_gone', r'E:\D\gone.md', size: 5, mtime: 100)],
    readHash: (_) => 'H',
  );
  t('B6.1', '既有文档 FS 不存在 → deleted=1', 1, r6.deleted.length);
  t('B6.2', 'deleted 携带精确 id', 'd_gone',
      r6.deleted.isEmpty ? null : r6.deleted.first.documentId);

  final r7 = FolderDiffCalculator.compute(
    files: [_stat(r'E:\D\a.md', 9, 300)],
    existing: [_doc('d_a', r'E:\D\a.md', size: 5, mtime: 100)],
    readHash: (_) => null,
  );
  t('B7.1', '读取失败 → 保守 unchanged', 1, r7.unchanged.length);
  t('B7.2', '绝不因读取抖动误判 updated', 0, r7.updated.length);

  final r8 = FolderDiffCalculator.compute(
    files: [_stat(r'e:\d\a.md', 5, 100)],
    existing: [
      _doc('first', r'E:\D\a.md', size: 5, mtime: 100),
      _doc('dup', r'e:\d\A.md', size: 5, mtime: 100),
    ],
    readHash: (_) => 'SAME',
  );
  t('B8.1', '同 folderKey 去重（不重复计入）', 1, r8.unchanged.length);
  t('B8.2', '同键取先到者 id', 'first',
      r8.unchanged.isEmpty ? null : r8.unchanged.first.documentId);

  t('B9.1', 'E:\\Docs\\a.md 在 E:\\Docs 之下', true, isUnderFolder(r'E:\Docs\a.md', r'E:\Docs'));
  t('B9.2', 'E:\\Docs2\\a.md 不误匹配 E:\\Docs（分隔符边界）', false,
      isUnderFolder(r'E:\Docs2\a.md', r'E:\Docs'));
  t('B9.3', '前缀判定大小写不敏感', true, isUnderFolder(r'e:\docs\SUB\x.md', r'E:\DOCS'));
}

// ---------------------------------------------------------------------------
// C. FolderSyncService（集成）
// ---------------------------------------------------------------------------

Future<void> _c_staticNoBatchDelete() async {
  section('C0 删除铁律 / 归属铁律（静态 grep：同步路径无整体批删入口）');
  final candidates = [
    '../advisor_core/lib/application/folder_sync.dart',
    r'E:\APP\私人顾问团\advisor_core\lib\application\folder_sync.dart',
  ];
  File? f;
  for (final c in candidates) {
    if (File(c).existsSync()) {
      f = File(c);
      break;
    }
  }
  if (f == null) {
    t('C0.0', '找到 folder_sync.dart', true, false, note: '跳过 grep');
    return;
  }
  final src = f.readAsStringSync();
  t('C0.1', '同步路径无 deleteByKnowledgeBase', false, src.contains('deleteByKnowledgeBase'));
  t('C0.2', '同步路径无按库整体批删仓储入口', false,
      RegExp(r'deleteDocuments?\w*ByKnowledgeBase').hasMatch(src));
  t('C0.3', '删除走精确 deleteDocument(id)', true, src.contains('_knowledge.deleteDocument('));
  t('C0.4', '前缀判定仅用于 backfill/rescan（isUnderFolder 存在）', true,
      src.contains('isUnderFolder'));
}

Future<void> _c_linkAndRescan() async {
  section('C1 link / 重扫：新增 / 未变快速路径 / 内容更新 / 新文件');
  final db = openAdvisorDatabase(_p('C1.sqlite'));
  ensureSchema(db);
  final sync = _mkSync(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  await repos.knowledge
      .upsertBase(KnowledgeBase(id: 'kbC1', name: 'C1', createdAt: 1, updatedAt: 1));

  final dir = _p('C1/folder');
  _writeFile('$dir${Platform.pathSeparator}a.md', '# A\n油箱容积六千升');
  _writeFile('$dir${Platform.pathSeparator}b.md', '# B\n液压泵额定流量');

  Object? e1;
  try {
    await sync.linkFolder('kbC1', _p('C1/nope'));
  } catch (e) {
    e1 = e;
  }
  t('C1.1', 'link 缺失目录 → KnowledgeError(kb.folder.missing)', 'kb.folder.missing',
      e1 is KnowledgeError ? e1.code : '${e1.runtimeType}');

  final folder = await sync.linkFolder('kbC1', dir);
  t('C1.2', 'link 后 folderPath = 比较键（小写）', folderKey(dir), folder.folderPath);
  t('C1.3', 'link 后 displayPath 原样', dir, folder.displayPath);

  Object? e2;
  try {
    await sync.linkFolder('kbC1', '$dir${Platform.pathSeparator}');
  } catch (e) {
    e2 = e;
  }
  t('C1.4', '重复关联被拒 kb.folder.duplicate', 'kb.folder.duplicate',
      e2 is KnowledgeError ? e2.code : '${e2.runtimeType}');

  final s1 = await sync.rescan(folder.id);
  t('C1.5', '首次重扫 added=2', 2, s1.added);
  t('C1.6', '库内文档=2 且 folder_id 已登记', 2, _countDocRows(db, folderId: folder.id));

  final plan2 = await sync.planRescan(folder.id);
  t('C1.7', '无变化：added/updated/deleted 均 0', '0/0/0',
      '${plan2.added.length}/${plan2.updated.length}/${plan2.deleted.length}');
  t('C1.8', '无变化：unchangedCount=2', 2, plan2.unchangedCount);

  await Future<void>.delayed(const Duration(milliseconds: 5));
  _writeFile('$dir${Platform.pathSeparator}a.md', '# A\n油箱容积九千升（已改）');
  final plan3 = await sync.planRescan(folder.id);
  t('C1.9', '内容变化 → updated=1', 1, plan3.updated.length);
  final s3 = await sync.rescan(folder.id, confirmDeletes: true);
  t('C1.10', '更新执行后 updated=1', 1, s3.updated);
  t('C1.11', '更新后文档总数不变（=2，旧删新入）', 2, _countDocRows(db, kb: 'kbC1'));

  _writeFile('$dir${Platform.pathSeparator}c.md', '# C\n长臂喷射臂架');
  final s4 = await sync.rescan(folder.id);
  t('C1.12', '新文件 added=1', 1, s4.added);
  t('C1.13', '文档总数=3', 3, _countDocRows(db, kb: 'kbC1'));

  db.dispose();
}

Future<void> _c_deleteDefenses() async {
  section('C2 删除三防线（失联零删除 / 大比例 dry-run / 精确逐删）');
  final db = openAdvisorDatabase(_p('C2.sqlite'));
  ensureSchema(db);
  final sync = _mkSync(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  await repos.knowledge
      .upsertBase(KnowledgeBase(id: 'kbC2', name: 'C2', createdAt: 1, updatedAt: 1));

  final dir = _p('C2/folder');
  for (final n in ['a', 'b', 'c', 'd']) {
    _writeFile('$dir${Platform.pathSeparator}$n.md', '# $n\n内容 $n 油箱工程车');
  }
  final folder = await sync.linkFolder('kbC2', dir);
  await sync.rescan(folder.id);
  t('C2.1', '前置：4 篇文档已入库', 4, _countDocRows(db, folderId: folder.id));

  final moved = _p('C2/folder_moved');
  Directory(dir).renameSync(moved);
  final planMissing = await sync.planRescan(folder.id);
  t('C2.2', '失联：abortedReason=folder_missing', 'folder_missing', planMissing.abortedReason);
  t('C2.3', '失联：计划 deleted 为空', 0, planMissing.deleted.length);
  t('C2.4', '失联：planRescan 后库内文档一条未少（裸SQL=4）', 4,
      _countDocRows(db, folderId: folder.id));
  Object? em;
  try {
    await _drain(sync.executeRescan(planMissing)); // async* 惰性：必须消费才触发 guard
  } catch (e) {
    em = e;
  }
  t('C2.5', '失联：executeRescan 抛 kb.folder.missing', 'kb.folder.missing',
      em is KnowledgeError ? em.code : '${em.runtimeType}');
  t('C2.6', '失联：execute 后仍 4 篇（零删除铁证）', 4, _countDocRows(db, folderId: folder.id));

  Directory(moved).renameSync(dir);

  File('$dir${Platform.pathSeparator}b.md').deleteSync();
  File('$dir${Platform.pathSeparator}c.md').deleteSync(); // 4 删 2 → 50%
  final plan3 = await sync.planRescan(folder.id);
  t('C2.7', 'deleted=2', 2, plan3.deleted.length);
  t('C2.8', 'needsConfirmation=true（2/4 ≥0.5）', true, plan3.needsConfirmation);
  t('C2.9', 'dry-run：计划后库内仍 4 篇（未执行删除）', 4, _countDocRows(db, folderId: folder.id));

  Object? ec;
  try {
    await _drain(sync.executeRescan(plan3)); // async* 惰性：必须消费才触发 guard（原缺陷：漏消费 → guard 未跑 → ec=Null）
  } catch (e) {
    ec = e;
  }
  t('C2.10', '未确认执行 → 抛 kb.folder.abort_deletes', 'kb.folder.abort_deletes',
      ec is KnowledgeError ? ec.code : '${ec.runtimeType}');
  t('C2.11', '未确认执行后库内仍 4 篇（确实没删）', 4, _countDocRows(db, folderId: folder.id));

  final sConfirmed = await sync.rescan(folder.id, confirmDeletes: true);
  t('C2.12', '确认后 deleted=2', 2, sConfirmed.deleted);
  t('C2.13', '确认后库内剩 2 篇', 2, _countDocRows(db, folderId: folder.id));

  File('$dir${Platform.pathSeparator}a.md').deleteSync(); // 2 删 1 → ratio=0.5 边界
  final planSmall = await sync.planRescan(folder.id);
  t('C2.14', '边界：2 删 1（ratio=0.5）仍 needsConfirmation', true, planSmall.needsConfirmation);
  Object? eb;
  try {
    await sync.rescan(folder.id);
  } catch (e) {
    eb = e;
  }
  t('C2.15', 'ratio 达界 → rescan() 未确认抛 abort_deletes', 'kb.folder.abort_deletes',
      eb is KnowledgeError ? eb.code : '${eb.runtimeType}');
  t('C2.16', '拦截后仍 2 篇', 2, _countDocRows(db, folderId: folder.id));

  db.dispose();
}

Future<void> _c_orphansAndUnlink() async {
  section('C3 孤儿文档保护 + unlink 双路径 + FTS 级联');
  final db = openAdvisorDatabase(_p('C3.sqlite'));
  ensureSchema(db);
  final sync = _mkSync(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  await repos.knowledge
      .upsertBase(KnowledgeBase(id: 'kbC3', name: 'C3', createdAt: 1, updatedAt: 1));

  final dir = _p('C3/folder');
  _writeFile('$dir${Platform.pathSeparator}a.md', '# A\n油箱六千升');
  _writeFile('$dir${Platform.pathSeparator}b.md', '# B\n液压泵流量');
  final folder = await sync.linkFolder('kbC3', dir);
  await sync.rescan(folder.id);
  t('C3.1', '前置：2 篇 folder 文档', 2, _countDocRows(db, folderId: folder.id));

  _writeFile('$dir${Platform.pathSeparator}orphan.md', '# O\n孤儿内容');
  await repos.knowledge.upsertDocument(KnowledgeDocument(
    id: 'doc_orphan',
    knowledgeBaseId: 'kbC3',
    fileName: 'orphan.md',
    filePath: '$dir${Platform.pathSeparator}orphan.md',
    fileHash: 'HORPHAN',
    fileSize: 5,
    status: DocumentStatus.indexed,
    createdAt: 1,
    updatedAt: 1,
  ));
  File('$dir${Platform.pathSeparator}orphan.md').deleteSync();
  t('C3.2', '孤儿文档已建（folder_id IS NULL）', 1, _countDocRows(db, kb: 'kbC3', orphanOnly: true));

  final plan = await sync.planRescan(folder.id);
  final deletedIds = plan.deleted.map((d) => d.documentId).toSet();
  t('C3.3', '重扫 deleted 不含孤儿', false, deletedIds.contains('doc_orphan'));
  final s = await sync.rescan(folder.id, confirmDeletes: true);
  t('C3.4', '重扫后孤儿文档仍在库', 1, _countDocRows(db, kb: 'kbC3', orphanOnly: true));
  t('C3.5', '重扫未误删 folder 文档', 2, _countDocRows(db, folderId: folder.id));
  t('C3.6', '重扫 added/updated/deleted=0', '0/0/0', '${s.added}/${s.updated}/${s.deleted}');

  final keep = await sync.unlinkFolder(folder.id, keepDocuments: true);
  t('C3.7', 'unlink(keep) 影响 2 篇', 2, keep.affectedDocuments);
  t('C3.8', 'unlink(keep) 后 folder 登记行已删', true,
      (await repos.knowledge.getFolder(folder.id)) == null);
  t('C3.9', 'unlink(keep) 文档保留（转孤儿）', 3, _countDocRows(db, kb: 'kbC3'));
  t('C3.10', 'unlink(keep) 后无 folder 文档', 0, _countDocRows(db, folderId: folder.id));

  final dir2 = _p('C3/folder2');
  _writeFile('$dir2${Platform.pathSeparator}x.md', '# X\n长臂喷射臂架系统');
  _writeFile('$dir2${Platform.pathSeparator}y.md', '# Y\n油箱容积参数');
  final folder2 = await sync.linkFolder('kbC3', dir2);
  await sync.rescan(folder2.id);
  final delDocs = await repos.knowledge.listDocumentsByFolder(folder2.id);
  final delIds = delDocs.map((d) => d.id).toList();
  final ftsBefore = (db
          .select('SELECT COUNT(*) c FROM knowledge_chunks_fts WHERE document_id IN (?,?)',
              delIds.length >= 2 ? [delIds[0], delIds[1]] : [delIds[0], delIds[0]])
          .first['c'] as num)
      .toInt();
  t('C3.11', 'unlink(delete) 前 FTS 有该文档行', true, ftsBefore > 0, note: 'fts=$ftsBefore');

  final del = await sync.unlinkFolder(folder2.id, keepDocuments: false);
  t('C3.12', 'unlink(delete) 影响 2 篇', 2, del.affectedDocuments);
  t('C3.13', 'unlink(delete) 后 kbC3 只剩之前 3 篇孤儿', 3, _countDocRows(db, kb: 'kbC3'));
  final ftsAfter = (db
          .select('SELECT COUNT(*) c FROM knowledge_chunks_fts WHERE document_id IN (?,?)',
              delIds.length >= 2 ? [delIds[0], delIds[1]] : [delIds[0], delIds[0]])
          .first['c'] as num)
      .toInt();
  t('C3.14', 'unlink(delete) 后 FTS 该文档行已级联清除', 0, ftsAfter);

  Object? eu;
  try {
    await sync.unlinkFolder('nope', keepDocuments: true);
  } catch (e) {
    eu = e;
  }
  t('C3.15', 'unlink 不存在 → kb.folder.missing', 'kb.folder.missing',
      eu is KnowledgeError ? eu.code : '${eu.runtimeType}');

  db.dispose();
}

Future<void> _c_backfill() async {
  section('C4 补绑回填（只增不删；文件不在位不认领）');
  final db = openAdvisorDatabase(_p('C4.sqlite'));
  ensureSchema(db);
  final sync = _mkSync(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  await repos.knowledge
      .upsertBase(KnowledgeBase(id: 'kbC4', name: 'C4', createdAt: 1, updatedAt: 1));

  final dir = _p('C4/folder');
  _writeFile('$dir${Platform.pathSeparator}present.md', '# P\n在位文件油箱');
  final folder = await sync.linkFolder('kbC4', dir);

  await repos.knowledge.upsertDocument(KnowledgeDocument(
    id: 'orphan_in',
    knowledgeBaseId: 'kbC4',
    fileName: 'present.md',
    filePath: '$dir${Platform.pathSeparator}present.md',
    fileHash: 'HP',
    fileSize: 5,
    status: DocumentStatus.indexed,
    createdAt: 1,
    updatedAt: 1,
  ));
  await repos.knowledge.upsertDocument(KnowledgeDocument(
    id: 'orphan_out',
    knowledgeBaseId: 'kbC4',
    fileName: 'moved.md',
    filePath: '$dir${Platform.pathSeparator}moved.md',
    fileHash: 'HM',
    fileSize: 5,
    status: DocumentStatus.indexed,
    createdAt: 1,
    updatedAt: 1,
  ));

  final bf = await sync.backfillFolder(folder.id);
  t('C4.1', '回填认领 1（在位者）', 1, bf.matched);
  t('C4.2', '仍孤儿 1（文件已移走不认领）', 1, bf.unmatched);
  t('C4.3', 'orphan_in 已归属该 folder', 1, _countDocRows(db, folderId: folder.id));
  t('C4.4', 'orphan_out 仍为孤儿', 1, _countDocRows(db, kb: 'kbC4', orphanOnly: true));
  t('C4.5', '回填只增不删（文档总数 2）', 2, _countDocRows(db, kb: 'kbC4'));

  Directory(dir).renameSync(_p('C4/folder_moved'));
  Object? eb;
  try {
    await sync.backfillFolder(folder.id);
  } catch (e) {
    eb = e;
  }
  t('C4.6', '失联回填 → kb.folder.missing', 'kb.folder.missing',
      eb is KnowledgeError ? eb.code : '${eb.runtimeType}');

  db.dispose();
}

// ---------------------------------------------------------------------------

void _print() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('# QA 用例表（import_batch + folder_sync）');
  stdout.writeln('| ID | 用例 | 期望 | 实际 | 结论 |');
  stdout.writeln('|----|------|------|------|------|');
  for (final r in _res) {
    stdout.writeln('| ${r.id} | ${r.name} | ${'${r.expected}'.replaceAll('|', r'\|')} | '
        '${'${r.actual}'.replaceAll('|', r'\|')} | ${r.pass ? 'PASS' : 'FAIL'} |');
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
