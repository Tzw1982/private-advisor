/// QA 独立验证脚本（严过关）——**与工程师的 verify_storage.dart 相互独立**。
///
/// 运行：`cd advisor_storage && dart run tool/qa_verify.dart`
///
/// 设计原则：
/// - **不复制** verify_storage.dart 的断言；尽量绕开仓储 API，用**裸 SQL** 直接查子表行数，
///   以"证明级联真的发生"而非"仓储顺手删了"。
/// - 每条断言记录 期望 / 实际，最终输出 markdown 用例表。
/// - 只读取，不修改任何生产代码。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';
import 'package:advisor_storage/advisor_storage.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（独立于工程师脚本）
// ---------------------------------------------------------------------------

class CaseResult {
  CaseResult(this.id, this.name, this.expected, this.actual, this.pass, [this.note]);
  final String id;
  final String name;
  final String expected;
  final String actual;
  final bool pass;
  final String? note;
}

final List<CaseResult> _results = [];
int _pass = 0;
int _fail = 0;

void t(String id, String name, Object? expected, Object? actual, {String? note}) {
  final ok = expected == actual;
  if (ok) {
    _pass++;
  } else {
    _fail++;
  }
  _results.add(CaseResult(id, name, '$expected', '$actual', ok, note));
  stdout.writeln('  ${ok ? '✓' : '✗'} [$id] $name  (期望=$expected 实际=$actual)');
}

void section(String name) => stdout.writeln('\n── $name ──────────────────────────');

Object? _scalar(Database db, String sql, [List<Object?> params = const []]) {
  final rs = db.select(sql, params);
  if (rs.isEmpty) return null;
  return rs.first.values.first;
}

int _count(Database db, String table, [String? where, List<Object?> params = const []]) =>
    (_scalar(db, 'SELECT COUNT(*) FROM $table${where == null ? '' : ' WHERE $where'}', params)
            as int?) ??
    0;

String? _errCode(Object? e) => e is StorageError ? e.code : null;
String? _errMsg(Object? e) => e is StorageError
    ? e.message
    : (e is SqliteException ? e.message : (e == null ? null : '$e'));
Object? _errCause(Object? e) => e is StorageError ? e.cause : null;

// ---------------------------------------------------------------------------

Future<void> main() async {
  open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));

  stdout.writeln('严过关 · 独立 QA 验证（advisor_storage）');
  stdout.writeln('=' * 62);
  stdout.writeln('sqlite3 = ${sqlite3.version.libVersion}  |  dart = ${Platform.version}');

  final tmp = Directory.systemTemp.createTempSync('pa_qa_verify_');
  final sep = Platform.pathSeparator;

  await _t7_schemaConsistency();

  // ---- #8 user_version 迁移幂等 + #2 schema 建全 ----
  final dbPath = '${tmp.path}${sep}qa.sqlite';
  final db = openAdvisorDatabase(dbPath);
  await _t1_fkAndCascade(db); // #1 + #2
  await _t2_migrationAndBackfill(tmp, sep); // #2b/#2c 迁移 + 回填
  await _t2b_v4toV5(tmp, sep); // #2d 真实 v4→当前版本 迁移 + 数据完整性 + 幂等
  await _t3_generation(db); // #3
  await _t4_transactions(db); // #4
  await _t5_marketScope(db); // #5
  await _t6_errorNormalization(db); // #6
  await _t3b_legacyRepos(db); // #3 存量仓储
  _t8_idempotency(db); // #8

  // ---- #9 重启持久化：先写，再关，再开 ----
  await _t9_writeForRestart(db);
  db.dispose();

  final db2 = openAdvisorDatabase(dbPath);
  ensureSchema(db2);
  await _t9_verifyAfterRestart(db2);
  db2.dispose();

  // ---- 附加：#1 补充——不经 openAdvisorDatabase 时 FK 是否为 OFF ----
  await _t1b_fkOffRisk(tmp, sep);

  _printReport();
  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {}
  exitCode = _fail == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// #7 schema.g.dart vs schema.sql 独立逐字比对
// ---------------------------------------------------------------------------

Future<void> _t7_schemaConsistency() async {
  section('#7 schema.g.dart 与 schema.sql 独立比对');
  final sqlFile = File('lib/src/database/schema.sql');
  final gFile = File('lib/src/database/schema.g.dart');
  if (!sqlFile.existsSync() || !gFile.existsSync()) {
    t('7.1', '两个文件都存在', true, false, note: '找不到文件，跳过');
    return;
  }
  final disk = sqlFile.readAsStringSync();
  final gdart = gFile.readAsStringSync();
  final start = gdart.indexOf("r'''");
  final end = gdart.lastIndexOf("'''");
  var embedded = (start >= 0 && end > start) ? gdart.substring(start + 4, end) : '';
  // 去掉 r''' 之后用于排版的首个换行
  if (embedded.startsWith('\r\n')) {
    embedded = embedded.substring(2);
  } else if (embedded.startsWith('\n')) {
    embedded = embedded.substring(1);
  }
  t('7.1', '磁盘 schema.sql 与 g.dart 内嵌字面量逐字一致', true, disk == embedded,
      note: 'disk=${disk.length}B embedded=${embedded.length}B');
  t('7.2', '运行时常量 kAdvisorSchemaSql 与磁盘一致', true, kAdvisorSchemaSql == disk,
      note: 'const=${kAdvisorSchemaSql.length}B');
  // 独立扫描：引号内不得含分号（applySchema 以 ';' 切分）
  final quoted = RegExp(r"'[^']*'").allMatches(kAdvisorSchemaSql).map((m) => m.group(0)!);
  final bad = quoted.where((q) => q.contains(';')).toList();
  t('7.3', 'schema 内不存在引号内的分号', 0, bad.length, note: bad.isEmpty ? null : bad.join(' | '));
}

// ---------------------------------------------------------------------------
// #1 FK 实际值 + 级联删除（裸 SQL 证明）+ #2 建表完整性
// ---------------------------------------------------------------------------

