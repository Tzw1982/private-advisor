/// v8 → v9 迁移专项 + 专家 emoji 头像持久化验证（第 #66 轮，纯 Dart 真 SQLite）。
///
/// 运行：`cd advisor_storage && dart run tool/verify_storage_v9.dart`
///
/// 用户走查缺陷②「市场卡片有 emoji，添加到通讯录后头像没了、回退成首字」：
/// 根因是 `experts` 表**没有** emoji / color 两列，安装落库时把市场包自带的
/// 头像信息直接丢了。本脚本实证 v9（**additive**）的三条路径：
///
/// - **路径 A（全新库 0 → 9）**：canonical DDL 建表即含 `avatar_emoji` /
///   `avatar_color`；
/// - **路径 B（存量 v8 库 8 → 9）**：`ALTER TABLE ADD COLUMN` 补两列，
///   **既有行两列为 NULL**（UI 走"首字 + 确定性色"回退，**零行为回归**），
///   其它字段与行一个不丢；幂等（连跑 / `user_version` 回退 8、1 重跑）；
/// - **路径 C（端到端持久化）**：市场索引 emoji/color → `MarketService`
///   安装 → 专家行两列落库 → **关库重开后仍在**（真 SQLite 文件）。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';
import 'package:advisor_storage/advisor_storage.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（与 verify_storage 同款）
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

bool _columnExists(Database db, String table, String column) => db
    .select('PRAGMA table_info($table)')
    .any((r) => (r['name'] as String?) == column);

/// v8 形态的 `experts` 表（**无** avatar_emoji / avatar_color 两列）。
const String _v8ExpertsDdl = '''
CREATE TABLE experts (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    profession      TEXT,
    avatar_path     TEXT,
    system_prompt   TEXT NOT NULL,
    welcome_message TEXT,
    quick_prompts_json TEXT,
    category_id     TEXT,
    package_id      TEXT,
    package_version TEXT,
    source          TEXT NOT NULL,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
)
''';

