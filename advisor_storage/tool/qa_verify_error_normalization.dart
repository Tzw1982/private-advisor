/// QA 独立验收脚本（TD-1 存量 8 仓储错误归一化）—— **证伪导向**。
///
/// 运行：`cd advisor_storage && dart run tool/qa_verify_error_normalization.dart`
///
/// 与工程师的 `verify_error_normalization.dart` **相互独立**：本脚本只读取 / 调用
/// 生产代码，不引用其断言措辞，重点攻击其**未覆盖**的对抗面（team-lead 指定 6 点）：
///   §1 覆盖完整性：逐仓储核对「公开方法数 vs 被 `_guard` 包裹数」（源码结构核对），
///      明确列出任何漏网方法。
///   §2 只归一化一次：用「抛异常的假 Database」证明——AppError / StorageError 原样透传
///      （identity 不变、code 不被改写），非 AppError 才被包。
///   §3 不吞编程错误：用**公开 API**（listMessages(limit:-1) → RangeError）实证 `_guard`
///      会包装非 SQL 异常 → 给判定（可接受 / 应修）。
///   §4 成功路径零行为变更：Message insert / update 逐字（11 列）复核 + upsert + 不存在 id。
///   §5 cause 链 + 码稳定性 / 唯一性（≥5 方法，重复触发两次）。
///
/// 纪律：不修改任何生产代码，不改工程师的 `verify_error_normalization.dart` /
/// `verify_storage.dart`；只维护本 `qa_verify_*.dart` 与 `tool/qa_verify.dart`。
///
/// SQLite 原生库：本机 Windows 用系统 `winsqlite3.dll`（仅验证脚本 override）。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';
import 'package:advisor_storage/advisor_storage.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（本脚本私有）
// ---------------------------------------------------------------------------

class Case {
  Case(this.id, this.name, this.expected, this.actual, this.pass, [this.note]);
  final String id, name, expected, actual;
  final bool pass;
  final String? note;
}

final List<Case> _res = [];
int _pass = 0;
int _fail = 0;

void t(String id, String name, Object? expected, Object? actual, {String? note}) {
  final ok = expected == actual;
  ok ? _pass++ : _fail++;
  _res.add(Case(id, name, '$expected', '$actual', ok, note));
  stdout.writeln('  ${ok ? '✓' : '✗'} [$id] $name  (期望=$expected 实际=$actual'
      '${note == null ? '' : '  · $note'})');
}

void section(String name) => stdout.writeln('\n── $name ──────────────────────────');

// ---------------------------------------------------------------------------
// 「抛异常的假 Database」：所有成员经 noSuchMethod 抛出**预置异常**。
// 用于精确验证 `_guard` 的分支语义（AppError 透传 vs 非 AppError 包装），
// 无需真的制造某种底层错误。
// ---------------------------------------------------------------------------

class _ThrowingDb implements Database {
  _ThrowingDb(this.error);
  final Object error;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw error;
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));

  stdout.writeln('QA 独立验收 · TD-1 存量 8 仓储错误归一化');
  stdout.writeln('=' * 62);

  _t1Coverage();
  await _t2NormalizeOnce();
  await _t3SwallowProgrammingError();
  await _t4SuccessPathUnchanged();
  await _t5CauseAndCodeStability();

  _print();
  exitCode = _fail == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// §1 覆盖完整性（源码结构核对）
// ---------------------------------------------------------------------------

void _t1Coverage() {
  section('§1 覆盖完整性：公开方法数 vs 被 _guard 包裹数');

  final src = File('lib/src/database/sqlite_repositories.dart').readAsStringSync();
  final classRe = RegExp(r'class\s+(Sqlite\w+Repository)\s+implements\s+\w+');
  final matches = classRe.allMatches(src).toList();
  t('1.0', '源码含 8 个 Sqlite*Repository 类', 8, matches.length);

  var totalMethods = 0;
  var guardedMethods = 0;
  final unguarded = <String>[];

  for (var i = 0; i < matches.length; i++) {
    final cls = matches[i].group(1)!;
    final start = matches[i].end;
    final end = i + 1 < matches.length ? matches[i + 1].start : src.length;
    final body = src.substring(start, end);
    final parts = body.split('@override'); // parts[0] = 字段/构造
    var n = 0, g = 0;
    for (var j = 1; j < parts.length; j++) {
      final chunk = parts[j];
      final name = RegExp(r'>\s*(\w+)\s*\(').firstMatch(chunk)?.group(1) ?? '<未知>';
      n++;
      if (chunk.contains('_guard(')) {
        g++;
      } else {
        unguarded.add('$cls.$name');
      }
    }
    totalMethods += n;
    guardedMethods += g;
    // 每仓储：期望 = 全部方法都被包裹
    t('1.${i + 1}', '$cls：公开方法 $n 个，被 _guard 包裹 $g 个', '$n/$n', '$g/$n');
  }

  t('1.total', '公开方法总数 = 被 _guard 包裹总数', '$totalMethods/$totalMethods',
      '$guardedMethods/$totalMethods');
  t('1.unguarded', '漏网方法清单为空', 0, unguarded.length,
      note: unguarded.isEmpty ? '（无漏网）' : '漏网=$unguarded');
}

