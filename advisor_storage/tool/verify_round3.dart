/// 存储层第 3 轮验证脚本（纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_storage && dart run tool/verify_round3.dart`
///
/// 覆盖（T04 完成判据）：
/// 1. **schema v2 → v3 迁移**：构造真实 v2 库（含业务数据）→ `ensureSchema` →
///    断言升到 v3、`expert_groups` 新表 / `style_id` 新列就绪、**既有数据一条不丢**、
///    重复执行**幂等**（不重复 ALTER、不报错）；
/// 2. **分组 CRUD**：`ExpertService.createGroup / listGroups / assignGroup / deleteGroup`
///    （删组清空成员 `group_id`，无 DB FK 由服务层保证）；
/// 3. **风格持久化**：`setStyle / getStyle`（落 `expert_user_states.style_id`，非法值归一 null）；
/// 4. **端到端导入落库**：临时目录（递归 / 跳隐藏临时 / 去重跳过）经 `BatchImporter` +
///    `KnowledgeService` 落库并可经 FTS5 检索命中。
///
/// SQLite 原生库：Windows 使用系统 `winsqlite3.dll`（仅本脚本 override）。
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

void checkEq(String name, Object? actual, Object? expected) =>
    check(name, actual == expected, 'actual=$actual expected=$expected');

int _count(Database db, String sql, [List<Object?> params = const []]) {
  final rs = db.select(sql, params);
  return (rs.first.values.first as num).toInt();
}

bool _tableExists(Database db, String name) =>
    db.select("SELECT name FROM sqlite_master WHERE type='table' AND name = ?", [name]).isNotEmpty;

bool _columnExists(Database db, String table, String column) => db
    .select('PRAGMA table_info($table)')
    .any((r) => (r['name'] as String?) == column);

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));

  stdout.writeln('私人顾问团 · 第 3 轮存储验证（advisor_storage）');
  stdout.writeln('=' * 60);
  stdout.writeln('sqlite3 版本 = ${sqlite3.version.libVersion}');

  final tmp = Directory.systemTemp.createTempSync('pa_round3_storage_');
  final sep = Platform.pathSeparator;

  await _verifyV2ToV3Migration(tmp, sep);
  await _verifyGroupCrudAndStyle(tmp, sep);
  await _verifyEndToEndImport(tmp, sep);

  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {}

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
// 1. v2 → v3 迁移
// ---------------------------------------------------------------------------

