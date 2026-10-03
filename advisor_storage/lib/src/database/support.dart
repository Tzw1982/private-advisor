/// 存储层通用工具：数据库打开、schema 应用与迁移、事务、Row→值转换、错误归一化。
///
/// 本文件是 `advisor_storage` 的最底层，只依赖 `advisor_core`（错误模型）与
/// `sqlite3`，**不依赖 Flutter**，因此可在纯 Dart 环境（`dart run`）中运行。
///
/// ⚠️ `applySchema` 依赖 `schema.sql` 中"引号内不含分号"的约束（见 §5 待明确 #6），
///    `tool/verify_storage.dart` 有回归断言守护该约束。
library;

import 'dart:convert';

import 'package:advisor_core/advisor_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'schema.g.dart';

/// 当前 schema 版本（写入 `PRAGMA user_version`）。
///
/// 版本历史：
/// - 1：25 张业务表（第 1 轮）；
/// - 2：新增 FTS5 虚表 `knowledge_chunks_fts`（第 2 轮中文检索，**additive**）；
/// - 3：新增 `expert_groups` 表 + `expert_user_states.style_id` 列（第 3 轮通讯录改造，**additive**）；
/// - 4：新增 `knowledge_base_folders` 表 + `knowledge_documents.folder_id`/`source_mtime`
///       两列（第 4 轮知识库「文件夹关联」，**additive**）；
/// - 5：`group_configs` 新增 `announcement` / `announcement_updated_at` /
///       `max_speakers_per_round` 三列（第 6 轮群聊体验改造，**additive**）;
/// - 6：新增 `message_attachments` 表 + 2 索引（第 8 轮会话附件，**additive，无加列**）;
///       守卫内为 **no-op 空分支**——新表由 `schema.sql` 的 `CREATE TABLE IF NOT EXISTS`
///       经 [applySchema] 一次性建好，无需 `ALTER`；分支仍显式存在，防后人误以为漏迁移。
/// - 7：`market_packages` 新增 `emoji` / `color` 两列（第 #58 轮修复「专家 emoji
///       不显示」，**additive，无新表**；与第 3 轮 `style_id` / 第 6 轮
///       `group_configs` 三列同模式：「DDL 内置 + 守卫双保险」）。存量库既有行
///       两列默认 NULL，数据不丢；新库建表即含两列 → 守卫判存后 no-op。
/// - 8：`market_packages` 新增 `slug` 一列（第 #59 轮修复「点击添加没反应」根因
///       之二：slug 未持久化 → 安装目录全部坍缩为 `packages/-1.0.0`，**additive，
///       无新表**；与第 #58 轮 `emoji`/`color` 同模式「DDL 内置 + 守卫双保险」）。
///       存量库既有行默认 NULL，数据不丢；slug 由用户下次「刷新索引」经
///       `replacePackages` 写入（迁移不回填业务字段，远端索引才是唯一事实源）。
/// - 9：`experts` 新增 `avatar_emoji` / `avatar_color` 两列（第 #66 轮修复
///       「专家加进通讯录后 emoji 头像回退首字」，**additive，无新表**；与第
///       #58 轮 `market_packages.emoji`/`color` 同模式「DDL 内置 + 守卫双保险」）。
///       存量库既有行两列默认 NULL → UI 走"首字 + 确定性色"回退，行为不变；
///       新安装的专家由 `MarketService.installPackage` 从市场索引读出 emoji/color
///       一并落库（`verify_storage_v9.dart` 实证）。
const int kSchemaVersion = 9;

/// FTS5 索引表名（与 `schema.sql` 中的虚表名一致）。
const String kFtsTable = 'knowledge_chunks_fts';

// ---------------------------------------------------------------------------
// 数据库打开 / schema
// ---------------------------------------------------------------------------