Future<void> _t1_fkAndCascade(Database db) async {
  section('#1 外键开关 + 级联删除（裸 SQL 验证）；#2 建表完整性');
  ensureSchema(db);

  final fk = _scalar(db, 'PRAGMA foreign_keys;');
  t('1.1', 'PRAGMA foreign_keys 实际值', 1, fk);

  // —— #2 与 schema.sql 声明的表逐一比对（拆成可分辨断言，证明"多的 6 张"确来自 FTS5）——
  // 先剥离整行注释再扫描：否则被注释掉的 `-- CREATE VIRTUAL TABLE ... vec_chunks`
  // 会被正则误计为"已声明虚表"（v5 后 schema.sql 尾部确有该注释段）。
  final sqlText = File('lib/src/database/schema.sql').readAsStringSync();
  final liveSql = sqlText
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('--'))
      .join('\n');
  final businessDeclared = RegExp(r'CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+([A-Za-z_][A-Za-z0-9_]*)')
      .allMatches(liveSql)
      .map((m) => m.group(1)!)
      .toSet();
  final ftsDeclared = RegExp(r'CREATE\s+VIRTUAL\s+TABLE\s+IF\s+NOT\s+EXISTS\s+([A-Za-z_][A-Za-z0-9_]*)')
      .allMatches(liveSql)
      .map((m) => m.group(1)!)
      .toSet();
  final allTables = db
      .select("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
      .map((r) => r['name'] as String)
      .toSet();

  const ftsName = 'knowledge_chunks_fts';
  const shadowSuffixes = ['data', 'idx', 'content', 'docsize', 'config'];
  final shadowNames = shadowSuffixes.map((s) => '${ftsName}_$s').toSet();

  // 业务表数**从 schema.sql 现算**（不写死数字）——随 schema 演进自动跟随，新增/删除
  // 业务表不再需要手工改断言。但不能退化成同义反复：2.1 比对的是
  // 「schema.sql 声明的 CREATE TABLE IF NOT EXISTS 数」 vs 「sqlite_master 实际业务表数」，
  // 因此既自动跟随，仍能发现"漏建 / 多建 / 改名"。
  final businessInDb = allTables.difference(ftsDeclared).difference(shadowNames);
  t('2.1', '业务表数 = schema.sql 声明的 CREATE TABLE 数（活断言）', businessDeclared.length,
      businessInDb.length, note: 'declared=${businessDeclared.length} inDb=${businessInDb.length}');
  final missingBusiness = businessDeclared.difference(allTables);
  t('2.2', '业务表全部存在（缺失=0）', 0, missingBusiness.length,
      note: missingBusiness.isEmpty
          ? '${businessDeclared.length}/${businessDeclared.length}'
          : '$missingBusiness');
  // 锁定历轮新增表确实在 schema.sql 中（防"数量对得上但表被替换/改名"）
  for (final name in ['expert_groups', 'knowledge_base_folders', 'message_attachments']) {
    t('2.1s', '历轮新增表已声明：$name', true, businessDeclared.contains(name));
  }

  final ftsRow = db.select("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", [ftsName]);
  final ftsSql = ftsRow.isEmpty ? '' : (ftsRow.first['sql'] as String);
  t('2.3', 'FTS 虚表存在且为 VIRTUAL TABLE ... USING fts5', true,
      ftsRow.isNotEmpty &&
          ftsSql.toUpperCase().contains('VIRTUAL TABLE') &&
          ftsSql.toLowerCase().contains('fts5'),
      note: 'ftsDeclared=$ftsDeclared');

  final missingShadow = shadowNames.difference(allTables);
  t('2.4', 'FTS5 影子表 5 张齐全（缺失=0）', 0, missingShadow.length,
      note: 'needed=${shadowSuffixes.join(",")}');

  // 总表数按"声明来源"推导，而非硬编码常数：业务 + 虚表 + 影子
  final expectedTotal = businessDeclared.length + ftsDeclared.length + shadowNames.length;
  t('2.5', '总表数 = 业务 ${businessDeclared.length} + 虚表 ${ftsDeclared.length} + 影子 ${shadowNames.length}（按声明推导）',
      expectedTotal, allTables.length,
      note: 'business=${businessDeclared.length} virtual=${ftsDeclared.length} shadow=${shadowNames.length}');

  final expectedAll = {...businessDeclared, ...ftsDeclared, ...shadowNames};
  final unexpected = allTables.difference(expectedAll);
  t('2.6', '无意外多出的表（证明多的 6 张确为 FTS 机制）', 0, unexpected.length,
      note: unexpected.isEmpty ? 'none' : '$unexpected');

  for (final name in ['generation_runs', 'generation_steps', 'generation_events']) {
    t('2.7', '表存在：$name', true, allTables.contains(name));
  }

  // —— 构造 知识库 → 文档 → 分块 → embedding 层级 ——
  final kb = SqliteKnowledgeRepository(db);
  final now = DateTime.now().millisecondsSinceEpoch;
  await kb.upsertBase(KnowledgeBase(id: 'kb_q', name: 'QA库', createdAt: now, updatedAt: now));
  await kb.upsertDocument(KnowledgeDocument(
    id: 'doc_q',
    knowledgeBaseId: 'kb_q',
    fileName: 'a.txt',
    filePath: '/a.txt',
    fileHash: 'HASH_A',
    fileSize: 10,
    status: DocumentStatus.indexed,
    createdAt: now,
    updatedAt: now,
  ));
  await kb.insertChunks([
    KnowledgeChunk(id: 'ck1', documentId: 'doc_q', text: 't1', sequence: 1, chunkHash: 'h1'),
    KnowledgeChunk(id: 'ck2', documentId: 'doc_q', text: 't2', sequence: 2, chunkHash: 'h2'),
  ]);
  await kb.upsertEmbedding(ChunkEmbedding(
      chunkId: 'ck1', embeddingModelId: 'em_q', dimension: 4, vectorRef: 'v', createdAt: now));

  // 专家 + 绑定（用于验证 deleteBase 级联绑定）
  final exp = SqliteExpertRepository(db);
  await exp.upsertExpert(Expert(
      id: 'e_q', name: 'E', systemPrompt: 'p', source: ExpertSource.local,
      createdAt: now, updatedAt: now));
  await exp.upsertKnowledgeBinding(
      const ExpertKnowledgeBinding(expertId: 'e_q', knowledgeBaseId: 'kb_q'));

  t('1.2', '写入后 knowledge_chunks 行数（裸SQL）', 2, _count(db, 'knowledge_chunks', 'document_id=?', ['doc_q']));
  t('1.3', '写入后 chunk_embeddings 行数（裸SQL）', 1, _count(db, 'chunk_embeddings', 'chunk_id=?', ['ck1']));
  t('1.4', '写入后 expert_knowledge_bindings 行数（裸SQL）', 1,
      _count(db, 'expert_knowledge_bindings', 'knowledge_base_id=?', ['kb_q']));

  // —— deleteDocument：直接查子表行数证明级联 ——
  await kb.deleteDocument('doc_q');
  t('1.5', 'deleteDocument 后 chunk 行数（裸SQL，应 0）', 0,
      _count(db, 'knowledge_chunks', 'document_id=?', ['doc_q']));
  t('1.6', 'deleteDocument 后 embedding 行数（裸SQL，应 0）', 0,
      _count(db, 'chunk_embeddings', 'chunk_id IN (?,?)', ['ck1', 'ck2']));

  // —— deleteBase：级联清除 documents / bindings ——
  await kb.deleteBase('kb_q');
  t('1.7', 'deleteBase 后 knowledge_documents 行数（裸SQL，应 0）', 0,
      _count(db, 'knowledge_documents', 'knowledge_base_id=?', ['kb_q']));
  t('1.8', 'deleteBase 后 expert_knowledge_bindings 行数（裸SQL，应 0）', 0,
      _count(db, 'expert_knowledge_bindings', 'knowledge_base_id=?', ['kb_q']));

  // —— 专家删除级联 runtime_config ——
  await exp.upsertExpert(Expert(
      id: 'e_q2', name: 'E2', systemPrompt: 'p', source: ExpertSource.local,
      createdAt: now, updatedAt: now));
  await exp.upsertRuntimeConfig(const ExpertRuntimeConfig(expertId: 'e_q2'));
  t('1.9', 'runtime_config 写入后行数', 1, _count(db, 'expert_runtime_configs', 'expert_id=?', ['e_q2']));
  await exp.deleteExpert('e_q2');
  t('1.10', 'deleteExpert 后 runtime_config 行数（裸SQL，应 0）', 0,
      _count(db, 'expert_runtime_configs', 'expert_id=?', ['e_q2']));
}