/// 构造真实的 v2 库（两条表 + 业务数据 + user_version=2）。
Future<void> _verifyV2ToV3Migration(Directory tmp, String sep) async {
  section('1. schema v2 → v8 迁移（含既有数据不丢 + 幂等）');

  final path = '${tmp.path}${sep}v2.sqlite';
  final db = sqlite3.open(path); // 裸开：模拟旧版数据库文件

  // —— v2 形态的 DDL（experts 全列；expert_user_states **无 style_id**）——
  db.execute('''
    CREATE TABLE experts (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, profession TEXT, avatar_path TEXT,
      system_prompt TEXT NOT NULL, welcome_message TEXT, quick_prompts_json TEXT,
      category_id TEXT, package_id TEXT, package_version TEXT, source TEXT NOT NULL,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    );
  ''');
  db.execute('''
    CREATE TABLE expert_user_states (
      expert_id TEXT PRIMARY KEY, remark TEXT, group_id TEXT,
      pinned INTEGER NOT NULL DEFAULT 0, custom_prompt TEXT,
      is_locked INTEGER NOT NULL DEFAULT 0, local_modified_at INTEGER,
      FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE
    );
  ''');
  final now = DateTime.now().millisecondsSinceEpoch;
  db.execute(
    'INSERT INTO experts (id,name,system_prompt,source,created_at,updated_at) VALUES (?,?,?,?,?,?)',
    ['e_old', '旧专家', '你是旧专家', 'local', now, now],
  );
  db.execute(
    'INSERT INTO expert_user_states (expert_id,remark,pinned,custom_prompt) VALUES (?,?,?,?)',
    ['e_old', '旧备注', 1, '旧自定义提示词'],
  );
  db.execute('PRAGMA user_version = 2');

  // 前置断言
  checkEq('前置：user_version = 2', userVersion(db), 2);
  check('前置：无 style_id 列', !_columnExists(db, 'expert_user_states', 'style_id'));
  check('前置：无 expert_groups 表', !_tableExists(db, 'expert_groups'));
  checkEq('前置：experts 行数 = 1', _count(db, 'SELECT COUNT(*) FROM experts'), 1);

  // —— 升级 ——
  // 注（第 6 轮起）：kSchemaVersion 已升到 9，v2 库经 ensureSchema 一路升到最新版。
  // v3 断言（expert_groups / style_id 就绪）保持不变，最终版本断言改为 8。
  final v = ensureSchema(db);
  checkEq('ensureSchema 升级到最新（v9）', v, 9);
  checkEq('PRAGMA user_version = 9', userVersion(db), 9);
  check('新表 expert_groups 就绪', _tableExists(db, 'expert_groups'));
  check('新列 expert_user_states.style_id 就绪', _columnExists(db, 'expert_user_states', 'style_id'));
  check('FTS5 虚表仍就绪（additive 未破坏）', ftsAvailable(db));

  // 既有业务数据一条不丢
  checkEq('experts 行数仍为 1（不丢）', _count(db, 'SELECT COUNT(*) FROM experts'), 1);
  final remark = db.select("SELECT remark FROM expert_user_states WHERE expert_id='e_old'").first['remark'];
  checkEq('既有备注保留', remark, '旧备注');
  final styleVal =
      db.select("SELECT style_id FROM expert_user_states WHERE expert_id='e_old'").first['style_id'];
  check('既有行 style_id 为 NULL（默认不注入风格）', styleVal == null);

  // 幂等：重复 ensureSchema 不报错、不重复 ALTER、版本不变、数据不变
  var threw = false;
  try {
    ensureSchema(db);
    ensureSchema(db);
  } catch (e) {
    threw = true;
  }
  check('重复 ensureSchema 不抛异常（未重复 ALTER）', !threw);
  checkEq('重复后版本仍为 9', userVersion(db), 9);
  checkEq('重复后 experts 行数仍为 1', _count(db, 'SELECT COUNT(*) FROM experts'), 1);

  // 反向鲁棒性：把 v3 库 user_version 手动回退为 1（列已存在），ensureSchema 仍不得崩溃
  db.execute('PRAGMA user_version = 1');
  var threw2 = false;
  try {
    ensureSchema(db);
  } catch (_) {
    threw2 = true;
  }
  check('列已存在 + 版本回退时 ensureSchema 仍不崩溃', !threw2);
  checkEq('版本重新回到 9', userVersion(db), 9);

  db.dispose();
}

// ---------------------------------------------------------------------------
// 2. 分组 CRUD + 风格持久化
// ---------------------------------------------------------------------------