/// 打开数据库并设置基础 PRAGMA。
///
/// **环境无关**：不在此处 override 原生库加载方式。
/// - 生产（Flutter）：由 `sqlite3_flutter_libs` 提供 SQLite；
/// - 验证（纯 Dart）：由 `tool/verify_storage.dart` 自行
///   `open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'))`。
Database openAdvisorDatabase(String path) {
  final db = sqlite3.open(path);
  enableForeignKeys(db);
  db.execute('PRAGMA journal_mode = WAL;');
  return db;
}

/// 开启外键约束（连接级 PRAGMA）。
///
/// - 连接级：必须对**每一个**新连接执行一次（`sqlite3.open` 默认关闭）。
/// - **必须在事务之外执行**：SQLite 在事务内执行 `PRAGMA foreign_keys` 会**静默忽略**
///   （不报错但不生效）。本包的 schema 应用路径（[applySchema] / [ensureSchema]）
///   均在事务之外调用它，故安全。
///
/// 之所以放进 schema 应用路径：`schema.sql` 里虽写了 `PRAGMA foreign_keys = ON`，
/// 但 `applySchema` 只执行 `CREATE` 开头的语句，该 PRAGMA 会被跳过。若仅靠
/// `openAdvisorDatabase` 里的那一句，则任何**绕过它**的打开入口都会让级联删除
/// **静默失效**（不报错）。此处让 schema 路径自带 FK 开关，消除该脆弱前提。
void enableForeignKeys(Database db) {
  db.execute('PRAGMA foreign_keys = ON;');
}

/// 应用 schema（幂等：DDL 全部为 `CREATE ... IF NOT EXISTS`）。
///
/// 切分策略：以分号切分后，**剥离整行注释**再判定，只执行 `CREATE` 开头的语句。
/// 说明：原 `app/` 实现直接以 `startsWith('--')` 跳过整段，会把"注释头 + CREATE"
/// 的整段一并跳过，导致分节注释（如 `-- === Generation Runtime ===`）后的建表
/// 语句被漏执行——这是迁移时修复的一个潜在缺陷。该策略要求 `schema.sql` 内不
/// 存在引号内的分号，由验证脚本守护。
///
/// 虚表（`CREATE VIRTUAL TABLE`，如 FTS5）单独处理：其创建**依赖运行时能力**
/// （`sqlite3` 须编译进 FTS5 模块）。若目标环境缺失该模块，**不得**让整段 schema
/// 应用失败——此处捕获异常并跳过，检索端由 [ftsAvailable] 探测后自动降级。
void applySchema(Database db, String schemaSql) {
  // 保证外键开启（连接级；在事务之外执行才生效）。
  enableForeignKeys(db);
  for (final raw in schemaSql.split(';')) {
    final stmt = raw
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('--'))
        .join('\n')
        .trim();
    if (stmt.isEmpty) continue;
    final upper = stmt.toUpperCase();
    if (!upper.startsWith('CREATE')) continue;
    if (upper.contains('VIRTUAL TABLE')) {
      // 虚表：能力相关，失败不阻塞核心 schema。
      try {
        db.execute(stmt);
      } catch (_) {
        // 环境不支持（如未编译 FTS5）时静默跳过，由检索端降级。
      }
      continue;
    }
    db.execute(stmt);
  }
}

