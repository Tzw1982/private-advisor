/// 第 4 轮存储层验证（纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_storage && dart run tool/verify_round4.dart`
///
/// 覆盖：
/// 1. **v3 → v4 迁移**：构造真实 v3 库（业务数据在库、两列不存在）→ `ensureSchema`
///    → 版本 4 + `knowledge_base_folders` 表 + `folder_id`/`source_mtime` 两列 +
///    旧数据无损；幂等重跑；**版本回退重跑**（user_version 手动回退后不得重复
///    ALTER 报错——`_addColumnIfMissing` 双保险）；
/// 2. **文件夹仓储 7 方法**：upsert/get/list/delete + UNIQUE 拦截 + listDocumentsByFolder
///    + assignDocumentsFolder（填值 / 置 NULL）+ updateSourceMtime + 文档两列 roundtrip；
/// 3. **级联语义**：knowledge_base_folders 对 knowledge_bases 的 DB 级 CASCADE；
///    folder 行删除**不**级联文档（逻辑外键，处置权在服务层）。
///
/// SQLite 原生库：验证脚本使用系统 `winsqlite3.dll`（与 verify_storage 一致）。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart' show InMemorySecretStore;
import 'package:advisor_storage/advisor_storage.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

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

bool _columnExists(Database db, String table, String column) {
  final rows = db.select('PRAGMA table_info($table)');
  return rows.any((r) => (r['name'] as String?) == column);
}

bool _tableExists(Database db, String table) => db
    .select("SELECT name FROM sqlite_master WHERE type='table' AND name = ?", [table])
    .isNotEmpty;

// ---------------------------------------------------------------------------
// v3 库构造（真实迁移场景：表已存在、缺 v4 两列、含业务数据）
// ---------------------------------------------------------------------------

/// 手工建一张 v3 形态的 `knowledge_documents`（无 folder_id / source_mtime）+
/// `knowledge_bases`，写入一行业务数据，user_version 置 3。
Database _createV3Database(String path) {
  final db = sqlite3.open(path);
  db.execute('PRAGMA foreign_keys = ON;');
  db.execute('PRAGMA user_version = 3;');
  db.execute('''
    CREATE TABLE knowledge_bases (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT,
        type TEXT NOT NULL DEFAULT 'local_folder',
        embedding_model_id TEXT,
        index_path TEXT,
        status TEXT NOT NULL DEFAULT 'idle',
        file_count INTEGER DEFAULT 0,
        chunk_count INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    )
  ''');
  db.execute('''
    CREATE TABLE knowledge_documents (
        id TEXT PRIMARY KEY,
        knowledge_base_id TEXT NOT NULL,
        file_name TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_hash TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        mime_type TEXT,
        parser TEXT,
        parser_version TEXT,
        status TEXT NOT NULL,
        page_count INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE (knowledge_base_id, file_hash),
        FOREIGN KEY (knowledge_base_id) REFERENCES knowledge_bases(id) ON DELETE CASCADE
    )
  ''');
  db.execute('''
    INSERT INTO knowledge_bases (id, name, created_at, updated_at)
    VALUES ('kb_v3', 'v3旧库', 100, 100)
  ''');
  db.execute('''
    INSERT INTO knowledge_documents
      (id, knowledge_base_id, file_name, file_path, file_hash, file_size, status,
       created_at, updated_at)
    VALUES
      ('doc_v3_a', 'kb_v3', '旧文档A.md', 'E:\\Docs\\A.md', 'hashA', 10, 'indexed', 101, 101),
      ('doc_v3_b', 'kb_v3', '旧文档B.md', 'E:\\Docs\\B.md', 'hashB', 20, 'indexed', 102, 102)
  ''');
  return db;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));

  stdout.writeln('私人顾问团 · 第 4 轮存储验证（advisor_storage / v4 迁移 + 文件夹仓储）');
  stdout.writeln('=' * 60);
  stdout.writeln('sqlite3 版本 = ${sqlite3.version.libVersion}');

  final tmpDir = Directory.systemTemp.createTempSync('pa_round4_verify_');

  await _verifyMigration(tmpDir);
  await _verifyFolderRepository(tmpDir);
  await _verifyCascadeSemantics(tmpDir);

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

  try {
    tmpDir.deleteSync(recursive: true);
  } catch (_) {
    // 忽略清理失败（WAL 文件可能仍被占用）。
  }
}