// ---------------------------------------------------------------------------
// #2b/#2c 迁移 v1→v2（构造真实 v1 库）+ FTS 回填幂等
// ---------------------------------------------------------------------------

Future<void> _t2_migrationAndBackfill(Directory tmp, String sep) async {
  final counts = _schemaTableCounts();
  section('#2b 迁移 v1→v$kSchemaVersion：additive / 幂等 / 业务数据不丢');
  final path = '${tmp.path}${sep}migrate.sqlite';
  final db = sqlite3.open(path); // 裸开；ensureSchema 会开启 FK

  // 先建当前版本，再"回退"为 v1 形态：删 FTS 虚表（连影子表）+ user_version=1
  ensureSchema(db);
  db.execute('DROP TABLE IF EXISTS knowledge_chunks_fts');
  db.execute('PRAGMA user_version = 1');

  t('M1', '构造的 v1 库：FTS 虚表不存在', false, ftsTableExists(db));
  t('M2', '构造的 v1 库：user_version', 1, userVersion(db));
  t('M3', '构造的 v1 库：总表数 = 业务表数（无 FTS 虚表与影子表，按 schema.sql 现算）', counts.business,
      _tableCount(db));

  // 写入 v1 存量业务数据：1 库 + 1 文档 + 2 分块
  final kb = SqliteKnowledgeRepository(db);
  final now = DateTime.now().millisecondsSinceEpoch;
  await kb.upsertBase(KnowledgeBase(id: 'mig_kb', name: '迁移库', createdAt: now, updatedAt: now));
  await kb.upsertDocument(KnowledgeDocument(
      id: 'mig_doc', knowledgeBaseId: 'mig_kb', fileName: 'm.txt', filePath: '/m',
      fileHash: 'MH', fileSize: 5, status: DocumentStatus.indexed,
      createdAt: now, updatedAt: now));
  await kb.insertChunks([
    KnowledgeChunk(id: 'mig_c1', documentId: 'mig_doc', text: '消防车水罐容积6000升',
        sequence: 1, chunkHash: 'mh1'),
    KnowledgeChunk(id: 'mig_c2', documentId: 'mig_doc', text: '消防泵额定流量60升每秒',
        sequence: 2, chunkHash: 'mh2'),
  ]);
  t('M4', 'v1 库已含 2 个分块', 2, _count(db, 'knowledge_chunks', 'document_id=?', ['mig_doc']));
  t('M5', 'v1 库 FTS 行为 0（未建索引）', 0, ftsRowCount(db));

  // —— 执行迁移 ——
  final v = ensureSchema(db);
  t('M6', 'ensureSchema 返回 kSchemaVersion', kSchemaVersion, v,
      note: 'v5 起 ensureSchema 返回 kSchemaVersion 常量');
  t('M7', 'user_version 升到 kSchemaVersion', kSchemaVersion, userVersion(db));
  t('M8', 'FTS 虚表已建', true, ftsTableExists(db));
  t('M9', '迁移后总表数 = 业务 + 虚表 + 影子（按 schema.sql 现算）', counts.total, _tableCount(db),
      note: 'business=${counts.business} virtual=${counts.virtual} shadow=${counts.shadow}');
  // v5 三列在迁移后必须存在（本库是 v5 形态回退而来，故列已在；单独断言防漂移）
  final gcCols = _tableColumns(db, 'group_configs');
  for (final c in ['announcement', 'announcement_updated_at', 'max_speakers_per_round']) {
    t('M9v5', '迁移后 group_configs.$c 存在', true, gcCols.contains(c));
  }

  // 业务数据一条不丢
  t('M10', '迁移后业务知识库仍在', 1, _count(db, 'knowledge_bases', 'id=?', ['mig_kb']));
  t('M11', '迁移后业务文档仍在', 1, _count(db, 'knowledge_documents', 'id=?', ['mig_doc']));
  t('M12', '迁移后业务分块仍在（2）', 2,
      _count(db, 'knowledge_chunks', 'document_id=?', ['mig_doc']));

  // 回填：v1 存量 chunk 应被同步进 FTS
  t('M13', '迁移后 FTS 已回填 2 行', 2, ftsRowCount(db));
  // 回填的行能真的被检索到（回连业务表）
  final rt = Fts5Retriever(db);
  final hit = await rt.search('水罐容积', knowledgeBaseIds: ['mig_kb']);
  t('M14', '回填后可按查询命中存量分块', true, hit.isNotEmpty,
      note: 'hit=${hit.isEmpty ? null : hit.first.chunk.id}');

  // 迁移幂等：再次 ensureSchema 不应改变版本 / 表数 / FTS 行数
  section('#2c 迁移 / 回填幂等');
  t('BF1', '再次 ensureSchema 仍返回 kSchemaVersion', kSchemaVersion, ensureSchema(db));
  t('BF2', 'FTS 行数不因重复迁移而增加（仍 2）', 2, ftsRowCount(db));
  tryBackfillFts(db);
  t('BF3', '直接重复 tryBackfillFts 不重复插（仍 2）', 2, ftsRowCount(db));
  t('BF4', '表数仍为"业务+虚表+影子"（按 schema.sql 现算）', counts.total, _tableCount(db));

  // O-1 修复后：启动兜底回填——索引被清空时，ensureSchema 应自动重建
  db.execute('DELETE FROM knowledge_chunks_fts');
  t('BF5', '人为清空 FTS 后行数=0', 0, ftsRowCount(db));
  ensureSchema(db);
  t('BF6', 'ensureSchema 启动兜底回填：索引清空后自动重建（恢复 2）', 2, ftsRowCount(db),
      note: 'O-1 修复：ensureSchema 每次都 tryBackfillFts（幂等）；修复前此处为 0');
  // 幂等：连续再跑一次 ensureSchema，行数不变、不重复插入
  ensureSchema(db);
  t('BF6b', '再次 ensureSchema 幂等：行数不变（仍 2）', 2, ftsRowCount(db));
  // rebuild 显式 API 仍成立
  await rt.rebuild('mig_kb');
  t('BF7', 'rebuild() 可显式重建（恢复 2）', 2, ftsRowCount(db));

  db.dispose();
}

// ---------------------------------------------------------------------------
// #2d 真实 v4→当前版本 迁移：手工构造旧版 group_configs（无三列）+ 存量行 → 升级
// ---------------------------------------------------------------------------

