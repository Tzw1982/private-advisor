/// 存储层端到端验证脚本（纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_storage && dart run tool/verify_storage.dart`
///
/// 覆盖：
/// 1. schema 一致性 + `applySchema` 切分约束（schema.sql 内不得有引号内分号）；
/// 2. 知识库全链路：createBase → importDocument → listDocuments → listChunks →
///    embedding（含"外键陷阱"防御）→ deleteDocument → deleteBase；
/// 3. 市场仓储：upsertSource → replacePackages（**按 source 作用域**）→ listPackages
///    → getPackage → upsertInstalled → etag（settings KV）；
/// 4. **关闭并重开同一 DB 文件后数据仍在**（持久化）；
/// 5. **v6 → v7 迁移专项（#58「专家 emoji 不显示」根因修复）**：
///    `market_packages` 补 `emoji`/`color` 两列——存量 284 行不丢、两列补齐、
///    幂等（连跑 + user_version 回退 6/1 重跑）、重复 open 幂等、仓储
///    roundtrip（逐字一致 / null 透传 / 脏值原样 / 二次替换不残留）；
/// 6. **v7 → v8 迁移专项（#59「点击添加没反应」根因之二）**：
///    `market_packages` 补 `slug` 一列——存量 284 行不丢、列补齐、**升级后
///    既有行 slug 为空串 → refreshIndex（replacePackages）后才写入真实值**、
///    幂等（连跑 + user_version 回退 7/1 重跑）、重复 open 幂等、仓储
///    roundtrip（逐字一致 / 空串透读 / 脏值原样 / 二次替换更新不残留），
///    并防回归：v7 两列 emoji/color 与 slug 同时在。
///
/// SQLite 原生库：本机为 Windows，使用系统 `winsqlite3.dll` 驱动
/// （生产 Flutter 路径不 override，由 `sqlite3_flutter_libs` 提供）。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';
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

bool _isAscending(List<int> xs) {
  for (var i = 1; i < xs.length; i++) {
    if (xs[i] < xs[i - 1]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  // 纯 Dart 环境使用系统 winsqlite3.dll 驱动 SQLite（仅验证脚本做 override）。
  open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));

  stdout.writeln('私人顾问团 · 存储层验证（advisor_storage）');
  stdout.writeln('=' * 60);
  stdout.writeln('sqlite3 版本 = ${sqlite3.version.libVersion}');

  _verifySchema();

  final tmpDir = Directory.systemTemp.createTempSync('pa_storage_verify_');
  final dbPath = '${tmpDir.path}${Platform.pathSeparator}advisor_verify.sqlite';

  // v4 → v5 迁移专项（group_configs +3 列）
  await _verifyGroupConfigV5Migration(tmpDir);

  // v5 → v6 专项（message_attachments 新表 / 迁移 / 幂等 / FK cascade 实测）
  await _verifyAttachmentsV6(tmpDir);

  // v6 → v7 专项（market_packages +emoji/color 两列，#58「专家 emoji 不显示」修复）
  await _verifyMarketEmojiV7(tmpDir);

  // v7 → v8 专项（market_packages +slug 一列，#59「点击添加没反应」根因之二修复）
  await _verifyMarketSlugV8(tmpDir);

  // ---- 阶段一：首次打开，跑知识库 + 市场 ----------
  final db = openAdvisorDatabase(dbPath);
  final version = ensureSchema(db);
  section('schema 迁移');
  checkEq('ensureSchema 返回 9（第 #66 轮：experts +avatar_emoji/avatar_color）', version, 9);
  checkEq('PRAGMA user_version = 9', userVersion(db), 9);
  checkEq('再次 ensureSchema 幂等', ensureSchema(db), 9);
  check('foreign_keys 实测 = 1（ON）——app 连接经 ensureSchema 后 FK 为 ON',
      db.select('PRAGMA foreign_keys;').first.values.first == 1);

  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final knowledge = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 120),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    embeddingModel: HashEmbeddingModel(dimension: 256),
  );

  // 共享的临时源文件
  final sampleFile = File('${tmpDir.path}${Platform.pathSeparator}规格书.md');
  sampleFile.writeAsStringSync('''
# 工程车技术规格书

## 3.2.1 车辆性能参数

整车整备质量为 12000 kg，最大总质量 18000 kg，轴距 4500 mm，
最高车速不低于 100 km/h，油箱容积 6000 L。

## 3.2.2 液压泵参数

液压泵额定流量 60 L/s，额定压力 1.0 MPa，最大吸深 7 m。
''');

  await _verifyKnowledge(knowledge, repos, sampleFile);
  await _verifyFts(db, repos);
  await _verifyStartupBackfill(db, repos);
  await _verifyMarket(repos);

  db.dispose();
  stdout.writeln('\n（阶段一完成：关闭数据库连接）');

  // ---- 阶段二：重开同一 DB 文件，验证持久化 ----------
  final db2 = openAdvisorDatabase(dbPath);
  ensureSchema(db2);
  checkEq('重开：user_version 仍为 9', userVersion(db2), 9);
  final repos2 = sqliteRepositories(db2, secrets: InMemorySecretStore());
  await _verifyPersistence(repos2);
  db2.dispose();

  // ---- 收尾 ----------
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

  // 清理临时目录
  try {
    tmpDir.deleteSync(recursive: true);
  } catch (_) {
    // 忽略清理失败（WAL 文件可能仍被占用）。
  }
}

// ---------------------------------------------------------------------------
// 0. schema 一致性 + 切分约束
// ---------------------------------------------------------------------------

void _verifySchema() {
  section('schema 一致性 / 切分约束');

  // 回归断言：schema.sql 内不得出现引号内的分号（applySchema 依赖 split(';')）。
  final embedded = kAdvisorSchemaSql;
  final quoted = RegExp(r"'[^']*'").allMatches(embedded).map((m) => m.group(0)!);
  check('schema.sql 不存在引号内的分号', quoted.every((q) => !q.contains(';')));
  check('schema 含 FTS5 虚表 knowledge_chunks_fts', embedded.contains('knowledge_chunks_fts'));

  final onDisk = _locateSchemaSql();
  if (onDisk == null) {
    check('schema.g.dart 与 schema.sql 一致', false, '未找到 schema.sql（跳过一致性比对）');
    return;
  }
  final diskContent = onDisk.readAsStringSync();
  check('schema.g.dart 与 schema.sql 逐字一致', diskContent == embedded,
      'disk=${diskContent.length} embedded=${embedded.length}');
}