// ---------------------------------------------------------------------------
// 1. v3 → v4 迁移（含幂等与版本回退重跑）
// ---------------------------------------------------------------------------

Future<void> _verifyMigration(Directory tmpDir) async {
  section('v3 → v8 迁移（真实 v3 库 + 两列补齐 + 幂等 + 版本回退重跑）');

  final db = _createV3Database('${tmpDir.path}${Platform.pathSeparator}v3.sqlite');
  checkEq('前置：v3 库 user_version = 3', userVersion(db), 3);
  check('前置：folder_id 列不存在', !_columnExists(db, 'knowledge_documents', 'folder_id'));
  check('前置：source_mtime 列不存在', !_columnExists(db, 'knowledge_documents', 'source_mtime'));
  check('前置：knowledge_base_folders 表不存在', !_tableExists(db, 'knowledge_base_folders'));

  final v = ensureSchema(db);
  checkEq('ensureSchema 升级到 9', v, 9);
  checkEq('PRAGMA user_version = 9', userVersion(db), 9);
  check('knowledge_base_folders 表已建', _tableExists(db, 'knowledge_base_folders'));
  check('folder_id 列已补', _columnExists(db, 'knowledge_documents', 'folder_id'));
  check('source_mtime 列已补', _columnExists(db, 'knowledge_documents', 'source_mtime'));

  // 旧数据无损；存量文档两列为 NULL。
  checkEq('旧库 base 无损', db.select("SELECT name FROM knowledge_bases WHERE id = 'kb_v3'").length, 1);
  checkEq('旧文档 A 无损',
      db.select("SELECT file_path FROM knowledge_documents WHERE id = 'doc_v3_a'").first['file_path'],
      'E:\\Docs\\A.md');
  checkEq('旧文档数不变', db.select('SELECT COUNT(*) AS c FROM knowledge_documents').first['c'], 2);
  check('存量文档 folder_id = NULL',
      db.select("SELECT folder_id FROM knowledge_documents WHERE id = 'doc_v3_a'").first['folder_id'] == null);
  check('存量文档 source_mtime = NULL',
      db.select("SELECT source_mtime FROM knowledge_documents WHERE id = 'doc_v3_b'").first['source_mtime'] == null);

  // 幂等：重复 ensureSchema 不报错（不重复 ALTER）、版本不变。
  var threw = false;
  try {
    ensureSchema(db);
    ensureSchema(db);
  } catch (e) {
    threw = true;
    check('幂等重跑不抛异常（占位）', false, '$e');
  }
  if (!threw) check('幂等重跑不抛异常（不重复 ALTER）', true);
  checkEq('幂等重跑后版本仍为 9', userVersion(db), 9);

  // 版本回退重跑（双保险）：列已存在 + user_version 回退 → ensureSchema 不得崩溃。
  db.execute('PRAGMA user_version = 1;');
  var threw2 = false;
  try {
    ensureSchema(db);
  } catch (e) {
    threw2 = true;
    check('版本回退到 1 重跑不崩溃（占位）', false, '$e');
  }
  if (!threw2) check('版本回退到 1（列已存在）ensureSchema 不崩溃', true);
  checkEq('回退重跑后版本恢复 9', userVersion(db), 9);

  // 更狠的回退：回到 3（触发 v4 守卫但列已存在）。
  db.execute('PRAGMA user_version = 3;');
  var threw3 = false;
  try {
    ensureSchema(db);
  } catch (e) {
    threw3 = true;
    check('版本回退到 3 重跑不崩溃（占位）', false, '$e');
  }
  if (!threw3) check('版本回退到 3（触发 v4 守卫、列已存在）不崩溃', true);

  // 索引存在。
  check('idx_kb_folders_base 索引已建', db
      .select("SELECT name FROM sqlite_master WHERE type='index' AND name = 'idx_kb_folders_base'")
      .isNotEmpty);

  db.dispose();
}

// ---------------------------------------------------------------------------
// 2. 文件夹仓储 7 方法
// ---------------------------------------------------------------------------