// ---------------------------------------------------------------------------
// §2 只归一化一次（AppError 透传，非 AppError 包装）
// ---------------------------------------------------------------------------

Future<void> _t2NormalizeOnce() async {
  section('§2 只归一化一次：AppError 原样透传');

  // 2a：body 抛出的已是 StorageError → 必须**同一个对象**透传（不被再包一层）。
  final seededStorage = const StorageError('storage.already.normalized', '已归一化');
  Object? caught;
  try {
    await SqliteExpertRepository(_ThrowingDb(seededStorage)).getExpert('x');
  } catch (e) {
    caught = e;
  }
  t('2a.1', 'StorageError 透传后仍为 StorageError', true, caught is StorageError);
  t('2a.2', 'identity 不变（未再包一层）', true, identical(caught, seededStorage));
  t('2a.3', 'code 未被外层方法改写（未变成 storage.expert.get_expert）',
      'storage.already.normalized',
      caught is StorageError ? caught.code : '(非 StorageError)');

  // 2b：body 抛出的已是**其它 AppError**（ValidationError）→ 本实现 `is AppError` 亦透传。
  //   注：市场 / 知识仓储的既有 `_guard` 只 `is StorageError` 透传；TD-1 放宽到 AppError，
  //   与源码注释「语义完全一致」**不完全相符**（更宽），此处按实测记录。
  final seededValidation = const ValidationError('validation.x', '参数错');
  Object? caught2;
  try {
    await SqliteExpertRepository(_ThrowingDb(seededValidation)).getExpert('x');
  } catch (e) {
    caught2 = e;
  }
  t('2b.1', 'ValidationError（AppError）亦原样透传（未被包成 StorageError）', true,
      identical(caught2, seededValidation),
      note: 'runtimeType=${caught2.runtimeType}');

  // 2c：body 抛出的**非 AppError**（SqliteException）→ 必须被包成该方法的 StorageError，
  //   且原始异常保留在 cause（identity）。
  final sqliteCause = SqliteException(1, 'boom');
  Object? caught3;
  try {
    await SqliteExpertRepository(_ThrowingDb(sqliteCause)).getExpert('x');
  } catch (e) {
    caught3 = e;
  }
  t('2c.1', '非 AppError → 包成 StorageError', true, caught3 is StorageError);
  t('2c.2', 'code = storage.expert.get_expert', 'storage.expert.get_expert',
      caught3 is StorageError ? caught3.code : '(非 StorageError)');
  t('2c.3', 'cause 保留原始异常（identity）', true,
      caught3 is StorageError && identical(caught3.cause, sqliteCause));
}

// ---------------------------------------------------------------------------
// §3 不吞编程错误（公开 API 实证）
// ---------------------------------------------------------------------------