Future<void> _t2b_v4toV5(Directory tmp, String sep) async {
  section('#2d 真实 v4→v$kSchemaVersion 迁移：补列 / 存量行不丢 / 幂等（不依赖"回退版本"技巧）');
  final path = '${tmp.path}${sep}migrate_v4.sqlite';
  final db = sqlite3.open(path); // 裸开

  // 手工构造 v4 形态：旧版 group_configs（缺三列）+ conversations（供 FK / 插入）
  db.execute(
      'CREATE TABLE conversations (id TEXT PRIMARY KEY, type TEXT NOT NULL, title TEXT, '
      'pinned INTEGER DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);');
  db.execute('''CREATE TABLE IF NOT EXISTS group_configs (
      conversation_id TEXT PRIMARY KEY,
      speak_strategy TEXT NOT NULL DEFAULT 'auto',
      summarizer_expert_id TEXT,
      context_window INTEGER,
      max_rounds INTEGER DEFAULT 1,
      token_budget INTEGER,
      duplicate_threshold REAL DEFAULT 0.82,
      topic_threshold REAL DEFAULT 0.02,
      FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE);''');
  final now = DateTime.now().millisecondsSinceEpoch;
  db.execute('INSERT INTO conversations(id,type,title,created_at,updated_at) VALUES(?,?,?,?,?)',
      ['c_v4', 'group', '旧群', now, now]);
  db.execute(
      "INSERT INTO group_configs(conversation_id,speak_strategy,max_rounds) VALUES('c_v4','auto',2)");
  db.execute('PRAGMA user_version = 4');

  final beforeCols = _tableColumns(db, 'group_configs');
  t('V4.1', '构造的 v4 库：group_configs 无 announcement 列', false,
      beforeCols.contains('announcement'));
  t('V4.2', '构造的 v4 库：group_configs 无 max_speakers_per_round 列', false,
      beforeCols.contains('max_speakers_per_round'));
  t('V4.3', '构造的 v4 库：user_version', 4, userVersion(db));
  t('V4.4', '构造的 v4 库：存量群配置行存在', 1,
      _count(db, 'group_configs', 'conversation_id=?', ['c_v4']));

  // —— 执行迁移 ——
  final v = ensureSchema(db);
  t('V5.1', '迁移后 ensureSchema 返回 kSchemaVersion', kSchemaVersion, v);
  t('V5.2', '迁移后 user_version=kSchemaVersion', kSchemaVersion, userVersion(db));
  final afterCols = _tableColumns(db, 'group_configs');
  for (final c in ['announcement', 'announcement_updated_at', 'max_speakers_per_round']) {
    t('V5.3', '迁移补列成功：group_configs.$c', true, afterCols.contains(c));
  }
  // 数据完整性：存量行与旧字段不得丢失
  t('V5.4', '存量群配置行仍在（数据不丢）', 1, _count(db, 'group_configs', 'conversation_id=?', ['c_v4']));
  t('V5.5', '存量字段 max_rounds 保持 2', 2,
      (_scalar(db, 'SELECT max_rounds FROM group_configs WHERE conversation_id=?', ['c_v4']) as num)
          .toInt());
  t('V5.6', '存量会话仍在', 1, _count(db, 'conversations', 'id=?', ['c_v4']));
  t('V5.7', '旧行新列默认 NULL（additive 不破坏旧行）', null,
      _scalar(db, 'SELECT announcement FROM group_configs WHERE conversation_id=?', ['c_v4']));

  // 幂等：再次 ensureSchema 不得重复 ALTER（列不重复）或报错
  var threw = false;
  try {
    ensureSchema(db);
  } catch (_) {
    threw = true;
  }
  t('V5.8', '重复 ensureSchema 不抛异常（列已存在则跳过）', false, threw);
  t('V5.9', '重复 ensureSchema 后 user_version 仍 kSchemaVersion', kSchemaVersion, userVersion(db));
  t('V5.10', '重复 ensureSchema 后列数不变（无重复 ALTER）', afterCols.length,
      _tableColumns(db, 'group_configs').length);

  // 经真实仓储契约写读新列（证明列真的可用）
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  await repos.conversations.upsertGroupConfig(const GroupConfig(
      conversationId: 'c_v4',
      speakStrategy: 'leader_led',
      maxRounds: 2,
      announcement: '群共识：先给结论',
      announcementUpdatedAt: 123,
      maxSpeakersPerRound: 5));
  final back = await repos.conversations.getGroupConfig('c_v4');
  t('V5.11', '经仓储写读新列 announcement', '群共识：先给结论', back?.announcement);
  t('V5.12', '经仓储写读新列 maxSpeakersPerRound', 5, back?.maxSpeakersPerRound);
  t('V5.13', '经仓储写读 announcementUpdatedAt', 123, back?.announcementUpdatedAt);

  db.dispose();
}

// ---------------------------------------------------------------------------
// #3 GenerationRun → Step → Event 全链路（含工程师改过的 listRuns）
// ---------------------------------------------------------------------------

Future<void> _t3_generation(Database db) async {
  section('#3 存量仓储：GenerationRun→Step→Event 读写与顺序');
  final gen = SqliteGenerationRepository(db);

  // 3 个 run，started_at 故意乱序写入
  await gen.upsertRun(const GenerationRun(
      id: 'run_1', conversationId: 'conv_g', runType: RunType.singleChat,
      status: RunStatus.completed, promptTokens: 11, completionTokens: 22,
      estimatedCost: 1.5, startedAt: 1000, endedAt: 2000, modelProfileId: 'mp1'));
  await gen.upsertRun(const GenerationRun(
      id: 'run_2', conversationId: 'conv_g', runType: RunType.groupChat,
      status: RunStatus.failed, startedAt: 3000, errorCode: 'E1', errorMessage: 'boom'));
  await gen.upsertRun(const GenerationRun(
      id: 'run_3', conversationId: 'conv_g', runType: RunType.summarization,
      status: RunStatus.partial, startedAt: 2000));

  final runs = await gen.listRuns('conv_g');
  t('3.1', 'listRuns 数量', 3, runs.length);
  t('3.2', 'listRuns 按 started_at 倒序', 'run_2,run_3,run_1',
      runs.map((r) => r.id).join(','));

  final r1 = await gen.getRun('run_1');
  t('3.3', 'getRun 字段 promptTokens', 11, r1?.promptTokens);
  t('3.4', 'getRun 字段 completionTokens', 22, r1?.completionTokens);
  t('3.5', 'getRun 字段 estimatedCost', 1.5, r1?.estimatedCost);
  t('3.6', 'getRun runType 枚举还原', RunType.singleChat, r1?.runType);
  t('3.7', 'getRun status 枚举还原', RunStatus.completed, r1?.status);
  t('3.8', 'getRun startedAt/endedAt', '1000/2000', '${r1?.startedAt}/${r1?.endedAt}');
  final r2 = await gen.getRun('run_2');
  t('3.9', 'getRun 错误字段还原', 'E1|boom', '${r2?.errorCode}|${r2?.errorMessage}');

  // step：seq 3,1,2 乱序写入
  await gen.upsertStep(const GenerationStep(
      id: 'st_3', runId: 'run_1', stage: StepStage.generation, sequence: 3,
      status: RunStatus.completed, latencyMs: 33));
  await gen.upsertStep(const GenerationStep(
      id: 'st_1', runId: 'run_1', stage: StepStage.retrieval, sequence: 1,
      status: RunStatus.completed, retrievalCount: 7));
  await gen.upsertStep(const GenerationStep(
      id: 'st_2', runId: 'run_1', stage: StepStage.dedup, sequence: 2,
      status: RunStatus.completed));
  final steps = await gen.listSteps('run_1');
  t('3.10', 'listSteps 按 sequence 升序', 'st_1,st_2,st_3', steps.map((s) => s.id).join(','));
  t('3.11', 'step stage 枚举还原', StepStage.retrieval, steps.first.stage);
  t('3.12', 'step retrievalCount 还原', 7, steps.first.retrievalCount);
  t('3.13', 'step latencyMs 还原', 33, steps.last.latencyMs);

  // event：seq 1,2,3
  await gen.appendEvent(GenerationEvent(
      id: 'ev1', stepId: 'st_1', sequence: 1,
      eventType: GenerationEventType.runStarted, createdAt: 10));
  await gen.appendEvent(GenerationEvent(
      id: 'ev2', stepId: 'st_1', sequence: 2,
      eventType: GenerationEventType.tokenDelta, delta: '你好', createdAt: 11));
  await gen.appendEvent(GenerationEvent(
      id: 'ev3', stepId: 'st_1', sequence: 3,
      eventType: GenerationEventType.runCompleted, createdAt: 12));
  final evs = await gen.listEvents('st_1');
  t('3.14', 'listEvents 按 sequence 升序', 'ev1,ev2,ev3', evs.map((e) => e.id).join(','));
  t('3.15', 'event 类型 wire 往返', GenerationEventType.tokenDelta, evs[1].eventType);
  t('3.16', 'event delta 还原', '你好', evs[1].delta);

  // upsertRun 冲突更新：同 id 覆盖 status
  await gen.upsertRun(const GenerationRun(
      id: 'run_2', conversationId: 'conv_g', runType: RunType.groupChat,
      status: RunStatus.completed, startedAt: 3000));
  t('3.17', 'upsertRun 冲突更新 status', RunStatus.completed, (await gen.getRun('run_2'))?.status);

  // —— recoverInterrupted 语义探针（潜在缺陷）——
  // 造 1 个 running（本次应被恢复）+ 1 个历史 cancelled（不应计入本次恢复数）
  await gen.upsertRun(const GenerationRun(
      id: 'run_run', conversationId: 'conv_r', runType: RunType.singleChat,
      status: RunStatus.running, startedAt: 5000));
  await gen.upsertRun(const GenerationRun(
      id: 'run_cancel', conversationId: 'conv_r', runType: RunType.singleChat,
      status: RunStatus.cancelled, startedAt: 4000));
  final recovered = await gen.recoverInterrupted();
  final runningLeft = _count(db, 'generation_runs', "status='running'");
  final cancelledTotal = _count(db, 'generation_runs', "status='cancelled'");
  t('3.18', '运行中的 run 已被取消（裸SQL running=0）', 0, runningLeft);
  t('3.19', 'recoverInterrupted 应返回"本次恢复数"=1', 1, recovered,
      note: '实测=$recovered，全表 cancelled=$cancelledTotal；'
          '实现统计的是"全表 cancelled 总数"，存在历史 cancelled 时返回值偏大');
}