/// 确保 schema 已就绪：读取 `PRAGMA user_version`，落后时执行幂等建表 + FTS 虚表 +
/// v3 结构升级（`expert_groups` 表 / `expert_user_states.style_id` 列）+ v4 结构升级
/// （`knowledge_base_folders` 表 / `knowledge_documents.folder_id`·`source_mtime` 两列）+
/// v5 结构升级（`group_configs.announcement`·`announcement_updated_at`·`max_speakers_per_round` 三列）+
/// v6 结构升级（`message_attachments` 表 + 2 索引，**no-op 空分支**）+
/// v7 结构升级（`market_packages.emoji`·`color` 两列，守卫补列 / 新库 no-op）+
/// v8 结构升级（`market_packages.slug` 一列，守卫补列 / 新库 no-op）+
/// v9 结构升级（`experts.avatar_emoji`·`avatar_color` 两列，守卫补列 / 新库 no-op），
/// 然后置为 [kSchemaVersion]；**无论是否需要迁移**，最后都执行一次启动兜底回填。
/// 返回最终版本号。
///
/// 迁移原则：只允许 additive migration，**禁止** DROP/CREATE 重建。
///
/// **v2 → v3 的两处结构变更（第 3 轮）**：
/// - `expert_groups`：由 `schema.sql` 的 `CREATE TABLE IF NOT EXISTS` 承载（[applySchema] 执行）；
/// - `expert_user_states.style_id`：`ALTER TABLE ADD COLUMN` **无 `IF NOT EXISTS`** —— 以
///   `PRAGMA user_version < 3` 守卫 + `PRAGMA table_info` 判存**双保险**，确保「新装 DLL 已含该列」
///   与「既有 v2 库补列」两条路径都**只执行一次且幂等**（列已存在则跳过，绝不重复 ALTER 报错）。
///
/// **v3 → v4 的两处结构变更（第 4 轮，同一模式）**：
/// - `knowledge_base_folders`：由 `schema.sql` 的 `CREATE TABLE IF NOT EXISTS` 承载；
/// - `knowledge_documents.folder_id`（TEXT）/ `source_mtime`（INTEGER）：
///   `PRAGMA user_version < 4` 守卫 + `_addColumnIfMissing` 判存双保险
///   （用户手动回退 `user_version` 时列已存在 → 跳过，不重复 ALTER 报错）。
///
/// **v4 → v5 的三处结构变更（第 6 轮，同一模式）**：
/// - `group_configs.announcement`（TEXT）/ `announcement_updated_at`（INTEGER）/
///   `max_speakers_per_round`（INTEGER）：**同时**写进 `schema.sql` 的 canonical DDL
///   （与第 3 轮 `style_id` 同模式），并保留 `PRAGMA user_version < 5` 守卫 +
///   `_addColumnIfMissing` 判存双保险（additive，无新表）——新库建表即含三列（守卫 no-op），
///   老库由守卫补列。（此点区别于第 4 轮 `folder_id` / `source_mtime` 的「只走迁移」模式。）
///
/// **v5 → v6 的唯一结构变更（第 8 轮，本轮只有新表、无加列）**：
/// - `message_attachments`（会话附件）+ `idx_attachments_msg` / `idx_attachments_sha`
///   两索引：**全部由 `schema.sql` 的 `CREATE TABLE/INDEX IF NOT EXISTS` 承载**
///   （[applySchema] 在 `current < 6` 时已执行过一遍），因此守卫内**没有任何 ALTER**——
///   保留空的 `if (current < 6) { ... }` 分支只为**链式可读性**（与 v3/v4/v5 同构，
///   一眼看到本轮"确实没有要补的列"），防后人误以为漏迁移。
///
/// **v6 → v7 的结构变更（第 #58 轮，additive，无新表）**：
/// - `market_packages.emoji`（TEXT）/ `color`（TEXT）两列：**同时**写进
///   `schema.sql` 的 canonical DDL（与第 3 轮 `style_id` / 第 6 轮
///   `group_configs` 三列同模式），并保留 `PRAGMA user_version < 7` 守卫 +
///   `_addColumnIfMissing` 判存双保险——新库建表即含两列（守卫 no-op），老库
///   （第 7 轮 T06 之前的库，`market_packages` 有存量索引行）由守卫补列，
///   `ALTER TABLE ADD COLUMN` 既有行默认 NULL，**数据不丢**。
///
/// **v7 → v8 的唯一结构变更（第 #59 轮，additive，无新表）**：
/// - `market_packages.slug`（TEXT）：**同时**写进 `schema.sql` 的 canonical DDL
///   （与第 3 轮 `style_id` / 第 6 轮 `group_configs` 三列 / 第 #58 轮
///   `emoji`·`color` 两列同模式），并保留 `PRAGMA user_version < 8` 守卫 +
///   `_addColumnIfMissing` 判存双保险——新库建表即含该列（守卫 no-op），老库
///   （`user_version` ≤ 7，`market_packages` 有存量索引行）由守卫补列，
///   `ALTER TABLE ADD COLUMN` 既有行默认 NULL，**数据不丢、不重写**。存量行
///   slug **不在迁移中回填**：远端索引才是唯一事实源，由用户下次「刷新索引」
///   经 `replacePackages` 写入（`verify_storage.dart` v7→v8 迁移节实证）。
///
/// **v8 → v9 的结构变更（第 #66 轮，additive，无新表）**：
/// - `experts.avatar_emoji`（TEXT）/ `avatar_color`（TEXT）：**同时**写进
///   `schema.sql` 的 canonical DDL（与前几轮同模式），并保留
///   `PRAGMA user_version < 9` 守卫 + `_addColumnIfMissing` 判存双保险——
///   新库建表即含两列（守卫 no-op），老库由守卫补列，既有行默认 NULL
///   （UI 回退"首字 + 确定性色"，**零行为回归**；存量行不在迁移中回填）。
///
/// 无论是否需要建表，均在入口显式开启外键（连接级），确保"不经过
/// `openAdvisorDatabase` 的打开路径"同样具备级联删除能力。
///
/// **启动兜底回填（O-1）**：回填**不能只在 1→2 迁移那一刻做**——否则一旦 FTS 索引
/// 被清空（异常、外部工具、半途写入失败等），启动后检索会静默返回"没找到"，而用户
/// 看到的现象是"文档里明明有这个词"，属**静默故障**（与"降级不许静默"同类）。
/// 因此每次 `ensureSchema` 都调用 [tryBackfillFts]：**幂等**——仅当 FTS 表存在、
/// FTS 为空、且 `knowledge_chunks` 非空时才回填；FTS 非空时只是一次 `COUNT` 查询，
/// 不重建、不重复插入，对启动开销可忽略。
int ensureSchema(Database db) {
  enableForeignKeys(db);
  var current = userVersion(db);
  if (current < kSchemaVersion) {
    applySchema(db, kAdvisorSchemaSql);
    if (current < 3) {
      // v3：补 style_id 列（表已存在且缺列时；新装已在 CREATE TABLE 里含该列）。
      _addColumnIfMissing(db, 'expert_user_states', 'style_id', 'TEXT');
    }
    if (current < 4) {
      // v4：补 folder_id / source_mtime 两列（知识库「文件夹关联」第 4 轮）。
      _addColumnIfMissing(db, 'knowledge_documents', 'folder_id', 'TEXT');
      _addColumnIfMissing(db, 'knowledge_documents', 'source_mtime', 'INTEGER');
    }
    if (current < 5) {
      // v5：补群公告 / 公告更新时间 / 单轮发言上限三列（群聊体验改造第 6 轮）。
      _addColumnIfMissing(db, 'group_configs', 'announcement', 'TEXT');
      _addColumnIfMissing(db, 'group_configs', 'announcement_updated_at', 'INTEGER');
      _addColumnIfMissing(db, 'group_configs', 'max_speakers_per_round', 'INTEGER');
    }
    if (current < 6) {
      // v6：只有新表 message_attachments（+2 索引），已由 applySchema 的
      // CREATE TABLE IF NOT EXISTS 建好 → **无 ALTER，no-op 空分支**。
      // 分支保留以维持守卫链可读性（见上方 v5 → v6 说明）。
    }
    if (current < 7) {
      // v7：补 market_packages.emoji / color 两列（第 #58 轮修复「专家 emoji
      // 不显示」）。additive：老库 ALTER 补列（既有行默认 NULL，数据不丢），
      // 新库已在 canonical DDL 含两列 → _addColumnIfMissing 判存后 no-op。
      _addColumnIfMissing(db, 'market_packages', 'emoji', 'TEXT');
      _addColumnIfMissing(db, 'market_packages', 'color', 'TEXT');
    }
    if (current < 8) {
      // v8：补 market_packages.slug 一列（第 #59 轮修复「点击添加没反应」根因
      // 之二）。additive：老库 ALTER 补列（既有行默认 NULL，数据不丢），新库已
      // 在 canonical DDL 含该列 → _addColumnIfMissing 判存后 no-op。
      // 注意：存量行 slug 迁移**不回填**——远端索引才是唯一事实源，由用户下次
      // 「刷新索引」经 replacePackages 写入（verify_storage v7→v8 迁移节实证）。
      _addColumnIfMissing(db, 'market_packages', 'slug', 'TEXT');
    }
    if (current < 9) {
      // v9：补 experts.avatar_emoji / avatar_color 两列（第 #66 轮修复「添加到
      // 通讯录后 emoji 头像回退首字」）。additive：老库 ALTER 补列（既有行默认
      // NULL → UI 回退首字，行为不变），新库已在 canonical DDL 含两列 →
      // _addColumnIfMissing 判存后 no-op。存量行**不回填** emoji：市场索引才是
      // 唯一事实源，由用户下次「刷新索引 + 重新添加」写入。
      _addColumnIfMissing(db, 'experts', 'avatar_emoji', 'TEXT');
      _addColumnIfMissing(db, 'experts', 'avatar_color', 'TEXT');
    }
    _writeUserVersion(db, kSchemaVersion);
    current = kSchemaVersion;
  }
  tryBackfillFts(db);
  return current;
}