/// 定位 canonical `schema.sql`（优先 CWD，其次脚本相对路径）。
File? _locateSchemaSql() {
  final candidates = <String>[
    'lib/src/database/schema.sql',
  ];
  try {
    final scriptDir = File.fromUri(Platform.script).parent;
    candidates
      ..add('${scriptDir.parent.path}${Platform.pathSeparator}lib${Platform.pathSeparator}src${Platform.pathSeparator}database${Platform.pathSeparator}schema.sql')
      ..add('${scriptDir.path}${Platform.pathSeparator}..${Platform.pathSeparator}lib${Platform.pathSeparator}src${Platform.pathSeparator}database${Platform.pathSeparator}schema.sql');
  } catch (_) {
    // Platform.script 不可用时忽略。
  }
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 0b. v4 → v5 迁移（group_configs +3 列，含幂等 + 版本回退重跑）
// ---------------------------------------------------------------------------

bool _columnExists(Database db, String table, String column) => db
    .select('PRAGMA table_info($table)')
    .any((r) => (r['name'] as String?) == column);

/// 表是否存在（`sqlite_master`，**不依赖任何仓储 API**——迁移断言用）。
bool _tableExists(Database db, String table) => db
    .select("SELECT name FROM sqlite_master WHERE type='table' AND name = ?", [table])
    .isNotEmpty;

/// 索引是否存在。
bool _indexExists(Database db, String index) => db
    .select("SELECT name FROM sqlite_master WHERE type='index' AND name = ?", [index])
    .isNotEmpty;

/// 取 DDL 原文（迁移 / FK 断言用）。
String? _ddlOf(Database db, String name) {
  final rs = db.select("SELECT sql FROM sqlite_master WHERE name = ?", [name]);
  return rs.isEmpty ? null : rs.first['sql'] as String?;
}

/// 子表行数（**绕开仓储 API 直查**，用于 FK cascade 实测）。
int _countRows(Database db, String table, {String? where, List<Object?>? args}) {
  final suffix = where == null ? '' : ' WHERE $where';
  final rs = db.select('SELECT COUNT(*) AS c FROM $table$suffix', args ?? const []);
  return (rs.first['c'] as num?)?.toInt() ?? 0;
}

// ---------------------------------------------------------------------------
// 0c. v5 → v6 迁移 + message_attachments + FK cascade 实测
// ---------------------------------------------------------------------------

Message _userMessage(String id, String convId, {String content = '原始消息'}) => Message(
      id: id,
      conversationId: convId,
      senderType: MessageSenderType.user,
      senderId: 'e_demo',
      content: content,
      status: MessageStatus.completed,
      createdAt: 1700000000000,
      updatedAt: 1700000000000,
    );

Attachment _attachmentFixture({
  required String id,
  required String messageId,
  required String sha256,
  String fileName = '示意图.png',
}) =>
    Attachment(
      id: id,
      messageId: messageId,
      kind: AttachmentKind.image,
      fileName: fileName,
      storedPath: 'E:/data/attachments/${sha256.substring(0, 2)}/$sha256.png',
      sha256: sha256,
      sizeBytes: 2048,
      mimeType: 'image/png',
      createdAt: 1700000000000,
    );

/// v5 → v6：**0→6**（全新库）与 **5→6**（存量库）两路径、幂等、FK cascade 实测。
/// （第 #59 轮起 kSchemaVersion=8，两路径的最终版本断言已同步为 8。）
///
/// 重点验证（架构 §5 验证项 4–7）：
/// - 0→6：全新库建全部表，`message_attachments` 存在且索引齐；
/// - 5→6：存量库升级后表新增、既有 `group_configs` 三列**不回退**；
/// - **幂等**：连续 `ensureSchema` 两次（含 `user_version` 回退到 5 / 1 重跑）不报错；
/// - **FK cascade 实测**：插消息+附件 → 外键 ON 下**直查子表**确认行消失；
///   再显式关 FK 证明级联**不**生效（从而证明"服务层显式删"双保险确有必要）；
/// - DDL 级联断言：`message_attachments` 的 DDL 含 `ON DELETE CASCADE`；
/// - 仓储 roundtrip：insert / listByMessage / **listByMessages 批量（防 N+1）** /
///   findBySha256 / countByStoredPath（含 excludeId）/ deleteByMessage；
/// - `MessageRepository.deleteMessage`：删除后附件查询为空。
Future<void> _verifyAttachmentsV6(Directory tmpDir) async {
  section('v5 → v6 迁移 + message_attachments + FK cascade 实测');

  // ---- 路径 A：0 → 6（全新库） ----
  final freshPath = '${tmpDir.path}${Platform.pathSeparator}v6_fresh.sqlite';
  final dbA = openAdvisorDatabase(freshPath);
  check('路径 A 前置：全新库 user_version = 0', userVersion(dbA) == 0);
  checkEq('路径 A：ensureSchema 升级到 9', ensureSchema(dbA), 9);
  check('路径 A：message_attachments 表存在', _tableExists(dbA, 'message_attachments'));
  check('路径 A：idx_attachments_msg 存在', _indexExists(dbA, 'idx_attachments_msg'));
  check('路径 A：idx_attachments_sha 存在', _indexExists(dbA, 'idx_attachments_sha'));
  final ddlA = _ddlOf(dbA, 'message_attachments');
  check('路径 A：DDL 含 ON DELETE CASCADE', (ddlA ?? '').contains('ON DELETE CASCADE'),
      ddlA == null ? 'DDL 为空' : null);
  check('路径 A：DDL 外键指向 messages(id)', (ddlA ?? '').contains('REFERENCES messages(id)'));

  // ---- 路径 B：5 → 6（存量库：先建全表，再把 user_version 摁回 5） ----
  final dbB = openAdvisorDatabase('${tmpDir.path}${Platform.pathSeparator}v6_upgrade.sqlite');
  applySchema(dbB, kAdvisorSchemaSql);
  dbB.execute('PRAGMA user_version = 5;');
  check('路径 B 前置：user_version = 5（模拟第 6 轮存量库）', userVersion(dbB) == 5);
  check('路径 B 前置：v5 三列已存在', _columnExists(dbB, 'group_configs', 'announcement'));
  final vB = ensureSchema(dbB);
  checkEq('路径 B：ensureSchema 从 5 升到 9', vB, 9);
  check('路径 B：message_attachments 表新增', _tableExists(dbB, 'message_attachments'));
  check('路径 B：user_version = 9', userVersion(dbB) == 9);
  check('路径 B：既有 group_configs.announcement 列不回退',
      _columnExists(dbB, 'group_configs', 'announcement'));
  check('路径 B：既有 group_configs.max_speakers_per_round 列不回退',
      _columnExists(dbB, 'group_configs', 'max_speakers_per_round'));
  check('路径 B：既有消息/会话表不受影响',
      _tableExists(dbB, 'messages') && _tableExists(dbB, 'conversations'));

  // ---- 幂等：连跑 + 版本回退重跑 ----
  var threwB = false;
  try {
    ensureSchema(dbB);
    ensureSchema(dbB);
  } catch (e) {
    threwB = true;
    check('幂等重跑不抛异常（占位）', false, '$e');
  }
  if (!threwB) check('路径 B：连续 ensureSchema 两次不抛异常', true);
  checkEq('路径 B：幂等重跑后版本仍为 9', userVersion(dbB), 9);

  dbB.execute('PRAGMA user_version = 5;');
  var threwC = false;
  try {
    ensureSchema(dbB);
  } catch (e) {
    threwC = true;
    check('版本回退到 5 重跑（占位）', false, '$e');
  }
  if (!threwC) check('路径 B：user_version 回退到 5 重跑不崩溃', true);
  checkEq('路径 B：回退重跑后版本恢复 9', userVersion(dbB), 9);

  dbB.execute('PRAGMA user_version = 1;');
  var threwD = false;
  try {
    ensureSchema(dbB);
  } catch (e) {
    threwD = true;
    check('版本回退到 1 重跑（占位）', false, '$e');
  }
  if (!threwD) check('路径 B：user_version 回退到 1 重跑不崩溃', true);
  checkEq('路径 B：回退到 1 重跑后版本恢复 9', userVersion(dbB), 9);

  // ---- tenant：会话 + 消息 + 附件 ----
  final reposA = sqliteRepositories(dbB, secrets: InMemorySecretStore());
  await reposA.conversations.upsertConversation(Conversation(
        id: 'conv_att',
        type: ConversationType.single,
        createdAt: 1700000000000,
        updatedAt: 1700000000000,
      ));
  await reposA.messages.insertMessage(_userMessage('msg_att_1', 'conv_att'));

  // ---- FK cascade 实测（绕开仓储 API，直查子表） ----
  section('FK cascade 实测（直查子表，绕开仓储 API）');
  await reposA.attachments.insertAttachment(_attachmentFixture(
        id: 'att_1', messageId: 'msg_att_1', sha256: 'aaaa1111bbbb2222cccc3333dddd4444'));
  check('前置：message_attachments 有 1 行', _countRows(dbB, 'message_attachments') == 1);
  check('前置：foreign_keys 实测 = 1（ON）',
      dbB.select('PRAGMA foreign_keys;').first.values.first == 1);

  // ① 外键 ON：直接 DELETE 消息行 → 子表行**自动消失**（DDL 级联生效）。
  dbB.execute('DELETE FROM messages WHERE id = ?', ['msg_att_1']);
  check('① FK ON 下直删消息 → message_attachments 行自动消失（cascade 生效）',
      _countRows(dbB, 'message_attachments') == 0);
  check('① 消息行也已删除', _countRows(dbB, 'messages') == 0);

  // ② 反证：显式关 FK → cascade **不**生效 → 证明"服务层显式删"双保险确有必要。
  await reposA.messages.insertMessage(_userMessage('msg_att_2', 'conv_att'));
  await reposA.attachments.insertAttachment(_attachmentFixture(
        id: 'att_2', messageId: 'msg_att_2', sha256: 'eeee5555ffff6666aaaa7777bbbb8888'));
  dbB.execute('PRAGMA foreign_keys = OFF;');
  check('② 前置：foreign_keys 已显式关闭（=0）',
      dbB.select('PRAGMA foreign_keys;').first.values.first == 0);
  dbB.execute('DELETE FROM messages WHERE id = ?', ['msg_att_2']);
  check('② FK OFF 下直删消息 → 附件行**残留**（cascade 失效，反证成立）',
      _countRows(dbB, 'message_attachments') == 1);
  // 恢复 ON，然后用服务层显式删（双保险路径）清理。
  dbB.execute('PRAGMA foreign_keys = ON;');
  await reposA.attachments.deleteByMessage('msg_att_2');
  check('② 恢复 FK ON 后，服务层显式 deleteByMessage 清掉残留行',
      _countRows(dbB, 'message_attachments') == 0);

  // ---- 仓储 roundtrip ----
  section('AttachmentRepository roundtrip');
  await reposA.messages.insertMessage(_userMessage('msg_r1', 'conv_att'));
  await reposA.messages.insertMessage(_userMessage('msg_r2', 'conv_att'));
  final sha1 = '1111aaaa2222bbbb3333cccc4444dddd';
  final sha2 = '5555eeee6666ffff7777aaaa8888bbbb';
  await reposA.attachments.insertAttachments([
    _attachmentFixture(id: 'r1', messageId: 'msg_r1', sha256: sha1),
    _attachmentFixture(id: 'r2', messageId: 'msg_r1', sha256: sha2, fileName: '长篇文档.pdf'),
    _attachmentFixture(id: 'r3', messageId: 'msg_r2', sha256: sha1, fileName: '示意图 副本.png'),
  ]);

  final byM1 = await reposA.attachments.listAttachmentsByMessage('msg_r1');
  checkEq('listAttachmentsByMessage 返回 2 条', byM1.length, 2);
  check('附件 kind 正确解析为 image',
      byM1.every((a) => a.kind == AttachmentKind.image));
  check('附件 mimeType 读回', byM1.first.mimeType == 'image/png');
  check('附件 storedPath 读回', byM1.first.storedPath.contains('/attachments/'));

  final byMs = await reposA.attachments.listAttachmentsByMessages(['msg_r1', 'msg_r2']);
  checkEq('listAttachmentsByMessages 批量查返回 3 条（防 N+1）', byMs.length, 3);
  check('listAttachmentsByMessages 空入参返回空',
      (await reposA.attachments.listAttachmentsByMessages(const [])).isEmpty);

  final found = await reposA.attachments.findBySha256(sha1);
  check('findBySha256 命中（同内容复用同一物理文件）', found != null);
  check('findBySha256 未命中返回 null', (await reposA.attachments.findBySha256('deadbeef')) == null);

  checkEq('countByStoredPath(sha1) = 2（同内容被 2 条记录引用）',
      await reposA.attachments.countByStoredPath(byM1.first.storedPath), 2);
  checkEq('countByStoredPath 排除自身 r1 → 1',
      await reposA.attachments.countByStoredPath(byM1.first.storedPath, excludeId: 'r1'), 1);

  // ---- MessageRepository.deleteMessage ----
  section('MessageRepository.deleteMessage');
  await reposA.messages.deleteMessage('msg_r1');
  check('deleteMessage 后 listAttachmentsByMessage 为空（显式删生效）',
      (await reposA.attachments.listAttachmentsByMessage('msg_r1')).isEmpty);
  check('deleteMessage 后 getMessage 为 null', (await reposA.messages.getMessage('msg_r1')) == null);
  check('deleteMessage 不影响另一条消息的附件',
      (await reposA.attachments.listAttachmentsByMessage('msg_r2')).length == 1);

  dbA.dispose();
  dbB.dispose();
}

// ---------------------------------------------------------------------------
// 0d. v6 → v7 迁移：market_packages 补 emoji / color 两列（#58）
// ---------------------------------------------------------------------------

/// v6 → v7：市场卡片 emoji 数据链修复（#58「专家 emoji 不显示」）。
///
/// 根因：远端索引自第 7 轮 T06 起携带 emoji/color（域模型早已支持），但
/// `market_packages` 表缺列 → 仓储丢字段 → 卡片回退「首字 + 确定性色」。
///
/// 本函数验证（additive，禁 DROP/CREATE 重建）：
/// - 路径 A（**0 → 7 全新库**）：建表即含两列，`user_version=7`；
/// - 路径 B（**6 → 7 存量库**）：手工建**旧版** `market_packages`（无两列，
///   与 `_verifyGroupConfigV5Migration` 同模式——当前 canonical DDL 已含两列，
///   不能再靠它造「缺列」前置）+ 预置 **284 行**存量索引（对应用户实机库行数）
///   → 守卫补列后**一行不丢**、存量行两列默认 NULL；
/// - **幂等**：连续 `ensureSchema` + `user_version` 回退到 6 / 1 重跑不崩溃；
/// - **重复 open 幂等**：关闭再开同一 DB 文件，版本/列/行数/数据不变；
/// - 仓储 roundtrip：`replacePackages` → `listPackages` / `getPackage`
///   **逐字一致**、null 透传（不是空串）、脏值（空串/超长/非法色值）原样存取。
///
/// （第 #59 轮起 kSchemaVersion=8：本节构造的 v6 存量库经守卫链 6→7→8 一次
/// 走完，最终版本断言已同步为 8；emoji/color 两列的迁移语义不变。）
Future<void> _verifyMarketEmojiV7(Directory tmpDir) async {
  section('v6 → v7 迁移：market_packages +emoji/color（存量 284 行不丢 / 幂等 / roundtrip）');

  // ---- 路径 A：0 → 7（全新库，建表即含两列） ----
  final dbA = openAdvisorDatabase('${tmpDir.path}${Platform.pathSeparator}v7_fresh.sqlite');
  check('路径 A 前置：全新库 user_version = 0', userVersion(dbA) == 0);
  checkEq('路径 A：ensureSchema 升级到 9', ensureSchema(dbA), 9);
  check('路径 A：market_packages.emoji 列存在（新库建表即含）',
      _columnExists(dbA, 'market_packages', 'emoji'));
  check('路径 A：market_packages.color 列存在（新库建表即含）',
      _columnExists(dbA, 'market_packages', 'color'));

  final reposA = sqliteRepositories(dbA, secrets: InMemorySecretStore());
  await reposA.market.upsertSource(
      const MarketSource(id: 'src_v7', name: '源', baseUrl: 'https://v7.example'));
  await _verifyMarketEmojiRoundtrip(reposA, 'src_v7');
  dbA.dispose();

  // ---- 路径 B：6 → 7（存量库：旧版 market_packages 无两列 + 284 行预置） ----
  final dbPathB = '${tmpDir.path}${Platform.pathSeparator}v7_upgrade.sqlite';
  final dbB = openAdvisorDatabase(dbPathB);
  // 模拟 v6 库：显式建**旧版** market_packages（缺 emoji/color 两列），
  // 其余表交由 applySchema 建（market_packages 已存在 → CREATE IF NOT EXISTS
  // 跳过，保持旧版缺列形态）。
  dbB.execute('''
CREATE TABLE IF NOT EXISTS market_packages (
    package_id      TEXT PRIMARY KEY,
    source_id       TEXT NOT NULL,
    display_name    TEXT NOT NULL,
    profession      TEXT,
    description     TEXT,
    category_id     TEXT,
    tags_json       TEXT,
    latest_version  TEXT,
    sha256          TEXT,
    signature       TEXT,
    FOREIGN KEY (source_id) REFERENCES market_sources(id) ON DELETE CASCADE
);''');
  applySchema(dbB, kAdvisorSchemaSql);
  _insertStockPackages(dbB);
  dbB.execute('PRAGMA user_version = 6;'); // 模拟第 7 轮之前的存量库。

  check('路径 B 前置：user_version = 6（模拟存量库）', userVersion(dbB) == 6);
  check('路径 B 前置：emoji 列不存在', !_columnExists(dbB, 'market_packages', 'emoji'));
  check('路径 B 前置：color 列不存在', !_columnExists(dbB, 'market_packages', 'color'));
  checkEq('路径 B 前置：存量 market_packages 行数 = 284',
      _countRows(dbB, 'market_packages'), 284);

  final vB = ensureSchema(dbB);
  checkEq('路径 B：ensureSchema 从 6 升到 9', vB, 9);
  check('路径 B：emoji 列已补齐', _columnExists(dbB, 'market_packages', 'emoji'));
  check('路径 B：color 列已补齐', _columnExists(dbB, 'market_packages', 'color'));
  checkEq('路径 B：存量 284 行一行不丢', _countRows(dbB, 'market_packages'), 284);
  final stockRow = dbB
      .select("SELECT emoji, color FROM market_packages WHERE package_id = 'org.v7.stock.000'");
  check('路径 B：存量行 emoji 默认 NULL（不重写既有数据）',
      stockRow.isNotEmpty && stockRow.first['emoji'] == null,
      "row=${stockRow.isEmpty ? '缺失' : stockRow.first['emoji']}");
  check('路径 B：存量行 color 默认 NULL（不重写既有数据）',
      stockRow.isNotEmpty && stockRow.first['color'] == null,
      "row=${stockRow.isEmpty ? '缺失' : stockRow.first['color']}");

  // 存量行经仓储读回：emoji/color 为 null（走回退档「首字 + 确定性色」）。
  final reposB = sqliteRepositories(dbB, secrets: InMemorySecretStore());
  final stockGot = await reposB.market.getPackage('org.v7.stock.042');
  check('路径 B：存量行读回 emoji 为 null（回退档，行为不变）',
      stockGot != null && stockGot.emoji == null);
  check('路径 B：存量行读回 color 为 null（回退档，行为不变）',
      stockGot != null && stockGot.color == null);

  // 幂等：连续 ensureSchema 不重复 ALTER、版本不变、行数不变。
  var threw = false;
  try {
    ensureSchema(dbB);
    ensureSchema(dbB);
  } catch (e) {
    threw = true;
    check('路径 B：幂等重跑不抛异常（占位）', false, '$e');
  }
  if (!threw) check('路径 B：连续 ensureSchema 两次不抛异常', true);
  checkEq('路径 B：幂等重跑后版本仍为 9', userVersion(dbB), 9);
  checkEq('路径 B：幂等重跑后 284 行不丢', _countRows(dbB, 'market_packages'), 284);

  // 版本回退重跑（双保险）：列已存在 + user_version 回退 → 不得崩溃。
  dbB.execute('PRAGMA user_version = 6;');
  var threw6 = false;
  try {
    ensureSchema(dbB);
  } catch (e) {
    threw6 = true;
    check('路径 B：回退到 6 重跑（占位）', false, '$e');
  }
  if (!threw6) check('路径 B：user_version 回退到 6 重跑不崩溃', true);
  checkEq('路径 B：回退重跑后版本恢复 9', userVersion(dbB), 9);

  dbB.execute('PRAGMA user_version = 1;');
  var threw1 = false;
  try {
    ensureSchema(dbB);
  } catch (e) {
    threw1 = true;
    check('路径 B：回退到 1 重跑（占位）', false, '$e');
  }
  if (!threw1) check('路径 B：user_version 回退到 1 重跑不崩溃（列均已存在）', true);
  checkEq('路径 B：回退到 1 重跑后版本恢复 9', userVersion(dbB), 9);

  // 升级后存量库上的仓储 roundtrip（新源，不动存量 284 行）。
  await reposB.market.upsertSource(
      const MarketSource(id: 'src_v7rt', name: '源RT', baseUrl: 'https://v7rt.example'));
  await _verifyMarketEmojiRoundtrip(reposB, 'src_v7rt');
  checkEq('路径 B：roundtrip 后存量 284 行仍在',
      _countRows(dbB, 'market_packages', where: "source_id = 'src_stock'"), 284);

  // ---- 重复 open 幂等：关闭再开同一 DB 文件 ----
  dbB.dispose();
  final dbB2 = openAdvisorDatabase(dbPathB);
  checkEq('重复 open：ensureSchema 仍返回 9', ensureSchema(dbB2), 9);
  check('重复 open：emoji 列仍在', _columnExists(dbB2, 'market_packages', 'emoji'));
  check('重复 open：color 列仍在', _columnExists(dbB2, 'market_packages', 'color'));
  checkEq('重复 open：存量 284 行不丢（按 source 精确计数）',
      _countRows(dbB2, 'market_packages', where: "source_id = 'src_stock'"), 284);
  checkEq('重复 open：总行数 = 284 存量 + 1 roundtrip',
      _countRows(dbB2, 'market_packages'), 285);
  final reposB2 = sqliteRepositories(dbB2, secrets: InMemorySecretStore());
  // 重开后再做一次 roundtrip：证明「升级 + 重开」后的库两列读写均正常。
  await reposB2.market.replacePackages('src_v7rt', [
    MarketPackage(
      packageId: 'org.v7.rt-reopen',
      slug: 'rt-reopen',
      displayName: '重开专家',
      categoryId: '09-OperationsHR',
      latestVersion: SemVer.parse('1.0.0'),
      emoji: '🧭',
      color: '#0EA5E9',
    ),
  ]);
  final reopenGot = await reposB2.market.getPackage('org.v7.rt-reopen');
  check('重复 open：重开后写入读回 emoji 一致', reopenGot?.emoji == '🧭');
  check('重复 open：重开后写入读回 color 一致', reopenGot?.color == '#0EA5E9');
  final reopenStock = await reposB2.market.getPackage('org.v7.stock.001');
  check('重复 open：存量行 emoji 仍为 null', reopenStock?.emoji == null);
  dbB2.dispose();
}

/// 预置 284 行存量 `market_packages`（模拟用户实机库；v6 形态，无 emoji/color）。
void _insertStockPackages(Database db) {
  db.execute('INSERT INTO market_sources (id,name,base_url,enabled) '
      "VALUES ('src_stock','存量源','https://stock.example',1)");
  transaction(db, () {
    for (var i = 0; i < 284; i++) {
      final id = 'org.v7.stock.${i.toString().padLeft(3, '0')}';
      db.execute('''
        INSERT INTO market_packages
          (package_id,source_id,display_name,profession,description,category_id,
           tags_json,latest_version,sha256,signature)
        VALUES (?,?,?,?,?,?,?,?,?,?)
      ''', [
        id,
        'src_stock',
        '存量专家 $i',
        '职业 $i',
        '第 #58 轮迁移前置的存量索引行',
        '09-OperationsHR',
        '["存量"]',
        '1.0.0',
        null,
        null,
      ]);
    }
  });
}

/// 仓储 roundtrip：emoji/color 逐字一致 / null 透传 / 脏值原样 / 二次替换不残留。
Future<void> _verifyMarketEmojiRoundtrip(Repositories repos, String sourceId) async {
  section('MarketRepository emoji/color roundtrip（$sourceId）');

  final longEmoji = '👔' * 40; // 超长 emoji 脏值（40 个 👔）。
  await repos.market.replacePackages(sourceId, [
    MarketPackage(
      packageId: 'org.v7.rt-ok',
      slug: 'rt-ok',
      displayName: '有 emoji 专家',
      profession: '测试',
      description: 'roundtrip 正样',
      categoryId: '09-OperationsHR',
      tags: const ['roundtrip'],
      latestVersion: SemVer.parse('1.0.0'),
      versions: [
        MarketVersion(
          packageId: 'org.v7.rt-ok',
          version: SemVer.parse('1.0.0'),
          releaseUrl: 'https://v7.example/rt-ok-1.0.0.expert',
          sha256: 'abc',
        ),
      ],
      emoji: '👔',
      color: '#6B7280',
    ),
    MarketPackage(
      packageId: 'org.v7.rt-none',
      slug: 'rt-none',
      displayName: '无 emoji 专家',
      categoryId: '09-OperationsHR',
      latestVersion: SemVer.parse('1.0.0'),
    ),
    MarketPackage(
      packageId: 'org.v7.rt-dirty',
      slug: 'rt-dirty',
      displayName: '脏值专家',
      categoryId: '09-OperationsHR',
      latestVersion: SemVer.parse('1.0.0'),
      emoji: longEmoji,
      color: '这不是合法色值',
    ),
    MarketPackage(
      packageId: 'org.v7.rt-empty',
      slug: 'rt-empty',
      displayName: '空串专家',
      categoryId: '09-OperationsHR',
      latestVersion: SemVer.parse('1.0.0'),
      emoji: '',
      color: '',
    ),
  ]);

  final list = await repos.market.listPackages(sourceId: sourceId);
  checkEq('roundtrip：listPackages 数量', list.length, 4);
  MarketPackage byId(String id) => list.firstWhere((p) => p.packageId == id);
  checkEq('roundtrip：emoji 逐字一致', byId('org.v7.rt-ok').emoji, '👔');
  checkEq('roundtrip：color 逐字一致', byId('org.v7.rt-ok').color, '#6B7280');
  check('roundtrip：不带 emoji → 读回 null（不是空串）',
      byId('org.v7.rt-none').emoji == null, "actual=${byId('org.v7.rt-none').emoji}");
  check('roundtrip：不带 color → 读回 null（不是空串）', byId('org.v7.rt-none').color == null);
  checkEq('roundtrip：超长 emoji 原样存取（不抛、不改写）',
      byId('org.v7.rt-dirty').emoji, longEmoji);
  checkEq('roundtrip：非法色值字符串原样存取', byId('org.v7.rt-dirty').color, '这不是合法色值');
  check('roundtrip：空串 emoji 原样存取（不被改写为 null）',
      byId('org.v7.rt-empty').emoji == '', "actual=${byId('org.v7.rt-empty').emoji}");
  check('roundtrip：空串 color 原样存取（不被改写为 null）',
      byId('org.v7.rt-empty').color == '', "actual=${byId('org.v7.rt-empty').color}");

  final got = await repos.market.getPackage('org.v7.rt-ok');
  check('roundtrip：getPackage 单查带得到 emoji', got?.emoji == '👔');
  check('roundtrip：getPackage 单查带得到 color', got?.color == '#6B7280');
  checkEq('roundtrip：getPackage 不影响其他字段（displayName）', got?.displayName, '有 emoji 专家');
  checkEq('roundtrip：getPackage versions 仍带 1 条', got?.versions.length, 1);

  // 同 source 二次 replacePackages 不残留旧 emoji/color。
  await repos.market.replacePackages(sourceId, [
    MarketPackage(
      packageId: 'org.v7.rt-ok',
      slug: 'rt-ok',
      displayName: '有 emoji 专家',
      categoryId: '09-OperationsHR',
      latestVersion: SemVer.parse('1.0.0'),
    ),
  ]);
  final second = await repos.market.listPackages(sourceId: sourceId);
  checkEq('roundtrip：二次 replacePackages 后包数', second.length, 1);
  check('roundtrip：二次替换（不带 emoji）不残留旧 emoji', second.first.emoji == null,
      'actual=${second.first.emoji}');
  check('roundtrip：二次替换（不带 color）不残留旧 color', second.first.color == null,
      'actual=${second.first.color}');
}

// ---------------------------------------------------------------------------
// 0e. v7 → v8 迁移：market_packages 补 slug 列（#59）
// ---------------------------------------------------------------------------

/// v7 → v8：安装目录坍缩修复（#59「人才市场点添加没反应」根因之二）。
///
/// 根因：`MarketPackage.slug` 是安装目录 `packages/<slug>-<version>`
/// （market_page.dart 的 install()）的组成部分，但 `market_packages` 表 v7 及
/// 之前未存该列 → 仓储 `_package()` 只能以空串还原 → **所有包的安装目录都是
/// 同一个 `packages/-1.0.0`**，每装一个专家就覆盖上一个的文件（用户实机库
/// `installed_packages` 8 行 install_path 全部相同的铁证；根因之一
/// main.dart 的 GlobalKey 未挂载致 currentState 恒 null，已由主理人修复）。
///
/// 本函数验证（additive，禁 DROP/CREATE 重建）：
/// - 路径 A（**0 → 8 全新库**）：建表即含 slug，`user_version=8`；
/// - 路径 B（**7 → 8 存量库**）：手工建 **v7 形态** `market_packages`（含
///   emoji/color、**无 slug**，与 `_verifyMarketEmojiV7` 同模式）+ 预置
///   **284 行**存量索引（对应用户实机库行数）→ 守卫补列后**一行不丢**、
///   存量行 slug 默认 NULL → 仓储读回**空串**；
/// - **升级不救存量**（关键路径实证）：既有行 slug 读回空串 → 必须**再点一次
///   「刷新索引」**（`replacePackages`，即 `refreshIndex` 的落库那一步）后
///   才写入真实 slug，安装目录恢复 `packages/<slug>-<version>` 形式；
/// - **幂等**：连续 `ensureSchema` + `user_version` 回退到 7 / 1 重跑不崩溃；
/// - **重复 open 幂等**：关闭再开同一 DB 文件，版本/列/行数/数据不变；
/// - 仓储 roundtrip：`replacePackages` → `listPackages` / `getPackage`
///   slug **逐字一致**、空串透读、脏值（超长）原样、二次替换更新不残留；
/// - **防回归**：v7 两列 emoji/color 与 slug **同时**在（证明 v8 没弄丢 v7）。
Future<void> _verifyMarketSlugV8(Directory tmpDir) async {
  section(
      'v7 → v8 迁移：market_packages +slug（存量 284 行不丢 / 升级后 refreshIndex 才写入 / 幂等 / roundtrip）');

  // ---- 路径 A：0 → 8（全新库，建表即含 slug） ----
  final dbA = openAdvisorDatabase(
      '${tmpDir.path}${Platform.pathSeparator}v8_fresh.sqlite');
  check('路径 A 前置：全新库 user_version = 0', userVersion(dbA) == 0);
  checkEq('路径 A：ensureSchema 升级到 9', ensureSchema(dbA), 9);
  check('路径 A：market_packages.slug 列存在（新库建表即含）',
      _columnExists(dbA, 'market_packages', 'slug'));
  check(
      '路径 A：v7 两列未丢（emoji/color 仍在，防回归）',
      _columnExists(dbA, 'market_packages', 'emoji') &&
          _columnExists(dbA, 'market_packages', 'color'));

  final reposA = sqliteRepositories(dbA, secrets: InMemorySecretStore());
  await reposA.market.upsertSource(const MarketSource(
      id: 'src_v8', name: '源', baseUrl: 'https://v8.example'));
  await _verifyMarketSlugRoundtrip(reposA, 'src_v8');
  dbA.dispose();

  // ---- 路径 B：7 → 8（存量库：v7 形态 market_packages 无 slug 列 + 284 行预置） ----
  final dbPathB = '${tmpDir.path}${Platform.pathSeparator}v8_upgrade.sqlite';
  final dbB = openAdvisorDatabase(dbPathB);
  // 模拟 v7 库：显式建 **v7 形态** market_packages（含 emoji/color、缺 slug）。
  // 其余表交由 applySchema 建（market_packages 已存在 → CREATE IF NOT EXISTS
  // 跳过，保持旧版缺列形态）。
  dbB.execute('''
CREATE TABLE IF NOT EXISTS market_packages (
    package_id      TEXT PRIMARY KEY,
    source_id       TEXT NOT NULL,
    display_name    TEXT NOT NULL,
    profession      TEXT,
    description     TEXT,
    category_id     TEXT,
    tags_json       TEXT,
    latest_version  TEXT,
    sha256          TEXT,
    signature       TEXT,
    emoji           TEXT,
    color           TEXT,
    FOREIGN KEY (source_id) REFERENCES market_sources(id) ON DELETE CASCADE
);''');
  applySchema(dbB, kAdvisorSchemaSql);
  _insertStockPackagesV7(dbB);
  dbB.execute('PRAGMA user_version = 7;'); // 模拟第 #59 轮之前的存量库（v7 形态）。

  check('路径 B 前置：user_version = 7（模拟存量库）', userVersion(dbB) == 7);
  check('路径 B 前置：slug 列不存在', !_columnExists(dbB, 'market_packages', 'slug'));
  check(
      '路径 B 前置：v7 两列已在（emoji/color）',
      _columnExists(dbB, 'market_packages', 'emoji') &&
          _columnExists(dbB, 'market_packages', 'color'));
  checkEq('路径 B 前置：存量 market_packages 行数 = 284',
      _countRows(dbB, 'market_packages'), 284);

  final vB = ensureSchema(dbB);
  checkEq('路径 B：ensureSchema 从 7 升到 9', vB, 9);
  check('路径 B：slug 列已补齐', _columnExists(dbB, 'market_packages', 'slug'));
  checkEq('路径 B：存量 284 行一行不丢', _countRows(dbB, 'market_packages'), 284);

  // 存量行经仓储读回：slug 为**空串**（映射 `?? ''`，与 fromJson 口径一致），
  // emoji/color 保持升级前写入的值（v7 数据不被 v8 破坏）。
  final reposB = sqliteRepositories(dbB, secrets: InMemorySecretStore());
  final stockGot = await reposB.market.getPackage('org.v8.stock.042');
  check('路径 B：存量行读回 slug 为空串（不是 null，映射 ?? \'\'）',
      stockGot != null && stockGot.slug == '', "actual=${stockGot?.slug}");
  check('路径 B：存量行读回 emoji 保持升级前写入值', stockGot != null && stockGot.emoji == '👔',
      "actual=${stockGot?.emoji}");
  check(
      '路径 B：存量行读回 color 保持升级前写入值',
      stockGot != null && stockGot.color == '#6B7280',
      "actual=${stockGot?.color}");

  // —— 关键路径：升级不救存量，必须「刷新索引」才写入 slug ——
  // 模拟用户再点一次「刷新索引」：MarketService.refreshIndex 拉取远端索引后
  // 经 replacePackages 按 source 作用域重写（284 行重新落库，slug 这次带上）。
  await reposB.market.replacePackages('src_stock', _stockPackagesV8WithSlug());
  final refreshed = await reposB.market.listPackages(sourceId: 'src_stock');
  checkEq('刷新索引后存量行数仍为 284（按 source 作用域重写）', refreshed.length, 284);
  final refreshedGot = await reposB.market.getPackage('org.v8.stock.042');
  check(
      '刷新索引后 slug 写入（不再为空串）',
      refreshedGot != null && refreshedGot.slug == 'stock-042',
      "actual=${refreshedGot?.slug}");
  // 症状记录：安装目录恢复 `packages/<slug>-<version>`，不再坍缩成 `/-1.0.0`。
  final refreshedDir =
      '/data/market/packages/${refreshedGot!.slug}-${refreshedGot.latestVersion}';
  check('安装目录恢复 packages/<slug>-<version>（不再坍缩为 packages/-1.0.0）',
      refreshedDir == '/data/market/packages/stock-042-1.0.0', refreshedDir);

  // 幂等：连续 ensureSchema 不重复 ALTER、版本不变、行数不变。
  var threw = false;
  try {
    ensureSchema(dbB);
    ensureSchema(dbB);
  } catch (e) {
    threw = true;
    check('路径 B：幂等重跑不抛异常（占位）', false, '$e');
  }
  if (!threw) check('路径 B：连续 ensureSchema 两次不抛异常', true);
  checkEq('路径 B：幂等重跑后版本仍为 9', userVersion(dbB), 9);
  checkEq('路径 B：幂等重跑后 284 行不丢', _countRows(dbB, 'market_packages'), 284);

  // 版本回退重跑（双保险）：列已存在 + user_version 回退 → 不得崩溃。
  dbB.execute('PRAGMA user_version = 7;');
  var threw7 = false;
  try {
    ensureSchema(dbB);
  } catch (e) {
    threw7 = true;
    check('路径 B：回退到 7 重跑（占位）', false, '$e');
  }
  if (!threw7) check('路径 B：user_version 回退到 7 重跑不崩溃', true);
  checkEq('路径 B：回退重跑后版本恢复 9', userVersion(dbB), 9);

  dbB.execute('PRAGMA user_version = 1;');
  var threw1 = false;
  try {
    ensureSchema(dbB);
  } catch (e) {
    threw1 = true;
    check('路径 B：回退到 1 重跑（占位）', false, '$e');
  }
  if (!threw1) check('路径 B：user_version 回退到 1 重跑不崩溃（列均已存在）', true);
  checkEq('路径 B：回退到 1 重跑后版本恢复 9', userVersion(dbB), 9);

  // 升级后存量库上的仓储 roundtrip（新源，不动存量 284 行）。
  await reposB.market.upsertSource(const MarketSource(
      id: 'src_v8rt', name: '源RT', baseUrl: 'https://v8rt.example'));
  await _verifyMarketSlugRoundtrip(reposB, 'src_v8rt');
  checkEq(
      '路径 B：roundtrip 后存量 284 行仍在',
      _countRows(dbB, 'market_packages', where: "source_id = 'src_stock'"),
      284);

  // ---- 重复 open 幂等：关闭再开同一 DB 文件 ----
  dbB.dispose();
  final dbB2 = openAdvisorDatabase(dbPathB);
  checkEq('重复 open：ensureSchema 仍返回 9', ensureSchema(dbB2), 9);
  check('重复 open：slug 列仍在', _columnExists(dbB2, 'market_packages', 'slug'));
  check(
      '重复 open：v7 两列仍在（emoji/color）',
      _columnExists(dbB2, 'market_packages', 'emoji') &&
          _columnExists(dbB2, 'market_packages', 'color'));
  checkEq(
      '重复 open：存量 284 行不丢（按 source 精确计数）',
      _countRows(dbB2, 'market_packages', where: "source_id = 'src_stock'"),
      284);
  final reposB2 = sqliteRepositories(dbB2, secrets: InMemorySecretStore());
  final reopenStock = await reposB2.market.getPackage('org.v8.stock.001');
  check(
      '重复 open：存量行 slug 持久有效（刷新索引写入的值仍在）',
      reopenStock != null && reopenStock.slug == 'stock-001',
      "actual=${reopenStock?.slug}");
  check('重复 open：存量行 emoji 仍在（v7 数据不丢）',
      reopenStock != null && reopenStock.emoji == '👔');
  dbB2.dispose();
}

/// 预置 284 行 **v7 形态**存量 `market_packages`（模拟用户实机库：已有
/// emoji/color 数据、无 slug 列；`org.v8.stock.042` 带 emoji/color 便于断言
/// v8 升级不破坏 v7 数据）。
void _insertStockPackagesV7(Database db) {
  db.execute('INSERT INTO market_sources (id,name,base_url,enabled) '
      "VALUES ('src_stock','存量源','https://stock.example',1)");
  transaction(db, () {
    for (var i = 0; i < 284; i++) {
      final id = 'org.v8.stock.${i.toString().padLeft(3, '0')}';
      db.execute('''
        INSERT INTO market_packages
          (package_id,source_id,display_name,profession,description,category_id,
           tags_json,latest_version,sha256,signature,emoji,color)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
      ''', [
        id,
        'src_stock',
        '存量专家 $i',
        '职业 $i',
        '第 #59 轮迁移前置的存量索引行',
        '09-OperationsHR',
        '["存量"]',
        '1.0.0',
        null,
        null,
        '👔',
        '#6B7280',
      ]);
    }
  });
}

/// 「刷新索引」后按 source 重写的 284 行（slug 这次带上 `stock-NNN`）。
List<MarketPackage> _stockPackagesV8WithSlug() => List.generate(
      284,
      (i) => MarketPackage(
        packageId: 'org.v8.stock.${i.toString().padLeft(3, '0')}',
        slug: 'stock-${i.toString().padLeft(3, '0')}',
        displayName: '存量专家 $i',
        profession: '职业 $i',
        description: '第 #59 轮迁移前置的存量索引行',
        categoryId: '09-OperationsHR',
        tags: const ['存量'],
        latestVersion: SemVer.parse('1.0.0'),
        emoji: '👔',
        color: '#6B7280',
      ),
    );

/// 仓储 roundtrip（slug）：逐字一致 / 空串透读 / 脏值原样 / 二次替换更新不残留 /
/// emoji+color+slug 同时在（防回归）。
Future<void> _verifyMarketSlugRoundtrip(
    Repositories repos, String sourceId) async {
  section('MarketRepository slug roundtrip（$sourceId）');

  final longSlug = 'slot-' * 2000; // 超长 slug 脏值（12000 字符）。
  await repos.market.replacePackages(sourceId, [
    MarketPackage(
      packageId: 'org.v8.rt-ok',
      slug: 'life-mentor',
      displayName: '有人生导师',
      profession: '人生顾问',
      description: 'roundtrip 正样',
      categoryId: '09-OperationsHR',
      tags: const ['roundtrip'],
      latestVersion: SemVer.parse('1.0.0'),
      versions: [
        MarketVersion(
          packageId: 'org.v8.rt-ok',
          version: SemVer.parse('1.0.0'),
          releaseUrl: 'https://v8.example/life-mentor-1.0.0.expert',
          sha256: 'abc',
        ),
      ],
      emoji: '👔',
      color: '#6B7280',
    ),
    MarketPackage(
      packageId: 'org.v8.rt-empty',
      slug: '',
      displayName: '空 slug 专家',
      categoryId: '09-OperationsHR',
      latestVersion: SemVer.parse('1.0.0'),
    ),
    MarketPackage(
      packageId: 'org.v8.rt-dirty',
      slug: longSlug,
      displayName: '脏值专家',
      categoryId: '09-OperationsHR',
      latestVersion: SemVer.parse('1.0.0'),
    ),
  ]);

  final list = await repos.market.listPackages(sourceId: sourceId);
  checkEq('roundtrip：listPackages 数量', list.length, 3);
  MarketPackage byId(String id) => list.firstWhere((p) => p.packageId == id);
  // ① slug roundtrip 逐字一致。
  checkEq('① roundtrip：slug 逐字一致', byId('org.v8.rt-ok').slug, 'life-mentor');
  // ② 不带 slug（空串）→ 读回空串（不是 null）。
  check('② roundtrip：空串 slug 读回空串（不是 null）', byId('org.v8.rt-empty').slug == '',
      "actual=${byId('org.v8.rt-empty').slug}");
  // ③ 脏值（超长）原样存取，不抛、不改写。
  checkEq('③ roundtrip：超长 slug 原样存取（不抛、不改写）', byId('org.v8.rt-dirty').slug,
      longSlug);
  // ⑤ emoji/color 与 slug 同时在（防回归：证明 v7 两列没被 v8 弄丢）。
  check(
      '⑤ roundtrip：emoji/color 与 slug 同时在',
      byId('org.v8.rt-ok').emoji == '👔' &&
          byId('org.v8.rt-ok').color == '#6B7280' &&
          byId('org.v8.rt-ok').slug == 'life-mentor');

  // ④ getPackage 单查同样带得到 slug。
  final got = await repos.market.getPackage('org.v8.rt-ok');
  checkEq('④ roundtrip：getPackage 单查带得到 slug', got?.slug, 'life-mentor');
  checkEq('④ roundtrip：getPackage 单查 emoji 仍在', got?.emoji, '👔');
  checkEq('④ roundtrip：getPackage versions 仍带 1 条', got?.versions.length, 1);

  // 同 source 二次 replacePackages 更新 slug 不残留旧值。
  await repos.market.replacePackages(sourceId, [
    MarketPackage(
      packageId: 'org.v8.rt-ok',
      slug: 'life-mentor-v2',
      displayName: '有人生导师',
      categoryId: '09-OperationsHR',
      latestVersion: SemVer.parse('1.0.0'),
    ),
  ]);
  final second = await repos.market.listPackages(sourceId: sourceId);
  checkEq('roundtrip：二次 replacePackages 后包数', second.length, 1);
  check('roundtrip：二次替换更新 slug 不残留旧值', second.first.slug == 'life-mentor-v2',
      "actual=${second.first.slug}");
  check('roundtrip：二次替换（不带 emoji）不残留旧 emoji', second.first.emoji == null,
      'actual=${second.first.emoji}');
}

Future<void> _verifyGroupConfigV5Migration(Directory tmpDir) async {
  section('v4 → v5 迁移（group_configs +3 列 / 幂等 / 版本回退重跑）');

  final db = openAdvisorDatabase('${tmpDir.path}${Platform.pathSeparator}v4.sqlite');
  // 模拟 **v4 库**：手工建**旧版** group_configs（无第 6 轮 v5 三列）。
  // 第 6 轮起三列已写进 canonical DDL（schema.sql，与 style_id 同模式）→ 不能再用
  // 当前 schema.sql 建库来造「缺列」前置（那样表已含列）；故显式建旧版表，其余表交由
  // applySchema 建（group_configs 已存在 → CREATE IF NOT EXISTS 跳过，保持旧版缺列）。
  db.execute('''
CREATE TABLE IF NOT EXISTS group_configs (
    conversation_id         TEXT PRIMARY KEY,
    speak_strategy          TEXT NOT NULL DEFAULT 'auto',
    summarizer_expert_id    TEXT,
    context_window          INTEGER,
    max_rounds              INTEGER DEFAULT 1,
    token_budget            INTEGER,
    duplicate_threshold     REAL DEFAULT 0.82,
    topic_threshold         REAL DEFAULT 0.02,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
);''');
  applySchema(db, kAdvisorSchemaSql);
  db.execute('PRAGMA user_version = 4;'); // 模拟 v4 库：表已建、缺 3 列。

  check('前置：announcement 列不存在', !_columnExists(db, 'group_configs', 'announcement'));
  check('前置：announcement_updated_at 列不存在',
      !_columnExists(db, 'group_configs', 'announcement_updated_at'));
  check('前置：max_speakers_per_round 列不存在',
      !_columnExists(db, 'group_configs', 'max_speakers_per_round'));

  final v = ensureSchema(db);
  checkEq('ensureSchema 升级到 9（v5 三列 + v6 新表 + v7 两列 + v8 slug + v9 两列）', v, 9);
  checkEq('PRAGMA user_version = 9', userVersion(db), 9);
  check('announcement 列已补', _columnExists(db, 'group_configs', 'announcement'));
  check('announcement_updated_at 列已补', _columnExists(db, 'group_configs', 'announcement_updated_at'));
  check('max_speakers_per_round 列已补', _columnExists(db, 'group_configs', 'max_speakers_per_round'));
  check('v6：message_attachments 表已由 applySchema 建好（no-op 守卫）',
      _tableExists(db, 'message_attachments'));
  check('v6：索引 idx_attachments_msg 已建', _indexExists(db, 'idx_attachments_msg'));
  check('v6：索引 idx_attachments_sha 已建', _indexExists(db, 'idx_attachments_sha'));

  // 幂等：连续 ensureSchema 不重复 ALTER、版本不变。
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
  db.execute('PRAGMA user_version = 4;');
  var threw2 = false;
  try {
    ensureSchema(db);
  } catch (e) {
    threw2 = true;
    check('版本回退到 4 重跑（占位）', false, '$e');
  }
  if (!threw2) check('版本回退到 4（列已存在）ensureSchema 不崩溃', true);
  checkEq('回退重跑后版本恢复 9', userVersion(db), 9);

  // 更狠：回退到 1（会依次触发 v3/v4/v5 守卫，列均已存在）。
  db.execute('PRAGMA user_version = 1;');
  var threw3 = false;
  try {
    ensureSchema(db);
  } catch (e) {
    threw3 = true;
    check('版本回退到 1 重跑（占位）', false, '$e');
  }
  if (!threw3) check('版本回退到 1 重跑不崩溃', true);

  // 读写 roundtrip：新三列经仓储落库并读回（公告 / 公告时间 / 单轮上限）。
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final now = DateTime.now().millisecondsSinceEpoch;
  await repos.conversations.upsertConversation(Conversation(
    id: 'cg_v5',
    type: ConversationType.group,
    title: '迁移验证群',
    createdAt: now,
    updatedAt: now,
  ));
  await repos.conversations.upsertGroupConfig(GroupConfig(
    conversationId: 'cg_v5',
    announcement: '本群只为商务合规项目服务。',
    announcementUpdatedAt: 1700000000000,
    maxSpeakersPerRound: 2,
  ));
  final cfg = await repos.conversations.getGroupConfig('cg_v5');
  checkEq('新列 roundtrip：announcement', cfg?.announcement, '本群只为商务合规项目服务。');
  checkEq('新列 roundtrip：announcementUpdatedAt', cfg?.announcementUpdatedAt, 1700000000000);
  checkEq('新列 roundtrip：maxSpeakersPerRound', cfg?.maxSpeakersPerRound, 2);
  // 未设新列的旧行：NULL 透传（服务层再兜底为默认 3）。
  checkEq('未设时 maxSpeakersPerRound = NULL', cfg == null ? null : cfg.speakStrategy, 'auto');

  db.dispose();
}

// ---------------------------------------------------------------------------
// 1. 知识库全链路
// ---------------------------------------------------------------------------

Future<void> _verifyKnowledge(
  KnowledgeService knowledge,
  Repositories repos,
  File sampleFile,
) async {
  section('知识库全链路（建库 → 导入 → 列表 → 分块 → 删除）');

  final base = await knowledge.createBase(name: '验证知识库');
  check('createBase 成功', base.id.isNotEmpty);
  checkEq('getBase 读回 name', (await repos.knowledge.getBase(base.id))?.name, '验证知识库');

  final imported = await knowledge.importDocument(
    knowledgeBaseId: base.id,
    filePath: sampleFile.path,
    fileName: '规格书.md',
    fileBytes: sampleFile.readAsBytesSync(),
  );
  checkEq('importDocument → 已索引', imported.doc.status, DocumentStatus.indexed);
  check('importDocument 产出分块', imported.chunkCount > 0, 'chunks=${imported.chunkCount}');

  // 去重：同内容重复导入不新增文档
  final dup = await knowledge.importDocument(
    knowledgeBaseId: base.id,
    filePath: sampleFile.path,
    fileName: '规格书.md',
    fileBytes: sampleFile.readAsBytesSync(),
  );
  checkEq('同库同哈希重复导入被去重', dup.chunkCount, imported.chunkCount);
  checkEq('去重后文档数仍为 1', (await knowledge.listDocuments(base.id)).length, 1);

  final docs = await knowledge.listDocuments(base.id);
  checkEq('listDocuments 数量', docs.length, 1);

  final chunks = await knowledge.listChunks(imported.doc.id);
  check('listChunks 数量 > 0', chunks.length > 0, 'chunks=${chunks.length}');
  check('分块 sequence 递增有序', _isAscending(chunks.map((c) => c.sequence).toList()));

  // 服务级 upsertEmbeddingModel + 仓储 upsertEmbedding 均生效
  final chunkIds = chunks.map((c) => c.id).toList();
  final embeddings = await repos.knowledge.listEmbeddings(chunkIds);
  check('embedding 已写入（服务级显式 upsertEmbeddingModel）', embeddings.isNotEmpty,
      'embeddings=${embeddings.length}');
  check('embedding 模型档案已落库',
      (await repos.knowledge.listEmbeddingModels()).isNotEmpty);

  // —— 外键陷阱防御：直接用未注册模型 id 写 embedding，必须成功 ——
  const directModelId = 'emb_direct_fk_test';
  var fkOk = true;
  String? fkErr;
  try {
    await repos.knowledge.upsertEmbedding(ChunkEmbedding(
      chunkId: chunks.first.id,
      embeddingModelId: directModelId,
      dimension: 8,
      vectorRef: 'vec:direct',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  } catch (e) {
    fkOk = false;
    fkErr = '$e';
  }
  check('upsertEmbedding 对未注册模型自动补占位行（无外键失败）', fkOk, fkErr);

  final modelIds = (await repos.knowledge.listEmbeddingModels()).map((m) => m.id).toSet();
  check('占位模型已落库', modelIds.contains(directModelId));
  final placeholder = (await repos.knowledge.listEmbeddingModels())
      .firstWhere((m) => m.id == directModelId);
  checkEq('占位模型 runtime = unknown', placeholder.runtime, 'unknown');
  final directRead = await repos.knowledge.listEmbeddings([chunks.first.id]);
  check('直接写入的 embedding 可读回',
      directRead.any((e) => e.embeddingModelId == directModelId));

  // —— 删除文档：级联删 chunks + embeddings ——
  await knowledge.deleteDocument(imported.doc.id);
  check('deleteDocument 后文档清空', (await knowledge.listDocuments(base.id)).isEmpty);
  check('级联删除 knowledge_chunks', (await knowledge.listChunks(imported.doc.id)).isEmpty);
  check('级联删除 chunk_embeddings', (await repos.knowledge.listEmbeddings(chunkIds)).isEmpty);

  // —— 删除知识库 ——
  await knowledge.deleteBase(base.id);
  check('deleteBase 后知识库清空', (await knowledge.listBases()).isEmpty);

  // —— 造一个"持久化库"，用于重开验证 ——
  final persistBase = await knowledge.createBase(name: '持久化验证库');
  final persistImport = await knowledge.importDocument(
    knowledgeBaseId: persistBase.id,
    filePath: sampleFile.path,
    fileName: '规格书.md',
    fileBytes: sampleFile.readAsBytesSync(),
  );
  check('持久化库导入成功', persistImport.chunkCount > 0, 'chunks=${persistImport.chunkCount}');
}

// ---------------------------------------------------------------------------
// 2. FTS5 检索（bigram 索引 / OR 召回 / coverage 阈值）
// ---------------------------------------------------------------------------

Future<void> _verifyFts(Database db, Repositories repos) async {
  section('FTS5 检索（bigram / OR 召回 / coverage / 删除一致）');

  final rt = Fts5Retriever(db);
  check('FTS5 health() = true（可用）', await rt.health());
  check('FTS5 表存在（level2: schema 已建）', ftsTableExists(db));

  final now = DateTime.now().millisecondsSinceEpoch;
  await repos.knowledge
      .upsertBase(KnowledgeBase(id: 'kb_f', name: 'FTS库', createdAt: now, updatedAt: now));
  await repos.knowledge.upsertDocument(KnowledgeDocument(
    id: 'doc_f',
    knowledgeBaseId: 'kb_f',
    fileName: '规格.md',
    filePath: '/f',
    fileHash: 'HF',
    fileSize: 1,
    status: DocumentStatus.indexed,
    createdAt: now,
    updatedAt: now,
  ));
  final chunks = [
    KnowledgeChunk(
        id: 'fc1', documentId: 'doc_f', text: '工程车长臂喷射臂架系统', sequence: 0, chunkHash: 'h1'),
    KnowledgeChunk(
        id: 'fc2', documentId: 'doc_f', text: '油箱工程车液压系统额定流量', sequence: 1, chunkHash: 'h2'),
  ];
  await repos.knowledge.insertChunks(chunks);
  await rt.indexChunks(chunks, knowledgeBaseId: 'kb_f', documentId: 'doc_f');
  checkEq('索引写入行数 = 分块数', ftsRowCount(db), 2);

  // —— 回归：「批量不再返回 0」（源自古 fts_probe2 的尾单字 + AND 缺陷场景）——
  final hits = await rt.search('长臂', knowledgeBaseIds: ['kb_f'], topK: 5);
  check('查 “长臂” 命中 ≥1（批量不再返回 0）', hits.isNotEmpty, 'hits=${hits.length}');
  check('命中首块为 fc1', hits.isNotEmpty && hits.first.chunk.id == 'fc1');
  check('score = coverage ∈ (0,1]',
      hits.isNotEmpty && hits.first.score > 0 && hits.first.score <= 1,
      'score=${hits.isEmpty ? null : hits.first.score}');

  final hitsFlow = await rt.search('流量', knowledgeBaseIds: ['kb_f']);
  check('查 “流量” 命中 fc2', hitsFlow.any((h) => h.chunk.id == 'fc2'));

  // coverage 排序：「油箱工程车」应使 fc2 覆盖率高于 fc1
  final ranked = await rt.search('油箱工程车', knowledgeBaseIds: ['kb_f']);
  check('coverage 排序：fc2 排在 fc1 之前',
      ranked.length >= 2 && ranked.first.chunk.id == 'fc2',
      'order=${ranked.map((h) => h.chunk.id).toList()}');

  // 单字 CJK 查询：bigram 为空 → 无结果（方案预期）
  final single = await rt.search('消', knowledgeBaseIds: ['kb_f']);
  check('单字 CJK 查询无结果（bigram 方案预期）', single.isEmpty);

  // 知识库过滤
  final other = await rt.search('长臂', knowledgeBaseIds: ['kb_none']);
  check('KB 过滤：非本库无命中', other.isEmpty);

  // 阈值：覆盖率过滤（长多概念查询 + 高阈值 → 结果更少/为空）
  final loose = await rt.search('工程车臂架流量', knowledgeBaseIds: ['kb_f'], threshold: 0.0);
  final tight = await rt.search('工程车臂架流量', knowledgeBaseIds: ['kb_f'], threshold: 0.99);
  check('高阈值过滤后命中数不增加', tight.length <= loose.length,
      'loose=${loose.length} tight=${tight.length}');

  // 索引维护同步：删除文档后不再命中
  await rt.deleteByDocument('doc_f');
  final after = await rt.search('长臂', knowledgeBaseIds: ['kb_f']);
  check('deleteByDocument 后不再命中', after.isEmpty);
  checkEq('删除后索引行数 = 0', ftsRowCount(db), 0);

  // 清理业务数据
  await repos.knowledge.deleteChunksByDocument('doc_f');
  await repos.knowledge.deleteDocument('doc_f');
  await repos.knowledge.deleteBase('kb_f');
}

// ---------------------------------------------------------------------------
// 3. 启动兜底回填（O-1）
// ---------------------------------------------------------------------------

/// 启动兜底回填验证：构造"已有 chunks 但 FTS 为空"的 v2 库，跑 ensureSchema
/// 应自动回填且可检索；再跑一次应**幂等**（不重复插入）。
Future<void> _verifyStartupBackfill(Database db, Repositories repos) async {
  section('启动兜底回填（O-1：FTS 空 + 有 chunks → ensureSchema 自动回填，幂等）');

  final now = DateTime.now().millisecondsSinceEpoch;
  await repos.knowledge
      .upsertBase(KnowledgeBase(id: 'kb_bf', name: '回填验证库', createdAt: now, updatedAt: now));
  await repos.knowledge.upsertDocument(KnowledgeDocument(
    id: 'doc_bf',
    knowledgeBaseId: 'kb_bf',
    fileName: '回填.md',
    filePath: '/bf',
    fileHash: 'HBF',
    fileSize: 1,
    status: DocumentStatus.indexed,
    createdAt: now,
    updatedAt: now,
  ));
  await repos.knowledge.insertChunks([
    KnowledgeChunk(
        id: 'bf1', documentId: 'doc_bf', text: '油箱工程车额定流量与压力', sequence: 0, chunkHash: 'b1'),
    KnowledgeChunk(
        id: 'bf2', documentId: 'doc_bf', text: '长臂喷射臂架系统', sequence: 1, chunkHash: 'b2'),
  ]);

  // 模拟"FTS 被清空"：直接清表（chunks 仍在 knowledge_chunks 中）。
  if (ftsTableExists(db)) {
    db.execute('DELETE FROM $kFtsTable');
  }
  checkEq('前置：FTS 已被清空', ftsRowCount(db), 0);
  final totalChunks = _countKnowledgeChunks(db);
  check('前置：库中仍有 chunks', totalChunks > 0, 'chunks=$totalChunks');

  // 触发启动路径（当前 user_version 已是最新 8，仍必须回填）。
  final v = ensureSchema(db);
  checkEq('已是 v9 时 ensureSchema 仍返回 9', v, 9);
  checkEq('ensureSchema 触发回填：FTS 行数 = 全库 chunks 数', ftsRowCount(db), totalChunks);

  final rt = Fts5Retriever(db);
  final hits = await rt.search('流量', knowledgeBaseIds: ['kb_bf']);
  check('回填后可检索到（不再静默"没找到"）', hits.isNotEmpty, 'hits=${hits.length}');
  check('命中块属 kb_bf', hits.isNotEmpty && hits.first.chunk.documentId == 'doc_bf');

  // 幂等：再次 ensureSchema 不得重复插入。
  ensureSchema(db);
  checkEq('再次 ensureSchema 不重复插入（幂等）', ftsRowCount(db), totalChunks);
  ensureSchema(db);
  checkEq('第三次 ensureSchema 仍幂等', ftsRowCount(db), totalChunks);

  // 清场
  await rt.deleteByDocument('doc_bf');
  await repos.knowledge.deleteChunksByDocument('doc_bf');
  await repos.knowledge.deleteDocument('doc_bf');
  await repos.knowledge.deleteBase('kb_bf');
}

int _countKnowledgeChunks(Database db) {
  final rs = db.select('SELECT COUNT(*) AS c FROM knowledge_chunks');
  return (rs.first['c'] as num?)?.toInt() ?? 0;
}

// ---------------------------------------------------------------------------
// 4. 市场仓储
// ---------------------------------------------------------------------------

Future<void> _verifyMarket(Repositories repos) async {
  section('市场仓储（source / replacePackages 作用域 / packages / installed / etag）');

  await repos.market.upsertSource(
      const MarketSource(id: 'src_a', name: '源A', baseUrl: 'https://a.example'));
  await repos.market.upsertSource(
      const MarketSource(id: 'src_b', name: '源B', baseUrl: 'https://b.example'));
  checkEq('listSources 数量', (await repos.market.listSources()).length, 2);

  final pkgA1 = MarketPackage(
    packageId: 'org.a.one',
    slug: 'a-one',
    displayName: 'A1',
    categoryId: 'cat1',
    tags: const ['x', 'y'],
    latestVersion: SemVer.parse('1.2.0'),
    versions: [
      MarketVersion(
        packageId: 'org.a.one',
        version: SemVer.parse('1.2.0'),
        releaseUrl: 'https://a.example/1.2.0.expert',
        sha256: 'aaa',
        sizeBytes: 100,
        publishedAt: 111,
      ),
    ],
  );
  final pkgA2 = MarketPackage(
    packageId: 'org.a.two',
    slug: 'a-two',
    displayName: 'A2',
    categoryId: 'cat2',
    latestVersion: SemVer.parse('2.0.0'),
  );
  final pkgB1 = MarketPackage(
    packageId: 'org.b.one',
    slug: 'b-one',
    displayName: 'B1',
    categoryId: 'cat1',
    latestVersion: SemVer.parse('3.0.0'),
  );

  await repos.market.replacePackages('src_a', [pkgA1, pkgA2]);
  await repos.market.replacePackages('src_b', [pkgB1]);
  checkEq('listPackages 全量数量', (await repos.market.listPackages()).length, 3);

  // 按 source 作用域替换：仅重写 src_a，不应影响 src_b
  await repos.market.replacePackages('src_a', [pkgA1]);
  checkEq('replacePackages 按 source 作用域（src_a 剩 1）',
      (await repos.market.listPackages(sourceId: 'src_a')).length, 1);
  final bList = await repos.market.listPackages(sourceId: 'src_b');
  checkEq('replacePackages 不影响其他源（src_b 仍 1）', bList.length, 1);
  checkEq('src_b 的包仍在', bList.isEmpty ? null : bList.first.packageId, 'org.b.one');

  checkEq('listPackages 按 category 过滤',
      (await repos.market.listPackages(categoryId: 'cat1')).length, 2);

  final got = await repos.market.getPackage('org.a.one');
  check('getPackage 读回', got != null && got.displayName == 'A1');
  checkEq('getPackage 回填 versions 数量', got?.versions.length, 1);
  checkEq('getPackage latestVersion', got?.latestVersion.toString(), '1.2.0');
  check('getPackage tags 还原', got?.tags.contains('y') ?? false);

  // 已安装
  await repos.market.upsertInstalled(InstalledPackage(
    installationId: 'inst_del',
    packageId: 'org.a.one',
    version: SemVer.parse('1.2.0'),
    installPath: 'C:/pkg/a',
    installedAt: 123,
    source: 'market',
  ));
  checkEq('listInstalled 数量', (await repos.market.listInstalled()).length, 1);
  checkEq('getInstalledByPackageId 命中',
      (await repos.market.getInstalledByPackageId('org.a.one'))?.installationId, 'inst_del');
  await repos.market.deleteInstalled('inst_del');
  check('deleteInstalled 生效', (await repos.market.listInstalled()).isEmpty);

  await repos.market.upsertInstalled(InstalledPackage(
    installationId: 'inst_keep',
    packageId: 'org.a.one',
    version: SemVer.parse('1.2.0'),
    installPath: 'C:/pkg/a',
    installedAt: 456,
    source: 'market',
  ));

  // etag（settings KV）
  await repos.market.setIndexEtag('src_a', 'W/"etag-123"', 999);
  final etag = await repos.market.getIndexEtag('src_a');
  checkEq('etag 读回', etag?.etag, 'W/"etag-123"');
  checkEq('refreshedAt 读回', etag?.refreshedAt, 999);

  await repos.market.setIndexEtag('src_b', null, 1000);
  final etagB = await repos.market.getIndexEtag('src_b');
  check('etag=null 时仍返回 refreshedAt',
      etagB != null && etagB.etag == null && etagB.refreshedAt == 1000,
      'got=$etagB');
  check('未设置的 source etag 为 null',
      (await repos.market.getIndexEtag('src_none')) == null);
}

// ---------------------------------------------------------------------------
// 3. 重启持久化
// ---------------------------------------------------------------------------

Future<void> _verifyPersistence(Repositories repos) async {
  section('重启后数据仍在（关闭并重开同一 DB 文件）');

  final bases = await repos.knowledge.listBases();
  check('知识库仍在', bases.any((b) => b.name == '持久化验证库'), 'bases=${bases.length}');
  final persistBase = bases.firstWhere((b) => b.name == '持久化验证库');
  final docs = await repos.knowledge.listDocuments(persistBase.id);
  check('文档仍在', docs.isNotEmpty, 'docs=${docs.length}');
  if (docs.isNotEmpty) {
    final chunks = await repos.knowledge.listChunks(docs.first.id);
    check('分块仍在', chunks.isNotEmpty, 'chunks=${chunks.length}');
  }

  final a = await repos.market.listPackages(sourceId: 'src_a');
  check('市场包仍在', a.any((p) => p.packageId == 'org.a.one'), 'a=${a.length}');
  final etag = await repos.market.getIndexEtag('src_a');
  checkEq('etag 持久化', etag?.etag, 'W/"etag-123"');
  check('已安装记录仍在',
      (await repos.market.listInstalled()).any((i) => i.installationId == 'inst_keep'));
}