// ---------------------------------------------------------------------------
// #3b 其余存量仓储读写（Expert/Conversation/Message/Provider/Credential/Settings/Job）
// ---------------------------------------------------------------------------

Future<void> _t3b_legacyRepos(Database db) async {
  section('#3b 其余存量仓储读写回归');
  final now = DateTime.now().millisecondsSinceEpoch;
  final exp = SqliteExpertRepository(db);
  final conv = SqliteConversationRepository(db);
  final msg = SqliteMessageRepository(db);
  final prov = SqliteProviderRepository(db);
  final cred = SqliteCredentialRepository(db);
  final set = SqliteSettingsRepository(db);
  final job = SqliteJobRepository(db);

  // Expert 全链
  await exp.upsertExpert(Expert(
      id: 'e_x', name: '专家X', profession: '医生', systemPrompt: 'sp',
      quickPrompts: const ['q1', 'q2'], source: ExpertSource.market,
      createdAt: now, updatedAt: now));
  final ex = await exp.getExpert('e_x');
  t('B1', 'Expert 读回 name', '专家X', ex?.name);
  t('B2', 'Expert quickPrompts JSON 往返', 'q1,q2', ex?.quickPrompts.join(','));
  t('B3', 'Expert source 枚举还原', ExpertSource.market, ex?.source);
  await exp.upsertUserState(const ExpertUserState(expertId: 'e_x', remark: '备注', pinned: true));
  final us = await exp.getUserState('e_x');
  t('B4', 'UserState pinned 布尔还原', true, us?.pinned);
  await exp.setTags('e_x', ['t1', 't2', 't1']);
  t('B5', 'setTags 去重后标签数', 2, (await exp.getTags('e_x')).length);

  // Conversation / Message
  await conv.upsertConversation(Conversation(
      id: 'c_x', type: ConversationType.group, title: '标题', pinned: true,
      createdAt: now, updatedAt: now));
  t('B6', 'Conversation type 还原', ConversationType.group, (await conv.getConversation('c_x'))?.type);
  await conv.upsertMember(const ConversationMember(
      conversationId: 'c_x', expertId: 'e_x', weight: 2.5, sortOrder: 1));
  t('B7', 'Member weight 还原', 2.5, (await conv.listMembers('c_x')).first.weight);
  await conv.upsertGroupConfig(const GroupConfig(conversationId: 'c_x', maxRounds: 3, topicThreshold: 0.5));
  t('B8', 'GroupConfig maxRounds 还原', 3, (await conv.getGroupConfig('c_x'))?.maxRounds);

  await msg.insertMessage(Message(
      id: 'm_x', conversationId: 'c_x', senderType: MessageSenderType.user,
      content: 'hi', createdAt: now, updatedAt: now));
  t('B9', 'Message 读回 content', 'hi', (await msg.getMessage('m_x'))?.content);
  await msg.insertCitation('m_x', const Citation(
      chunkId: 'ck', documentId: 'd', fileName: 'f.txt', text: 'quote', score: 0.9));
  t('B10', 'Citation 读回条数', 1, (await msg.listCitations('m_x')).length);

  // Provider / Model / Credential
  await prov.upsertProvider(const ProviderProfile(
      id: 'pp_x', providerId: 'deepseek', displayName: 'DeepSeek', baseUrl: 'https://x'));
  await prov.upsertModel(ModelProfile.deepseekChat(providerProfileId: 'pp_x'));
  t('B11', 'Model supportsJson 还原', true,
      (await prov.getModel('mp_deepseek_chat'))?.supportsJson);
  await cred.upsert(CredentialProfile(
      id: 'cr_x', providerProfileId: 'pp_x', name: 'k', secretRef: 'ref',
      createdAt: now, updatedAt: now));
  t('B12', 'Credential secretRef 还原', 'ref', (await cred.get('cr_x'))?.secretRef);

  // Settings / Job
  await set.set('k1', 'v1');
  t('B13', 'Settings set/get', 'v1', await set.get('k1'));
  await job.upsert(JobRecord(id: 'j_x', type: 'index', createdAt: now, progress: 0.5));
  t('B14', 'Job progress 还原', 0.5, (await job.get('j_x'))?.progress);
  t('B15', 'Job list 过滤 type', 1, (await job.list(type: 'index')).length);
}

// ---------------------------------------------------------------------------
// #4 事务回滚
// ---------------------------------------------------------------------------