Future<void> _t3SwallowProgrammingError() async {
  section('§3 不吞编程错误：公开 API 触发非 SQL 异常');

  final db = sqlite3.openInMemory();
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());

  // listMessages(limit:-1) 走 rows.sublist(length - (-1)) → RangeError（参数/编程错误），
  // 而非 SqliteException。用**纯公开 API** 观察 _guard 是否把它也归一化。
  const convId = 'conv_qa';
  await repos.conversations.upsertConversation(Conversation(
      id: convId, type: ConversationType.single, title: 't',
      createdAt: 1, updatedAt: 1));
  await repos.messages.insertMessage(Message(
      id: 'm1', conversationId: convId, senderType: MessageSenderType.user,
      content: 'hi', createdAt: 1, updatedAt: 1));

  Object? err;
  try {
    await repos.messages.listMessages(convId, limit: -1);
  } catch (e) {
    err = e;
  }
  t('3a.1', 'limit=-1 触发 RangeError 且被 _guard 归一化为 StorageError', true,
      err is StorageError && err is! SqliteException,
      note: 'runtimeType=${err.runtimeType}');
  t('3a.2', 'code = storage.message.list_messages', 'storage.message.list_messages',
      err is StorageError ? err.code : '(非 StorageError)');
  t('3a.3', 'cause 是 RangeError（非 SqliteException）——证明"非 SQL 异常也被包"',
      true,
      err is StorageError && err.cause is RangeError,
      note: 'cause=${(err is StorageError) ? err.cause.runtimeType : '?'}');

  db.dispose();
}

// ---------------------------------------------------------------------------
// §4 成功路径零行为变更（Message insert / update）
// ---------------------------------------------------------------------------

Future<void> _t4SuccessPathUnchanged() async {
  section('§4 成功路径零行为变更（Message insert / update 逐字）');

  final db = sqlite3.openInMemory();
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  await repos.conversations.upsertConversation(Conversation(
      id: 'c', type: ConversationType.single, title: 't', createdAt: 1, updatedAt: 1));

  Message mk(String id, {String content = '内容', MessageStatus status = MessageStatus.completed}) =>
      Message(
        id: id, conversationId: 'c', senderType: MessageSenderType.expert,
        senderId: 'e1', parentMessageId: 'p1', content: content, status: status,
        promptTokens: 11, completionTokens: 22, createdAt: 1000, updatedAt: 2000,
      );

  // 4a：insert 后 11 列逐字回读（Message 未重写 ==，故逐字段比对）。
  await repos.messages.insertMessage(mk('m_insert'));
  final got = await repos.messages.getMessage('m_insert');
  t('4a.1', 'insert → get 逐字回读（11 字段全等）', true, _msgEq(got, mk('m_insert')),
      note: got == null ? '读到 null' : '逐字段相等');

  // 4b：update 同 id（改 content/status/tokens/updatedAt）→ 被更新。
  await repos.messages.updateMessage(mk('m_insert',
      content: '内容已改', status: MessageStatus.failed));
  final after = await repos.messages.getMessage('m_insert');
  t('4b.1', 'update 后 content 已改', '内容已改', after?.content);
  t('4b.2', 'update 后 status 已改', MessageStatus.failed, after?.status);
  t('4b.3', 'upsert 不重复插入（仍 1 行）', 1,
      _count(db, 'SELECT COUNT(*) FROM messages WHERE id=?', ['m_insert']));

  // 4c：insert 路径 vs update 路径 —— 相同字段写入**逐列一致**（仅 id 不同）。
  await repos.messages.insertMessage(mk('m_via_insert'));
  await repos.messages.updateMessage(mk('m_via_update'));
  final a = _row(db, 'm_via_insert')..remove('id');
  final b = _row(db, 'm_via_update')..remove('id');
  t('4c.1', 'insert 与 update 写入的库内状态逐列一致（除 id）', true, _mapEq(a, b),
      note: _mapEq(a, b) ? '10 列全等' : 'insert=$a update=$b');

  // 4d：update 一个**不存在**的 id → upsert 语义为"插入"（与文档注释一致）。
  await repos.messages.updateMessage(mk('m_ghost', content: '幽灵'));
  final ghost = await repos.messages.getMessage('m_ghost');
  t('4d.1', 'update 不存在 id → 按 upsert 插入（读到内容）', '幽灵', ghost?.content);

  // 4e：insert 一个**已存在**的 id → upsert 语义为"更新"。
  await repos.messages.insertMessage(mk('m_insert', content: '再次插入覆盖'));
  t('4e.1', 'insert 已存在 id → upsert 覆盖（content 更新）', '再次插入覆盖',
      (await repos.messages.getMessage('m_insert'))?.content);

  db.dispose();
}

// ---------------------------------------------------------------------------
// §5 cause 链 + 码稳定性 / 唯一性
// ---------------------------------------------------------------------------