/// 造一个 **v8 形态**的存量库（含 1 行老专家，模拟用户实机库）。
Database _makeV8Database(String path) {
  final f = File(path);
  if (f.existsSync()) f.deleteSync();
  final db = sqlite3.open(path);
  db.execute('PRAGMA foreign_keys = ON');
  db.execute(_v8ExpertsDdl);
  db.execute(
      "INSERT INTO experts (id,name,profession,avatar_path,system_prompt,"
      "quick_prompts_json,category_id,package_id,package_version,source,"
      "created_at,updated_at) VALUES "
      "('e_stock','存量老专家','老职业',NULL,'老提示词','[]',"
      "'02-Engineering','org.v8.stock','1.0.0','market',1700000000000,1700000000000)");
  db.execute('PRAGMA user_version = 8');
  return db;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  // 纯 Dart 环境使用系统 winsqlite3.dll 驱动 SQLite（仅验证脚本做 override）。
  open.overrideFor(
      OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));

  stdout.writeln('私人顾问团 · v8 → v9 迁移 / 专家 emoji 持久化（advisor_storage）');
  stdout.writeln('=' * 60);
  stdout.writeln('sqlite3 版本 = ${sqlite3.version.libVersion}');
  stdout.writeln('kSchemaVersion = $kSchemaVersion');

  final tmpDir = Directory.systemTemp.createTempSync('pa_v9_verify_');
  final sep = Platform.pathSeparator;

  // ── §1 路径 A：全新库（0 → 9） ────────────────────────────────
  section('§1 路径 A：全新库建表即含两列');
  final dbFresh = openAdvisorDatabase('${tmpDir.path}${sep}fresh.sqlite');
  final vA = ensureSchema(dbFresh);
  checkEq('ensureSchema 返回 9', vA, 9);
  checkEq('PRAGMA user_version = 9', _userVersion(dbFresh), 9);
  check('experts 含 avatar_emoji 列',
      _columnExists(dbFresh, 'experts', 'avatar_emoji'));
  check('experts 含 avatar_color 列',
      _columnExists(dbFresh, 'experts', 'avatar_color'));
  check('v8 的 market_packages.slug 仍在（防回归）',
      _columnExists(dbFresh, 'market_packages', 'slug'));
  check('v7 的 market_packages.emoji 仍在（防回归）',
      _columnExists(dbFresh, 'market_packages', 'emoji'));

  // ── §2 路径 B：存量 v8 库（8 → 9） ────────────────────────────
  section('§2 路径 B：存量 v8 库补两列 / 存量行不丢 / 幂等');
  final dbB = _makeV8Database('${tmpDir.path}${sep}v8_upgrade.sqlite');
  check('升级前：avatar_emoji 列不存在', !_columnExists(dbB, 'experts', 'avatar_emoji'));
  final vB = ensureSchema(dbB);
  checkEq('路径 B：ensureSchema 从 8 升到 9', vB, 9);
  check('补列：avatar_emoji 已存在', _columnExists(dbB, 'experts', 'avatar_emoji'));
  check('补列：avatar_color 已存在', _columnExists(dbB, 'experts', 'avatar_color'));

  final stock = dbB.select("SELECT * FROM experts WHERE id = 'e_stock'").first;
  checkEq('存量行没丢（仍 1 行）',
      dbB.select('SELECT COUNT(*) AS c FROM experts').first['c'], 1);
  checkEq('存量行 name 不变', stock['name'], '存量老专家');
  checkEq('存量行 profession 不变', stock['profession'], '老职业');
  checkEq('存量行 package_id 不变', stock['package_id'], 'org.v8.stock');
  check('★ 存量行 avatar_emoji = NULL（UI 回退首字，零回归）',
      stock['avatar_emoji'] == null, '${stock['avatar_emoji']}');
  check('★ 存量行 avatar_color = NULL（同上）', stock['avatar_color'] == null,
      '${stock['avatar_color']}');

  checkEq('幂等重跑：user_version 仍为 9', ensureSchema(dbB), 9);
  dbB.execute('PRAGMA user_version = 8');
  checkEq('回退到 8 重跑：恢复 9（列已存在 → no-op，不重复 ALTER）',
      ensureSchema(dbB), 9);
  dbB.execute('PRAGMA user_version = 1');
  checkEq('回退到 1 重跑：恢复 9', ensureSchema(dbB), 9);
  checkEq('回退重跑后存量行仍在',
      dbB.select('SELECT COUNT(*) AS c FROM experts').first['c'], 1);

  // ── §3 仓储 roundtrip（写入 / 读回 / 覆盖 / 清空） ───────────────
  section('§3 专家仓储 roundtrip（emoji / color 逐字一致）');
  final reposB = sqliteRepositories(dbB, secrets: InMemorySecretStore());
  final now = DateTime.now().millisecondsSinceEpoch;
  final expert = Expert(
    id: 'e_emoji',
    name: '机器人顾问',
    profession: '自动化顾问',
    avatarEmoji: '🤖',
    avatarColor: '#6D28D9',
    systemPrompt: '你是机器人顾问',
    packageId: 'org.test.emoji-hero',
    packageVersion: '1.0.0',
    categoryId: '02-Engineering',
    source: ExpertSource.market,
    createdAt: now,
    updatedAt: now,
  );
  await reposB.experts.upsertExpert(expert);
  final got = await reposB.experts.getExpert('e_emoji');
  check('读回：专家存在', got != null);
  checkEq('★ 读回 avatarEmoji', got?.avatarEmoji, '🤖');
  checkEq('★ 读回 avatarColor', got?.avatarColor, '#6D28D9');
  check('读回 avatarPath 仍为 null', got?.avatarPath == null);
  checkEq('读回 name', got?.name, '机器人顾问');
  checkEq('读回 source', got?.source.name, 'market');

  // 覆盖：改为别的 emoji
  await reposB.experts.upsertExpert(got!.copyWith(
    avatarEmoji: '🧹',
    avatarColor: null,
    clearAvatarColor: true,
  ));
  final got2 = await reposB.experts.getExpert('e_emoji');
  checkEq('★ 覆盖后 emoji 更新', got2?.avatarEmoji, '🧹');
  check('★ 覆盖后 color 清空（不是空串）', got2?.avatarColor == null,
      '${got2?.avatarColor}');
  final raw = dbB
      .select("SELECT avatar_emoji, avatar_color FROM experts WHERE id = 'e_emoji'")
      .first;
  check('★ 底层 avatar_color 是 NULL 而非空串', raw['avatar_color'] == null,
      '${raw['avatar_color']}');
  checkEq('底层 avatar_emoji 逐字一致', raw['avatar_emoji'], '🧹');

  // ── §4 路径 C：端到端（索引 → 安装 → 落库 → 关库重开仍在） ────────
  section('§4 端到端：市场索引 emoji → 安装落库 → 重开仍在');
  final dbPathC = '${tmpDir.path}${sep}e2e.sqlite';
  final dbC = openAdvisorDatabase(dbPathC);
  ensureSchema(dbC);
  final reposC = sqliteRepositories(dbC, secrets: InMemorySecretStore());
  final market = MarketService(reposC, experts: ExpertService(reposC));
  await market.registerDefaultSource();
  await market.applyIndex(jsonIndex());

  final pkg = await market.getPackage('org.test.emoji-hero');
  check('索引里读得到 emoji', pkg?.emoji == '🤖', '${pkg?.emoji}');
  checkEq('索引里读得到 color', pkg?.color, '#6D28D9');

  final installed = await market.installPackage(
    manifest: PackageManifest(
      packageId: 'org.test.emoji-hero',
      slug: 'emoji-hero',
      version: const SemVer(1, 0, 0),
      appVersion: AppVersionRequirement.parse('>=0.1.0'),
      displayName: '机器人顾问',
      categoryId: '02-Engineering',
      entry: 'agents/main.md',
      sha256: 'a' * 64,
    ),
    verification: const PackageVerification([
      VerifyStep('1. HTTPS', true),
      VerifyStep('2. Manifest', true),
    ]),
    systemPrompt: '你是机器人顾问',
    installPath: '${tmpDir.path}${sep}packages${sep}emoji-hero-1.0.0',
  );
  checkEq('★ 安装后专家 avatarEmoji', installed.avatarEmoji, '🤖');
  final rowC = dbC
      .select('SELECT avatar_emoji, avatar_color FROM experts WHERE id = ?',
          [installed.id])
      .first;
  checkEq('★ 库里 avatar_emoji', rowC['avatar_emoji'], '🤖');
  checkEq('★ 库里 avatar_color', rowC['avatar_color'], '#6D28D9');

  // 关库重开（模拟重启 / 切页签后重新读库）。
  dbC.dispose();
  final dbC2 = openAdvisorDatabase(dbPathC);
  final version2 = ensureSchema(dbC2);
  final reposC2 = sqliteRepositories(dbC2, secrets: InMemorySecretStore());
  checkEq('重开：user_version 仍为 9', version2, 9);
  final reread = await reposC2.experts.getExpert(installed.id);
  checkEq('★ 重开后 emoji 仍在', reread?.avatarEmoji, '🤖');
  checkEq('★ 重开后 color 仍在', reread?.avatarColor, '#6D28D9');

  // 重开后"切回来"读市场列表：包数 / emoji 都在（不联网）。
  final market2 = MarketService(reposC2, experts: ExpertService(reposC2));
  final pkgs2 = await market2.listPackages();
  checkEq('★ 重开后包数', pkgs2.length, 1);
  checkEq('★ 重开后 emoji 仍在', pkgs2.first.emoji, '🤖');

  // ── 清理 ─────────────────────────────────────────────────────
  dbFresh.dispose();
  dbB.dispose();
  dbC2.dispose();
  tmpDir.deleteSync(recursive: true);

  stdout.writeln('\n' + '=' * 60);
  stdout.writeln('结果：通过 $_passed ／ 失败 $_failed');
  if (_failures.isEmpty) {
    stdout.writeln('全部通过 ✅');
  } else {
    stdout.writeln('失败项：');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
  }
  if (_failed > 0) throw StateError('verify_storage_v9 失败 $_failed 项');
}

int _userVersion(Database db) =>
    (db.select('PRAGMA user_version').first.values.first as num).toInt();

/// 带 emoji / color 的最小市场索引（与线上 `catalog/index.json` 同结构）。
String jsonIndex() => '''
{
  "schemaVersion": 1,
  "generatedAt": 1790785441428,
  "packages": [
    {
      "packageId": "org.test.emoji-hero",
      "slug": "emoji-hero",
      "displayName": "机器人顾问",
      "profession": "自动化顾问",
      "description": "带 emoji 的测试包",
      "categoryId": "02-Engineering",
      "tags": ["emoji"],
      "emoji": "🤖",
      "color": "#6D28D9",
      "latestVersion": "1.0.0",
      "versions": [
        {"version": "1.0.0", "releaseUrl": "https://example.test/e.expert",
         "sha256": "${'a' * 64}", "publishedAt": 1}
      ]
    }
  ]
}
''';