Future<void> _t4_transactions(Database db) async {
  section('#4 事务回滚（中途失败不留脏数据）');
  final kb = SqliteKnowledgeRepository(db);
  final mkt = SqliteMarketRepository(db);
  final now = DateTime.now().millisecondsSinceEpoch;

  await kb.upsertBase(KnowledgeBase(id: 'kb_tx', name: 'TX', createdAt: now, updatedAt: now));
  await kb.upsertDocument(KnowledgeDocument(
      id: 'doc_tx', knowledgeBaseId: 'kb_tx', fileName: 'f', filePath: '/f',
      fileHash: 'H', fileSize: 1, status: DocumentStatus.indexed,
      createdAt: now, updatedAt: now));

  // insertChunks：第 1 条合法、第 2 条 document_id 违反外键 → 整批回滚
  Object? err;
  try {
    await kb.insertChunks([
      KnowledgeChunk(id: 'ck_ok', documentId: 'doc_tx', text: 'ok', sequence: 1, chunkHash: 'h'),
      KnowledgeChunk(id: 'ck_bad', documentId: 'no_such_doc', text: 'bad', sequence: 2, chunkHash: 'h'),
    ]);
  } catch (e) {
    err = e;
  }
  t('4.1', 'insertChunks 中途失败抛错', true, err != null, note: err == null ? null : '$err');
  t('4.2', '回滚后合法 chunk 未落库（裸SQL=0）', 0, _count(db, 'knowledge_chunks', 'id=?', ['ck_ok']));
  t('4.3', '回滚后表内无残留', 0, _count(db, 'knowledge_chunks', 'document_id=?', ['doc_tx']));

  // replacePackages：先成功写入 old，再用"同批重复 package_id"触发失败 → 回滚保留 old
  await mkt.upsertSource(const MarketSource(id: 'src_tx', name: 'TX', baseUrl: 'https://t'));
  await mkt.replacePackages('src_tx', [
    const MarketPackage(packageId: 'org.old', slug: 'old', displayName: 'OLD',
        categoryId: 'c', latestVersion: SemVer(1, 0, 0)),
  ]);
  t('4.4', 'replacePackages 初次写入 src_tx 行数', 1, _count(db, 'market_packages', 'source_id=?', ['src_tx']));

  Object? err2;
  try {
    await mkt.replacePackages('src_tx', [
      const MarketPackage(packageId: 'org.new', slug: 'n', displayName: 'NEW',
          categoryId: 'c', latestVersion: SemVer(2, 0, 0)),
      const MarketPackage(packageId: 'org.new', slug: 'n', displayName: 'NEW-DUP',
          categoryId: 'c', latestVersion: SemVer(2, 0, 0)),
    ]);
  } catch (e) {
    err2 = e;
  }
  t('4.5', 'replacePackages 同批重复主键抛错', true, err2 != null, note: err2 == null ? null : '$err2');
  t('4.6', '回滚后 src_tx 仍只有 1 条', 1, _count(db, 'market_packages', 'source_id=?', ['src_tx']));
  t('4.7', '回滚后旧包 org.old 仍在（裸SQL）', 1,
      _count(db, 'market_packages', 'package_id=?', ['org.old']));
  t('4.8', '回滚后新包 org.new 未落库（裸SQL=0）', 0,
      _count(db, 'market_packages', 'package_id=?', ['org.new']));
}

// ---------------------------------------------------------------------------
// #5 replacePackages 的 source 作用域 + versions 级联
// ---------------------------------------------------------------------------

Future<void> _t5_marketScope(Database db) async {
  section('#5 replacePackages 按 source 作用域');
  final mkt = SqliteMarketRepository(db);
  await mkt.upsertSource(const MarketSource(id: 'src_A', name: 'A', baseUrl: 'https://a'));
  await mkt.upsertSource(const MarketSource(id: 'src_B', name: 'B', baseUrl: 'https://b'));

  await mkt.replacePackages('src_A', [
    const MarketPackage(packageId: 'org.a1', slug: 'a1', displayName: 'A1',
        categoryId: 'c', latestVersion: SemVer(1, 0, 0), versions: [
      MarketVersion(packageId: 'org.a1', version: SemVer(1, 0, 0),
          releaseUrl: 'u', sha256: 's1', sizeBytes: 1, publishedAt: 1),
      MarketVersion(packageId: 'org.a1', version: SemVer(1, 1, 0),
          releaseUrl: 'u', sha256: 's2', sizeBytes: 1, publishedAt: 2),
    ]),
    const MarketPackage(packageId: 'org.a2', slug: 'a2', displayName: 'A2',
        categoryId: 'c', latestVersion: SemVer(2, 0, 0)),
  ]);
  await mkt.replacePackages('src_B', [
    const MarketPackage(packageId: 'org.b1', slug: 'b1', displayName: 'B1',
        categoryId: 'c', latestVersion: SemVer(3, 0, 0)),
    const MarketPackage(packageId: 'org.b2', slug: 'b2', displayName: 'B2',
        categoryId: 'c', latestVersion: SemVer(3, 1, 0)),
  ]);
  t('5.1', '初始 src_A 包数', 2, _count(db, 'market_packages', 'source_id=?', ['src_A']));
  t('5.2', '初始 src_B 包数', 2, _count(db, 'market_packages', 'source_id=?', ['src_B']));

  // 只刷新 src_A，且删掉 org.a2
  await mkt.replacePackages('src_A', [
    const MarketPackage(packageId: 'org.a1', slug: 'a1', displayName: 'A1',
        categoryId: 'c', latestVersion: SemVer(1, 1, 0), versions: [
      MarketVersion(packageId: 'org.a1', version: SemVer(1, 1, 0),
          releaseUrl: 'u', sha256: 's2', sizeBytes: 1, publishedAt: 2),
    ]),
  ]);
  t('5.3', '刷新后 src_A 包数=1', 1, _count(db, 'market_packages', 'source_id=?', ['src_A']));
  t('5.4', 'src_B 一条不少（裸SQL=2）', 2, _count(db, 'market_packages', 'source_id=?', ['src_B']));
  final bIds = (await mkt.listPackages(sourceId: 'src_B')).map((p) => p.packageId).toList()..sort();
  t('5.5', 'src_B 具体包完整', 'org.b1,org.b2', bIds.join(','));
  t('5.6', '被删包的 versions 级联清除（org.a1 旧版本 1.0.0 应无）', 0,
      _count(db, 'market_versions', 'package_id=? AND version=?', ['org.a1', '1.0.0']));
  t('5.7', '保留版本 1.1.0 仍存在', 1,
      _count(db, 'market_versions', 'package_id=? AND version=?', ['org.a1', '1.1.0']));
  // 观察：package 级 sha256/signature 恒为 NULL
  final pkgSha = _scalar(db, 'SELECT sha256 FROM market_packages WHERE package_id=?', ['org.a1']);
  t('5.8', 'package 级 sha256 写入情况（观察项）', null, pkgSha,
      note: 'replacePackages 恒写 NULL，sha256 仅在 market_versions 保留');

  // etag KV
  await mkt.setIndexEtag('src_A', 'W/"e1"', 111);
  await mkt.setIndexEtag('src_B', null, 222);
  t('5.9', 'etag 读回', 'W/"e1"', (await mkt.getIndexEtag('src_A'))?.etag);
  t('5.10', '未设置源返回 null', null, await mkt.getIndexEtag('src_X'));
}

// ---------------------------------------------------------------------------
// #6 错误归一化 + 敏感信息泄漏检查
// ---------------------------------------------------------------------------