/// 幂等地为 [table] 补 [column]（先查 `PRAGMA table_info`，缺列才 `ALTER`）。
///
/// 覆盖两处易踩坑：`ALTER TABLE ADD COLUMN` **无 `IF NOT EXISTS`**；且用户手动
/// 回退 `user_version`（如 QA 构造 v1 场景）时，若仅凭版本守卫会**重复 ALTER 报错**。
void _addColumnIfMissing(Database db, String table, String column, String type) {
  final exists = db.select('PRAGMA table_info($table)').any(
        (row) => (row['name'] as String?) == column,
      );
  if (exists) return;
  db.execute('ALTER TABLE $table ADD COLUMN $column $type;');
}

// ---------------------------------------------------------------------------
// FTS5 索引表工具
// ---------------------------------------------------------------------------

/// FTS5 索引表是否存在。
bool ftsTableExists(Database db) => db
    .select("SELECT name FROM sqlite_master WHERE type='table' AND name = ?", [kFtsTable])
    .isNotEmpty;

/// FTS5 索引当前行数（表不存在时为 0）。
int ftsRowCount(Database db) {
  if (!ftsTableExists(db)) return 0;
  final rs = db.select('SELECT COUNT(*) AS c FROM $kFtsTable');
  return (rs.first['c'] as num?)?.toInt() ?? 0;
}