Future<void> _verifyGroupCrudAndStyle(Directory tmp, String sep) async {
  section('2. 分组 CRUD + 风格持久化（SQLite 仓储）');

  final path = '${tmp.path}${sep}round3a.sqlite';
  final db = openAdvisorDatabase(path);
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final experts = ExpertService(repos);

  check('Repositories.groups 已装配', repos.groups is SqliteGroupRepository);

  final e1 = await experts.createLocal(name: '张三', systemPrompt: 'p1');
  final e2 = await experts.createLocal(name: '李四', systemPrompt: 'p2');

  // —— 分组 CRUD ——
  checkEq('初始分组为空', (await experts.listGroups()).length, 0);
  final g = await experts.createGroup('核心顾问组', sortOrder: 1);
  check('创建分组成功', g.id.isNotEmpty && g.name == '核心顾问组');
  checkEq('listGroups 数量 = 1', (await experts.listGroups()).length, 1);

  await experts.assignGroup(e1.id, g.id);
  final s1 = await repos.experts.getUserState(e1.id);
  checkEq('成员 group_id 已设置', s1?.groupId, g.id);

  // 删除分组：成员 group_id 被服务层清空
  await experts.deleteGroup(g.id);
  checkEq('分组已删除', (await experts.listGroups()).length, 0);
  final s1b = await repos.experts.getUserState(e1.id);
  check('删组后成员 group_id 被清空', s1b?.groupId != g.id, 'groupId=${s1b?.groupId}');

  // —— 风格持久化 ——
  await experts.setStyle(e2.id, 'professional');
  checkEq('风格已落库', await experts.getStyle(e2.id), 'professional');
  final rawStyle = db
      .select("SELECT style_id FROM expert_user_states WHERE expert_id = ?", [e2.id]).first['style_id'];
  checkEq('SQLite 行内 style_id', rawStyle, 'professional');

  await experts.setStyle(e2.id, '不存在的风格');
  check('非法风格被归一为 null（关闭）', await experts.getStyle(e2.id) == null);

  await experts.setStyle(e2.id, 'sharp');
  await experts.setStyle(e2.id, null);
  check('显式置 null 关闭风格', await experts.getStyle(e2.id) == null);

  // resolveEffective 带出风格
  await experts.setStyle(e2.id, 'amiable');
  final eff = await experts.resolveEffective(e2.id);
  checkEq('生效配置带出 styleId', eff.styleId, 'amiable');
  check('StyleLibrary 能据此生成指令',
      StyleLibrary.directiveFor(eff.styleId).contains('风格要求'));

  db.dispose();
}

// ---------------------------------------------------------------------------
// 3. 端到端导入落库（临时目录）
// ---------------------------------------------------------------------------