Future<void> _t6_errorNormalization(Database db) async {
  section('#6 错误归一化：StorageError vs 裸 SqliteException');
  final kb = SqliteKnowledgeRepository(db);
  final mkt = SqliteMarketRepository(db);
  final msgRepo = SqliteMessageRepository(db);
  final now = DateTime.now().millisecondsSinceEpoch;

  await kb.upsertBase(KnowledgeBase(id: 'kb_e', name: 'E', createdAt: now, updatedAt: now));

  // (a) 唯一键 UNIQUE(knowledge_base_id, file_hash)
  await kb.upsertDocument(KnowledgeDocument(
      id: 'd1', knowledgeBaseId: 'kb_e', fileName: 'f', filePath: '/f', fileHash: 'SAME',
      fileSize: 1, status: DocumentStatus.indexed, createdAt: now, updatedAt: now));
  Object? uErr;
  try {
    await kb.upsertDocument(KnowledgeDocument(
        id: 'd2', knowledgeBaseId: 'kb_e', fileName: 'f2', filePath: '/f2', fileHash: 'SAME',
        fileSize: 1, status: DocumentStatus.indexed, createdAt: now, updatedAt: now));
  } catch (e) {
    uErr = e;
  }
  t('6.1', '唯一键冲突抛 StorageError', true, uErr is StorageError, note: '实际类型=${uErr.runtimeType}');
  t('6.2', '不是裸 SqliteException', false, uErr is SqliteException);
  t('6.3', '错误码', 'storage.knowledge.upsert_document', _errCode(uErr));
  final uMsg = _errMsg(uErr);
  t('6.4', 'message 无 SQL 明文', true,
      !(uMsg?.contains('INSERT') ?? true) && !(uMsg?.contains('UNIQUE') ?? true),
      note: 'message=$uMsg');
  t('6.5', '原始异常保留在 cause', true, _errCause(uErr) is SqliteException,
      note: 'cause=${_errCause(uErr).runtimeType}');

  // (b) 外键冲突（insertChunks 指向不存在文档）
  Object? fErr;
  try {
    await kb.insertChunks([
      KnowledgeChunk(id: 'x', documentId: 'ghost', text: 't', sequence: 1, chunkHash: 'h'),
    ]);
  } catch (e) {
    fErr = e;
  }
  t('6.6', '外键冲突抛 StorageError', true, fErr is StorageError);
  t('6.7', '外键错误码', 'storage.knowledge.insert_chunks', _errCode(fErr));
  final fMsg = _errMsg(fErr);
  t('6.8', '外键 message 无 SQL 明文', true,
      !(fMsg?.contains('FOREIGN') ?? true) && !(fMsg?.contains('INSERT') ?? true),
      note: 'message=$fMsg');

  // (c) 市场外键（source 不存在）
  Object? mErr;
  try {
    await mkt.replacePackages('ghost_src', [
      const MarketPackage(packageId: 'org.z', slug: 'z', displayName: 'Z',
          categoryId: 'c', latestVersion: SemVer(1, 0, 0)),
    ]);
  } catch (e) {
    mErr = e;
  }
  t('6.9', '市场外键冲突抛 StorageError', true, mErr is StorageError);
  t('6.10', '市场错误码', 'storage.market.replace_packages', _errCode(mErr));

  // (d) —— 存量 8 仓储归一化（TD-1）——**正向断言** ——
  // 说明：本组原为「症状记录式」反证（断言当前仍是裸 SqliteException）；
  // TD-1 让 8 个存量仓储全部经 `_guard` 归一化后，旧断言翻红即是修复生效的证据。
  // 现改为正向：该路径抛出的必须是 StorageError（非裸 SqliteException），
  // code 符合 `storage.<area>.<method>` 且原始 SqliteException 保留在 cause。
  Object? legacyErr;
  try {
    await msgRepo.insertCitation('nonexistent_msg', const Citation(
        chunkId: 'c', documentId: 'd', fileName: 'f', text: 'q', score: 1));
  } catch (e) {
    legacyErr = e;
  }
  final legacyCode = _errCode(legacyErr);
  t('6.11', '存量仓储(Message)抛 StorageError（非裸 SqliteException）', true,
      legacyErr is StorageError && legacyErr is! SqliteException,
      note: '实际类型=${legacyErr.runtimeType}');
  t('6.12', '错误码符合 storage.<area>.<method> 且原始 SqliteException 保留在 cause',
      true,
      legacyCode == 'storage.message.insert_citation' &&
          RegExp(r'^storage\.[a-z_]+\.[a-z_]+$').hasMatch(legacyCode ?? '') &&
          _errCause(legacyErr) is SqliteException,
      note: 'code=$legacyCode cause=${_errCause(legacyErr).runtimeType}');
}

// ---------------------------------------------------------------------------
// #8 user_version 迁移幂等
// ---------------------------------------------------------------------------

int _tableCount(Database db) => db
    .select("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
    .length;

/// 从 `schema.sql`（**剔除整行注释后**）现算表清单，**不写死数字**：
/// [business] = `CREATE TABLE IF NOT EXISTS` 数；[virtual] = `CREATE VIRTUAL TABLE` 数；
/// [shadow] = 每个 FTS5 虚表固定 5 张影子表（`_data/_idx/_content/_docsize/_config`）；
/// [total] = 三者之和。
///
/// 这样任何 schema 演进（新增/删除表、增删虚表）都自动跟随，无需手工改断言。
({int business, int virtual, int shadow, int total}) _schemaTableCounts() {
  final liveSql = File('lib/src/database/schema.sql')
      .readAsStringSync()
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('--'))
      .join('\n');
  final business =
      RegExp(r'CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+([A-Za-z_][A-Za-z0-9_]*)')
          .allMatches(liveSql)
          .map((m) => m.group(1)!)
          .toSet()
          .length;
  final virtual =
      RegExp(r'CREATE\s+VIRTUAL\s+TABLE\s+IF\s+NOT\s+EXISTS\s+([A-Za-z_][A-Za-z0-9_]*)')
          .allMatches(liveSql)
          .map((m) => m.group(1)!)
          .toSet()
          .length;
  const shadowPerVirtual = 5;
  final shadow = virtual * shadowPerVirtual;
  return (business: business, virtual: virtual, shadow: shadow, total: business + virtual + shadow);
}

/// 读取某表的列名集合（PRAGMA table_info）。
Set<String> _tableColumns(Database db, String table) => db
    .select('PRAGMA table_info($table)')
    .map((r) => r['name'] as String)
    .toSet();

void _t8_idempotency(Database db) {
  section('#8 ensureSchema 幂等（同一已存在 DB）');
  final tablesBefore = _tableCount(db);
  t('8.1', 'ensureSchema 重复调用返回版本不变', kSchemaVersion, ensureSchema(db));
  t('8.2', 'user_version 保持 kSchemaVersion', kSchemaVersion, userVersion(db));
  t('8.3', '重复 ensureSchema 不新增表', tablesBefore, _tableCount(db));
  var threw = false;
  try {
    for (var i = 0; i < 3; i++) {
      ensureSchema(db);
    }
  } catch (_) {
    threw = true;
  }
  t('8.4', '连续 3 次 ensureSchema 不抛异常', false, threw);
  t('8.5', '版本仍为 kSchemaVersion', kSchemaVersion, userVersion(db));
  t('8.6', '表数与初始一致', tablesBefore, _tableCount(db));
}