/// FTS5 是否可用（表存在且可查询）。
bool ftsAvailable(Database db) {
  try {
    if (!ftsTableExists(db)) return false;
    db.select('SELECT rowid FROM $kFtsTable LIMIT 1');
    return true;
  } catch (_) {
    return false;
  }
}

/// 向 FTS 索引写入若干行（`bg` = bigram tokens 以空格连接）。**调用方负责事务**。
void insertFtsRows(
  Database db,
  Iterable<({String chunkId, String documentId, String knowledgeBaseId, String text})> rows,
) {
  for (final r in rows) {
    db.execute('DELETE FROM $kFtsTable WHERE chunk_id = ?', [r.chunkId]);
    db.execute(
      'INSERT INTO $kFtsTable(bg, chunk_id, document_id, knowledge_base_id) VALUES (?,?,?,?)',
      [
        ChineseBigram.tokenize(r.text).join(' '),
        r.chunkId,
        r.documentId,
        r.knowledgeBaseId,
      ],
    );
  }
}

/// 历史分块回填（**幂等**）：仅当 FTS 表存在、索引为空、且已有分块时执行。
///
/// 触发场景：schema 从 v1 升到 v2 时，数据库里可能已有 `knowledge_chunks`
/// 但索引为空——启动阶段一次性补齐。已有索引则直接返回，不重复写入。
void tryBackfillFts(Database db) {
  if (!ftsTableExists(db)) return;
  if (ftsRowCount(db) > 0) return;
  final rows = db.select(
    'SELECT c.id AS chunk_id, c.document_id AS document_id, c.text AS text, '
    'd.knowledge_base_id AS kb_id '
    'FROM knowledge_chunks c JOIN knowledge_documents d ON d.id = c.document_id',
  );
  if (rows.isEmpty) return;
  transaction(db, () {
    insertFtsRows(
      db,
      rows.map((r) => (
            chunkId: r['chunk_id'] as String,
            documentId: r['document_id'] as String,
            knowledgeBaseId: r['kb_id'] as String,
            text: r['text'] as String,
          )),
    );
  });
}