Future<void> _verifyEndToEndImport(Directory tmp, String sep) async {
  section('3. 多文件夹导入经 KnowledgeService 落库并可检索命中');

  final path = '${tmp.path}${sep}round3b.sqlite';
  final db = openAdvisorDatabase(path);
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final knowledge = KnowledgeService(
    repos,
    parsers: const [PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 120),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    retriever: Fts5Retriever(db),
  );

  // —— 造临时目录：根 a.md / dup.md（同内容）/ b.md / note.xyz；子目录 sub/c.md；
  //    以及应被跳过的 .hidden.md、~$lock.md ——
  final src = Directory('${tmp.path}${sep}import_src')..createSync(recursive: true);
  File('${src.path}${sep}a.md').writeAsStringSync('# 规格书\n\n液压泵额定流量 60 L/s。');
  File('${src.path}${sep}dup.md').writeAsStringSync('# 规格书\n\n液压泵额定流量 60 L/s。');
  File('${src.path}${sep}b.md').writeAsStringSync('# 参数\n\n油箱容积 6000 L。');
  File('${src.path}${sep}note.xyz').writeAsStringSync('不支持的格式');
  File('${src.path}${sep}.hidden.md').writeAsStringSync('隐藏文件不应被扫描');
  File('${src.path}${sep}~\$lock.md').writeAsStringSync('Office 临时锁文件');
  final sub = Directory('${src.path}${sep}sub')..createSync();
  File('${sub.path}${sep}c.md').writeAsStringSync('# 子目录\n\n最大总质量 18000 kg。');

  // 扫描过滤
  final scanned = DirectoryScanner.scan([src.path]);
  final names = scanned.map((f) => f.name).toSet();
  check('递归扫描到子目录文件', names.contains('c.md'));
  check('跳过隐藏文件 .hidden.md', !names.contains('.hidden.md'));
  check('跳过临时文件 ~\$lock.md', !names.contains('~\$lock.md'));
  checkEq('未被跳过的候选数 = 5', scanned.length, 5);

  // 计划分类
  final plan = ImportPlanner.plan([src.path], supportedExtensions: const {'.md', '.markdown', '.txt', '.csv'});
  checkEq('supported = 4（a/dup/b/c）', plan.supported.length, 4);
  checkEq('unsupported = 1（note.xyz）', plan.unsupported.length, 1);
  checkEq('oversize = 0', plan.oversize.length, 0);

  // 大小上限分类（用小上限断言，避免造 50MB 文件）
  final bigPlan = ImportPlanner.planFiles(
    const [ScannedFile(path: 'x.bin', name: 'x.bin', sizeBytes: 100, extension: '.bin')],
    supportedExtensions: const {'.bin'},
    maxBytes: 50,
  );
  checkEq('超限文件归入 oversize', bigPlan.oversize.length, 1);
  check('oversize 原因可读', bigPlan.oversize.first.reason.contains('50MB'));

  // —— 导入落库（sink 用 KnowledgeService；去重经服务返回同 doc.id 识别）——
  final base = await knowledge.createBase(name: '导入验证库');
  final seenDocIds = <String>{};
  Future<ImportFileResult> importOne(ScannedFile f) async {
    final bytes = File(f.path).readAsBytesSync();
    final r = await knowledge.importDocument(
      knowledgeBaseId: base.id,
      filePath: f.path,
      fileName: f.name,
      fileBytes: bytes,
    );
    if (seenDocIds.contains(r.doc.id)) return ImportFileResult.skipped('已存在，跳过');
    seenDocIds.add(r.doc.id);
    return ImportFileResult.success(chunkCount: r.chunkCount);
  }

  final importer = BatchImporter(batchSize: 2);
  ImportProgress? last;
  final progressStamps = <bool>[];
  await for (final p in importer.run(plan: plan, importFile: importOne)) {
    last = p;
    progressStamps.add(p.done);
  }
  check('收到进度流', last != null);
  checkEq('进度流以 done=true 收尾', progressStamps.last, true);
  checkEq('total = 5（含 1 个计划阶段被拒）', last!.total, 5);
  checkEq('processed = 5', last.processed, 5);
  checkEq('success = 3（a/b/c）', last.success, 3);
  checkEq('skipped = 1（dup.md 去重）', last.skipped, 1);
  checkEq('failed = 1（note.xyz 不支持）', last.failed, 1);

  // 落库结果 + 检索命中
  final docs = await repos.knowledge.listDocuments(base.id);
  checkEq('知识库文档数 = 3', docs.length, 3);

  final hits = await knowledge.retrieve(query: '液压泵额定流量', knowledgeBaseIds: [base.id]);
  check('FTS5 检索命中导入内容', hits.isNotEmpty, 'hits=${hits.length}');
  check('引用含来源文件名', hits.isNotEmpty && hits.first.fileName.isNotEmpty);

  // 失败隔离：单文件异常不阻断整批
  final plan2 = ImportPlanner.planFiles(
    const [
      ScannedFile(path: 'ok.md', name: 'ok.md', sizeBytes: 10, extension: '.md'),
      ScannedFile(path: 'boom.md', name: 'boom.md', sizeBytes: 10, extension: '.md'),
    ],
    supportedExtensions: const {'.md'},
  );
  ImportProgress? last2;
  await for (final p in BatchImporter().run(
    plan: plan2,
    importFile: (f) async {
      if (f.name == 'boom.md') throw StateError('模拟解析异常');
      return ImportFileResult.success(chunkCount: 1);
    },
  )) {
    last2 = p;
  }
  checkEq('失败隔离：1 成功 1 失败', '${last2!.success}/${last2.failed}', '1/1');
  check('失败项原因可读', last2.perFile.any((e) => e.status == ImportFileStatus.failed && (e.reason ?? '').contains('模拟')));

  db.dispose();
}