Future<void> _verifyFolderRepository(Directory tmpDir) async {
  section('文件夹仓储（upsert/get/list/delete + UNIQUE + byFolder + assign + mtime + 两列 roundtrip）');

  final db = openAdvisorDatabase('${tmpDir.path}${Platform.pathSeparator}repo.sqlite');
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());

  final now = DateTime.now().millisecondsSinceEpoch;
  await repos.knowledge
      .upsertBase(KnowledgeBase(id: 'kb_r4', name: '第4轮库', createdAt: now, updatedAt: now));

  // upsertFolder + getFolder roundtrip。
  final folder = KnowledgeBaseFolder(
    id: 'kbf_1',
    knowledgeBaseId: 'kb_r4',
    folderPath: 'e:\\docs\\specs', // 比较键（小写）。
    displayPath: 'E:\\Docs\\Specs', // 原样路径。
    recursive: true,
    createdAt: now,
  );
  await repos.knowledge.upsertFolder(folder);
  final got = await repos.knowledge.getFolder('kbf_1');
  check('getFolder 读回', got != null);
  checkEq('getFolder folderPath（比较键）', got?.folderPath, 'e:\\docs\\specs');
  checkEq('getFolder displayPath（原样）', got?.displayPath, 'E:\\Docs\\Specs');
  checkEq('getFolder recursive', got?.recursive, true);
  check('getFolder lastScanAt 初始 NULL', got?.lastScanAt == null);

  // lastScanAt 更新（copyWith + upsert）。
  await repos.knowledge.upsertFolder(folder.copyWith(lastScanAt: 12345));
  checkEq('upsertFolder 更新 lastScanAt', (await repos.knowledge.getFolder('kbf_1'))?.lastScanAt, 12345);

  // listFolders 按库过滤。
  await repos.knowledge.upsertBase(
      KnowledgeBase(id: 'kb_other', name: '其他库', createdAt: now, updatedAt: now));
  await repos.knowledge.upsertFolder(KnowledgeBaseFolder(
    id: 'kbf_2',
    knowledgeBaseId: 'kb_other',
    folderPath: 'e:\\docs\\other',
    displayPath: 'E:\\Docs\\Other',
    createdAt: now,
  ));
  checkEq('listFolders 按库过滤', (await repos.knowledge.listFolders('kb_r4')).length, 1);

  // UNIQUE(knowledge_base_id, folder_path) 拦截大小写变体（folder_path 存比较键）。
  var dupRejected = false;
  String? dupMsg;
  try {
    await repos.knowledge.upsertFolder(KnowledgeBaseFolder(
      id: 'kbf_dup',
      knowledgeBaseId: 'kb_r4',
      folderPath: 'E:\\DOCS\\SPECS', // 大写变体 → 不经比较键直接撞 UNIQUE。
      displayPath: 'E:\\DOCS\\SPECS',
      createdAt: now,
    ));
  } catch (e) {
    dupRejected = true;
    dupMsg = '$e';
  }
  check('UNIQUE 拦截大小写变体重复关联', dupRejected, dupMsg);
  checkEq('被拒后未新增行', (await repos.knowledge.listFolders('kb_r4')).length, 1);

  // 文档两列 roundtrip：folder_id + source_mtime 落库读回。
  await repos.knowledge.upsertDocument(KnowledgeDocument(
    id: 'doc_r4',
    knowledgeBaseId: 'kb_r4',
    fileName: '规格.md',
    filePath: 'E:\\Docs\\Specs\\规格.md',
    fileHash: 'h_r4',
    fileSize: 5,
    status: DocumentStatus.indexed,
    folderId: 'kbf_1',
    sourceMtime: 999888,
    createdAt: now,
    updatedAt: now,
  ));
  final doc = await repos.knowledge.listDocuments('kb_r4').then((l) => l.first);
  checkEq('文档 folder_id roundtrip', doc.folderId, 'kbf_1');
  checkEq('文档 source_mtime roundtrip', doc.sourceMtime, 999888);

  // listDocumentsByFolder：归属判定 = folder_id 登记事实。
  await repos.knowledge.upsertDocument(KnowledgeDocument(
    id: 'doc_orphan',
    knowledgeBaseId: 'kb_r4',
    fileName: '孤儿.md',
    filePath: 'E:\\Docs\\Specs\\孤儿.md',
    fileHash: 'h_orphan',
    fileSize: 5,
    status: DocumentStatus.indexed,
    createdAt: now,
    updatedAt: now,
  ));
  final byFolder = await repos.knowledge.listDocumentsByFolder('kbf_1');
  checkEq('listDocumentsByFolder 只含 folder_id 命中者',
      byFolder.map((d) => d.id).toSet().join('|'), 'doc_r4');

  // assignDocumentsFolder：填值与置 NULL（只 UPDATE folder_id，绝不删行）。
  await repos.knowledge.assignDocumentsFolder(['doc_orphan'], 'kbf_1');
  checkEq('assign 回填 folder_id',
      (await repos.knowledge.listDocumentsByFolder('kbf_1')).length, 2);
  checkEq('assign 后文档数不变（只增不删）', (await repos.knowledge.listDocuments('kb_r4')).length, 2);
  await repos.knowledge.assignDocumentsFolder(['doc_orphan'], null);
  check('assign(null) 清空 folder_id',
      (await repos.knowledge.listDocumentsByFolder('kbf_1')).length == 1);
  checkEq('置 NULL 后文档仍在', (await repos.knowledge.listDocuments('kb_r4')).length, 2);

  // updateSourceMtime。
  await repos.knowledge.updateSourceMtime('doc_r4', 111222);
  checkEq('updateSourceMtime 生效',
      (await repos.knowledge.listDocuments('kb_r4')).firstWhere((d) => d.id == 'doc_r4').sourceMtime,
      111222);
  await repos.knowledge.updateSourceMtime('doc_not_exists', 1); // 不抛错（对账竞态容忍）。
  check('updateSourceMtime 对不存在文档不抛错', true);

  // deleteFolder 只删行、不碰文档（逻辑外键，处置权在服务层）。
  await repos.knowledge.deleteFolder('kbf_2');
  check('deleteFolder 生效', (await repos.knowledge.getFolder('kbf_2')) == null);
  checkEq('deleteFolder 不级联文档（kb_other 无文档前提下断言 kb_r4 仍 2 篇）',
      (await repos.knowledge.listDocuments('kb_r4')).length, 2);

  db.dispose();
}