// ---------------------------------------------------------------------------
// #9 重启持久化
// ---------------------------------------------------------------------------

const String _persistIds = 'persist_kb|persist_doc|persist_ck|src_persist|org.persist|inst_persist';

Future<void> _t9_writeForRestart(Database db) async {
  section('#9 重启持久化（写入阶段）');
  final kb = SqliteKnowledgeRepository(db);
  final mkt = SqliteMarketRepository(db);
  final now = DateTime.now().millisecondsSinceEpoch;

  await kb.upsertBase(KnowledgeBase(id: 'persist_kb', name: '持久库', createdAt: now, updatedAt: now));
  await kb.upsertDocument(KnowledgeDocument(
      id: 'persist_doc', knowledgeBaseId: 'persist_kb', fileName: 'p.txt', filePath: '/p',
      fileHash: 'PH', fileSize: 3, status: DocumentStatus.indexed, createdAt: now, updatedAt: now));
  await kb.insertChunks([
    KnowledgeChunk(id: 'persist_ck', documentId: 'persist_doc', text: 'p', sequence: 1, chunkHash: 'ph'),
  ]);
  await mkt.upsertSource(const MarketSource(id: 'src_persist', name: 'P', baseUrl: 'https://p'));
  await mkt.replacePackages('src_persist', [
    const MarketPackage(packageId: 'org.persist', slug: 'p', displayName: 'P',
        categoryId: 'c', latestVersion: SemVer(1, 0, 0)),
  ]);
  await mkt.setIndexEtag('src_persist', 'W/"persist"', 777);
  await mkt.upsertInstalled(InstalledPackage(
      installationId: 'inst_persist', packageId: 'org.persist', version: const SemVer(1, 0, 0),
      installPath: 'C:/p', installedAt: 999, source: 'market'));

  t('9.0', '写入阶段：知识库/文档/分块/包/etag/安装 均已入库', '1,1,1,1,1,1',
      '${_count(db, 'knowledge_bases', 'id=?', ['persist_kb'])},'
      '${_count(db, 'knowledge_documents', 'id=?', ['persist_doc'])},'
      '${_count(db, 'knowledge_chunks', 'id=?', ['persist_ck'])},'
      '${_count(db, 'market_packages', 'package_id=?', ['org.persist'])},'
      '${_count(db, 'settings', "key=?", ['market.index.etag.src_persist'])},'
      '${_count(db, 'installed_packages', 'installation_id=?', ['inst_persist'])}');
  stdout.writeln('  （写入完成，即将 dispose 关闭 → 重开）');
}

Future<void> _t9_verifyAfterRestart(Database db) async {
  section('#9 重启持久化（重开后逐一断言）');
  t('9.1', '重开 user_version', kSchemaVersion, userVersion(db));
  t('9.2', '知识库仍在（裸SQL）', 1, _count(db, 'knowledge_bases', 'id=?', ['persist_kb']));
  t('9.3', '文档仍在（裸SQL）', 1, _count(db, 'knowledge_documents', 'id=?', ['persist_doc']));
  t('9.4', '分块仍在（裸SQL）', 1, _count(db, 'knowledge_chunks', 'id=?', ['persist_ck']));
  t('9.5', '市场包仍在（裸SQL）', 1, _count(db, 'market_packages', 'package_id=?', ['org.persist']));
  t('9.6', 'etag 仍在且值正确', 'W/"persist"',
      _scalar(db, 'SELECT value FROM settings WHERE key=?', ['market.index.etag.src_persist']));
  t('9.7', '已安装记录仍在（裸SQL）', 1,
      _count(db, 'installed_packages', 'installation_id=?', ['inst_persist']));
  // 仓储层再读一遍
  final kb = SqliteKnowledgeRepository(db);
  final mkt = SqliteMarketRepository(db);
  t('9.8', '仓储 listChunks 读回', 1, (await kb.listChunks('persist_doc')).length);
  t('9.9', '仓储 getInstalledByPackageId 读回', 'inst_persist',
      (await mkt.getInstalledByPackageId('org.persist'))?.installationId);
}

// ---------------------------------------------------------------------------
// #1 补充：FK 开关不再依赖调用方（回归守护；Round 2 已修复）
// ---------------------------------------------------------------------------

Future<void> _t1b_fkOffRisk(Directory tmp, String sep) async {
  section('#1b 回归守护：裸开连接时 FK 是否由 schema 路径自动开启（Round 2 修复后）');
  final path = '${tmp.path}${sep}raw.sqlite';
  final raw = sqlite3.open(path); // 直接用 sqlite3.open，不设 PRAGMA
  ensureSchema(raw); // 修复后：ensureSchema 入口会 enableForeignKeys(db)
  final fk = _scalar(raw, 'PRAGMA foreign_keys;');
  t('1b.1', '裸开连接 + ensureSchema 后 foreign_keys 应已开启', 1, fk,
      note: '修复点：support.dart 在 openAdvisorDatabase/applySchema/ensureSchema 均 enableForeignKeys；'
          '旧缺陷时此处为 0');

  // 级联必须生效 → 删除文档不得留下孤儿分块
  final kb = SqliteKnowledgeRepository(raw);
  final now = DateTime.now().millisecondsSinceEpoch;
  await kb.upsertBase(KnowledgeBase(id: 'kb_off', name: 'OFF', createdAt: now, updatedAt: now));
  await kb.upsertDocument(KnowledgeDocument(
      id: 'd_off', knowledgeBaseId: 'kb_off', fileName: 'f', filePath: '/f', fileHash: 'H',
      fileSize: 1, status: DocumentStatus.indexed, createdAt: now, updatedAt: now));
  await kb.insertChunks([
    KnowledgeChunk(id: 'ck_off', documentId: 'd_off', text: 't', sequence: 1, chunkHash: 'h'),
  ]);
  await kb.deleteDocument('d_off');
  final orphan = _count(raw, 'knowledge_chunks', 'id=?', ['ck_off']);
  t('1b.2', 'FK=ON 时无孤儿分块（级联生效）', 0, orphan,
      note: '修复后级联由 PRAGMA 驱动生效；旧缺陷时为 1（残留孤儿）');
  raw.dispose();
}

// ---------------------------------------------------------------------------

void _printReport() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('# QA 用例表');
  stdout.writeln('| ID | 用例 | 期望 | 实际 | 结论 |');
  stdout.writeln('|----|------|------|------|------|');
  for (final r in _results) {
    final e = r.expected.replaceAll('|', '\\|');
    final a = r.actual.replaceAll('|', '\\|');
    stdout.writeln('| ${r.id} | ${r.name} | $e | $a | ${r.pass ? 'PASS' : 'FAIL'} |');
  }
  stdout.writeln('\n合计：通过 $_pass ／ 失败 $_fail');
  if (_fail > 0) {
    stdout.writeln('\n失败明细：');
    for (final r in _results.where((r) => !r.pass)) {
      stdout.writeln('  - [${r.id}] ${r.name}：期望=${r.expected} 实际=${r.actual}'
          '${r.note == null ? '' : '  （${r.note}）'}');
    }
  }
}