/// 读取当前 `PRAGMA user_version`。
int userVersion(Database db) {
  final rs = db.select('PRAGMA user_version;');
  if (rs.isEmpty) return 0;
  return (rs.first.values.first as num?)?.toInt() ?? 0;
}

void _writeUserVersion(Database db, int version) {
  // PRAGMA 不支持绑定参数；version 为 int，无注入风险。
  db.execute('PRAGMA user_version = $version;');
}

// ---------------------------------------------------------------------------
// 事务
// ---------------------------------------------------------------------------

/// 在单个事务中执行 [body]：正常提交，异常回滚后再抛出。
///
/// 适用场景：批量写入（如 `insertChunks`）与"删旧+插新"（如 `replacePackages`）。
T transaction<T>(Database db, T Function() body) {
  db.execute('BEGIN;');
  try {
    final result = body();
    db.execute('COMMIT;');
    return result;
  } catch (_) {
    try {
      db.execute('ROLLBACK;');
    } catch (_) {
      // 回滚失败时忽略，保留原始异常。
    }
    rethrow;
  }
}

// ---------------------------------------------------------------------------
// Row → 值转换
// ---------------------------------------------------------------------------

/// 归一化为 [int]（NULL 透传）。
int? rowInt(Object? v) => v == null ? null : (v as num).toInt();

/// 归一化为 [String]（NULL 透传）。
String? rowString(Object? v) => v as String?;

/// 归一化为 [double]（NULL 透传）。
double? rowDouble(Object? v) => v == null ? null : (v as num).toDouble();

/// 归一化为 [bool]（SQLite 以 0/1 存储）。
bool rowBool(Object? v) => (v as num? ?? 0) != 0;

/// [bool] → SQLite INTEGER。
int boolToInt(bool v) => v ? 1 : 0;

/// 解析 JSON 字符串数组（失败或非数组时返回空列表）。
List<String> rowJsonList(Object? v) {
  if (v == null) return const [];
  try {
    final decoded = jsonDecode('$v');
    return decoded is List ? decoded.map((e) => '$e').toList() : const [];
  } catch (_) {
    return const [];
  }
}

// ---------------------------------------------------------------------------
// 错误归一化
// ---------------------------------------------------------------------------

/// 把底层异常归一化为 [StorageError]（不向 UI 泄漏 `SqliteException`）。
///
/// [code] 约定：`storage.<area>.<reason>`，例如 `storage.knowledge.insert_chunks`。
StorageError normalizeStorageError(String code, Object cause, [String? message]) =>
    StorageError(code, message ?? '本地存储操作失败', cause);