// ---------------------------------------------------------------------------
// 3. 级联语义
// ---------------------------------------------------------------------------

Future<void> _verifyCascadeSemantics(Directory tmpDir) async {
  section('级联语义（folders ← bases 的 DB 级 CASCADE；folders 行删除不碰文档）');

  final db = openAdvisorDatabase('${tmpDir.path}${Platform.pathSeparator}cascade.sqlite');
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());

  final now = DateTime.now().millisecondsSinceEpoch;
  await repos.knowledge
      .upsertBase(KnowledgeBase(id: 'kb_c', name: '级联库', createdAt: now, updatedAt: now));
  await repos.knowledge.upsertFolder(KnowledgeBaseFolder(
    id: 'kbf_c1',
    knowledgeBaseId: 'kb_c',
    folderPath: 'e:\\c',
    displayPath: 'E:\\C',
    createdAt: now,
  ));
  await repos.knowledge.upsertDocument(KnowledgeDocument(
    id: 'doc_c1',
    knowledgeBaseId: 'kb_c',
    fileName: 'c.md',
    filePath: 'E:\\C\\c.md',
    fileHash: 'hc',
    fileSize: 1,
    status: DocumentStatus.indexed,
    folderId: 'kbf_c1',
    createdAt: now,
    updatedAt: now,
  ));

  // deleteFolder（服务层 unlink 前置动作）→ 文档不受 DB 级影响。
  await repos.knowledge.deleteFolder('kbf_c1');
  check('删 folder 行后文档仍在（无 DB 级联）',
      (await repos.knowledge.listDocuments('kb_c')).length == 1);

  // 重建 folder，再删 base → folders 文档均被 DB 级 CASCADE 清掉。
  await repos.knowledge.upsertFolder(KnowledgeBaseFolder(
    id: 'kbf_c1',
    knowledgeBaseId: 'kb_c',
    folderPath: 'e:\\c',
    displayPath: 'E:\\C',
    createdAt: now,
  ));
  await repos.knowledge.deleteBase('kb_c');
  check('删库级联清 folder 行', (await repos.knowledge.getFolder('kbf_c1')) == null);
  check('删库级联清文档', (await repos.knowledge.listDocuments('kb_c')).isEmpty);

  db.dispose();
}