Future<void> _t5CauseAndCodeStability() async {
  section('§5 cause 链 + 码稳定性 / 唯一性（≥5 方法）');

  final samples = <String, Future<void> Function(Database)>{
    'expert.list_experts': (db) => SqliteExpertRepository(db).listExperts(),
    'expert.get_expert': (db) => SqliteExpertRepository(db).getExpert('x'),
    'conversation.list_conversations': (db) =>
        SqliteConversationRepository(db).listConversations(),
    'message.get_message': (db) => SqliteMessageRepository(db).getMessage('x'),
    'generation.get_run': (db) => SqliteGenerationRepository(db).getRun('x'),
    'generation.list_runs': (db) => SqliteGenerationRepository(db).listRuns('x'),
    'provider.list_providers': (db) => SqliteProviderRepository(db).listProviders(),
    'credential.list': (db) => SqliteCredentialRepository(db).list(),
    'settings.get': (db) => SqliteSettingsRepository(db).get('k'),
    'job.list': (db) => SqliteJobRepository(db).list(),
  };

  final codes = <String>[];
  for (final e in samples.entries) {
    // 触发两次：验证稳定性 + cause identity
    final cause1 = SqliteException(1, 'boom-1');
    final cause2 = SqliteException(2, 'boom-2');
    Object? c1, c2;
    try {
      await e.value(_ThrowingDb(cause1));
    } catch (err) {
      c1 = err;
    }
    try {
      await e.value(_ThrowingDb(cause2));
    } catch (err) {
      c2 = err;
    }
    final code1 = c1 is StorageError ? c1.code : null;
    final code2 = c2 is StorageError ? c2.code : null;
    codes.add(code1 ?? '(null)');
    t('5.${e.key}', '${e.key}：code = storage.${e.key} 且稳定 + cause identity', true,
        code1 != null &&
            code1 == 'storage.${e.key}' &&
            code1 == code2 &&
            RegExp(r'^storage\.[a-z_]+\.[a-z_]+$').hasMatch(code1) &&
            c1 is StorageError &&
            identical(c1.cause, cause1) &&
            c2 is StorageError &&
            identical(c2.cause, cause2),
        note: 'code=$code1${code1 == code2 ? '（两次一致）' : ' ≠ $code2'}');
  }

  t('5.uniq', '抽样 ${codes.length} 个方法的 code 互不相同', codes.length,
      codes.toSet().length, note: 'codes=$codes');
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

int _count(Database db, String sql, [List<Object?> params = const []]) =>
    (db.select(sql, params).first.values.first as int?) ?? 0;

/// 逐字段比对（[Message] 未重写 `==`，不能用对象相等）。
bool _msgEq(Message? a, Message b) =>
    a != null &&
    a.id == b.id &&
    a.conversationId == b.conversationId &&
    a.senderType == b.senderType &&
    a.senderId == b.senderId &&
    a.parentMessageId == b.parentMessageId &&
    a.content == b.content &&
    a.status == b.status &&
    a.promptTokens == b.promptTokens &&
    a.completionTokens == b.completionTokens &&
    a.createdAt == b.createdAt &&
    a.updatedAt == b.updatedAt;

Map<String, Object?> _row(Database db, String id) {
  final rs = db.select('SELECT * FROM messages WHERE id=?', [id]);
  final r = rs.first;
  return {for (final c in rs.columnNames) c: r[c]};
}

bool _mapEq(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final k in a.keys) {
    if (!b.containsKey(k) || '${a[k]}' != '${b[k]}') return false;
  }
  return true;
}

void _print() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('# QA · TD-1 用例表');
  stdout.writeln('| ID | 用例 | 期望 | 实际 | 结论 |');
  stdout.writeln('|----|------|------|------|------|');
  for (final r in _res) {
    final e = r.expected.replaceAll('|', r'\|');
    final a = r.actual.replaceAll('|', r'\|');
    stdout.writeln('| ${r.id} | ${r.name} | $e | $a | ${r.pass ? 'PASS' : 'FAIL'} |');
  }
  stdout.writeln('\n合计：通过 $_pass ／ 失败 $_fail');
  if (_fail > 0) {
    stdout.writeln('\n失败明细：');
    for (final r in _res.where((r) => !r.pass)) {
      stdout.writeln('  - [${r.id}] ${r.name}：期望=${r.expected} 实际=${r.actual}'
          '${r.note == null ? '' : '  (${r.note})'}');
    }
  }
}
