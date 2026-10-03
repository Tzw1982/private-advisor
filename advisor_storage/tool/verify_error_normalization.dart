/// 存量 8 仓储「错误归一化」验证脚本（TD-1，纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_storage && dart run tool/verify_error_normalization.dart`
///
/// 目标：证明 [SqliteExpertRepository] / [SqliteConversationRepository] /
/// [SqliteMessageRepository] / [SqliteGenerationRepository] /
/// [SqliteProviderRepository] / [SqliteCredentialRepository] /
/// [SqliteSettingsRepository] / [SqliteJobRepository] 的公开方法**不再向调用方
/// 泄漏裸 `SqliteException`**，而是统一归一化为 [StorageError]
/// （`storage.<area>.<method>`），与市场 / 知识仓储同口径。
///
/// 触发方式（`关闭 / 删表 / 构造约束冲突`）：
/// - 7 个仓储：`DROP TABLE <其主表>` 后调用其读方法 → 底层"no such table"；
/// - Message 仓储：插入一条 `message_id` 不存在的引用行 → 外键立即冲突
///   （与 `tool/qa_verify.dart` 的 `[6.11]` 同触发路径）。
///
/// 每个仓储断言 4 条：① 抛的是 [StorageError]（而非裸 `SqliteException`）；
/// ② `code` 符合约定；③ `cause` 保留为底层 `SqliteException`；④ `message`
/// 不含 SQL 明文（不泄漏内部语句）。
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
// 迷你断言框架（与 tool/verify_storage.dart 同风格）
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

String? _code(Object? e) => e is AppError ? e.code : null;
String? _msg(Object? e) => e is AppError ? e.message : null;
Object? _cause(Object? e) => e is AppError ? e.cause : null;

/// 执行 [action] 并断言其归一化行为，符合 [expectedCode]。
Future<void> _expectStorageError(
  String label,
  String expectedCode,
  Future<void> Function() action,
) async {
  Object? err;
  try {
    await action();
  } catch (e) {
    err = e;
  }
  if (err == null) {
    check('$label 触发底层错误并抛出', false, '未抛出任何异常（触发路径失效？）');
    return;
  }
  check(
    '$label → StorageError（非裸 SqliteException）',
    err is StorageError && err is! SqliteException,
    'runtimeType=${err.runtimeType}',
  );
  check('$label → code = $expectedCode', _code(err) == expectedCode, 'code=${_code(err)}');
  check(
    '$label → cause 保留底层 SqliteException',
    _cause(err) is SqliteException,
    'cause=${_cause(err)?.runtimeType}',
  );
  final msg = _msg(err);
  check(
    '$label → message 无 SQL 明文',
    msg != null &&
        !msg.contains('no such table') &&
        !msg.contains('FOREIGN') &&
        !msg.contains('INSERT') &&
        !msg.contains('SELECT'),
    'message=$msg',
  );
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  // 纯 Dart 环境使用系统 winsqlite3.dll 驱动 SQLite（仅验证脚本做 override）。
  open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));

  stdout.writeln('私人顾问团 · 存量 8 仓储错误归一化验证（TD-1）');
  stdout.writeln('=' * 60);
  stdout.writeln('sqlite3 版本 = ${sqlite3.version.libVersion}');

  // 7 个仓储：用一张**未建 schema 的空库**触发底层 "no such table"
  // （比在共享库上 DROP TABLE 稳——后者会因跨表外键引用而连带报错）。
  final emptyDb = sqlite3.openInMemory();
  final emptyRepos = sqliteRepositories(emptyDb, secrets: InMemorySecretStore());

  // ① Expert：空库 → 表不存在。
  section('Expert（storage.expert.*）');
  await _expectStorageError(
    'listExperts（表缺失）',
    'storage.expert.list_experts',
    () => emptyRepos.experts.listExperts(),
  );

  // ② Conversation：空库 → 表不存在。
  section('Conversation（storage.conversation.*）');
  await _expectStorageError(
    'listConversations（表缺失）',
    'storage.conversation.list_conversations',
    () => emptyRepos.conversations.listConversations(),
  );

  // ④ Generation：空库 → 表不存在。
  section('Generation（storage.generation.*）');
  await _expectStorageError(
    'listRuns（表缺失）',
    'storage.generation.list_runs',
    () => emptyRepos.generations.listRuns('ghost_conv'),
  );

  // ⑤ Provider：空库 → 表不存在。
  section('Provider（storage.provider.*）');
  await _expectStorageError(
    'listProviders（表缺失）',
    'storage.provider.list_providers',
    () => emptyRepos.providers.listProviders(),
  );

  // ⑥ Credential：空库 → 表不存在。
  section('Credential（storage.credential.*）');
  await _expectStorageError(
    'list（表缺失）',
    'storage.credential.list',
    () => emptyRepos.credentials.list(),
  );

  // ⑦ Settings：空库 → 表不存在。
  section('Settings（storage.settings.*）');
  await _expectStorageError(
    'get（表缺失）',
    'storage.settings.get',
    () => emptyRepos.settings.get('k'),
  );

  // ⑧ Job：空库 → 表不存在。
  section('Job（storage.job.*）');
  await _expectStorageError(
    'list（表缺失）',
    'storage.job.list',
    () => emptyRepos.jobs.list(),
  );

  emptyDb.dispose();

  // ③ Message：外键冲突（message_id 不存在）——与 qa_verify [6.11] 同触发路径，
  // 需要 schema 就绪（messages / message_citations 存在 + 外键 ON）。
  section('Message（storage.message.*）');
  final db = sqlite3.openInMemory();
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  check('先决：schema 就绪（user_version = 9）', userVersion(db) == 9);
  check('先决：外键 = ON', db.select('PRAGMA foreign_keys;').first.values.first == 1);
  await _expectStorageError(
    'insertCitation(不存在的 message_id)',
    'storage.message.insert_citation',
    () => repos.messages.insertCitation(
      'nonexistent_msg',
      const Citation(chunkId: 'c', documentId: 'd', fileName: 'f', text: 'q', score: 1),
    ),
  );

  db.dispose();

  // ---- 成功路径零回归 smoke（全新库：upsert → get 逐字回读）----
  await _smokeSuccessPath();

  // ---- 收尾 ----
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

/// 成功路径零回归 smoke：证明归一化改造**不改变**成功路径行为。
Future<void> _smokeSuccessPath() async {
  section('成功路径零回归（smoke）');
  final db = sqlite3.openInMemory();
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());

  const e = Expert(
    id: 'ex_smoke',
    name: '烟测专家',
    systemPrompt: '你是烟测专家。',
    avatarEmoji: '🤖',
    avatarColor: '#123456',
    createdAt: 1000,
    updatedAt: 2000,
  );
  await repos.experts.upsertExpert(e);
  final got = await repos.experts.getExpert('ex_smoke');
  check('Expert upsert → get 逐字回读', got != null && got.name == e.name, 'got=${got?.name}');
  check('Expert emoji/color 落库回读（v9）', got?.avatarEmoji == '🤖' && got?.avatarColor == '#123456',
      'emoji=${got?.avatarEmoji} color=${got?.avatarColor}');

  await repos.settings.set('k', 'v');
  check('Settings set → get roundtrip', await repos.settings.get('k') == 'v');

  const j = JobRecord(id: 'job_smoke', type: 'import', createdAt: 1);
  await repos.jobs.upsert(j);
  check('Job upsert → get roundtrip', (await repos.jobs.get('job_smoke'))?.type == 'import');

  db.dispose();
}
