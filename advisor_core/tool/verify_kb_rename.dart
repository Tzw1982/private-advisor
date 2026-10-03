/// 知识库改名验证（用户走查反馈 #15-A，纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_core && dart run tool/verify_kb_rename.dart`
///
/// 覆盖：
/// 1. **改名成功且持久化可读回**：`renameBase` 返回改名后档案；
///    `getBase` / `listBases` 均读到新名；`id` 等其余字段不变；
///    `updatedAt` 被刷新（不小于原值）。
/// 2. **名称 trim**：输入带首尾空白时按 trim 后写入。
/// 3. **空名抛 `kb.name_empty`**：空串与纯空白两种情况。
/// 4. **不存在 id 抛 `kb.not_found`**。
library;

import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（与 advisor_core/tool 下既有 verify_*.dart 同款）
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
// 测试环境（内存仓储 + 真实 KnowledgeService）
// ---------------------------------------------------------------------------

class _Env {
  _Env() {
    final repos = inMemoryRepositories();
    this.repos = repos;
    knowledge = KnowledgeService(
      repos,
      parsers: const [PlainTextParser()],
      chunker: SimpleChunker(targetTokens: 64),
      vectorStore: InMemoryVectorStore(repos.knowledge),
      embeddingModel: HashEmbeddingModel(dimension: 64),
      retriever: InMemoryRetriever(repos.knowledge),
    );
  }

  late final Repositories repos;
  late final KnowledgeService knowledge;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 知识库改名验证（advisor_core / KnowledgeService.renameBase）');
  stdout.writeln('=' * 60);

  await _verifyRenameSuccess();

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
// 1. 改名成功 / trim / 持久化
// ---------------------------------------------------------------------------

Future<void> _verifyRenameSuccess() async {
  section('renameBase（成功 / trim / 持久化可读回 / 错误码）');

  final env = _Env();
  final base = await env.knowledge.createBase(name: '原始知识库');
  final oldUpdatedAt = base.updatedAt;
  checkEq('前置：createBase 落名', base.name, '原始知识库');

  // —— 改名成功 ——
  final renamed = await env.knowledge.renameBase(base.id, '工程车规格库');
  checkEq('返回值已是新名', renamed.name, '工程车规格库');
  checkEq('id 不变', renamed.id, base.id);
  checkEq('type 不变（默认 local_folder）', renamed.type, 'local_folder');
  checkEq('createdAt 不变', renamed.createdAt, base.createdAt);
  check('updatedAt 已刷新（不小于原值）', renamed.updatedAt >= oldUpdatedAt,
      'old=$oldUpdatedAt new=${renamed.updatedAt}');

  // —— 持久化可读回：getBase / listBases 双通道 ——
  final readBack = await env.knowledge.getBase(base.id);
  checkEq('getBase 读回新名（持久化）', readBack?.name, '工程车规格库');
  final listed = await env.knowledge.listBases();
  checkEq('listBases 读回新名（持久化）',
      listed.where((b) => b.id == base.id).first.name, '工程车规格库');
  checkEq('listBases 条数不变（未误建新库）', listed.length, 1);

  // —— trim：首尾空白被去掉 ——
  final trimmed =
      await env.knowledge.renameBase(base.id, '  带空白的名字  ');
  checkEq('首尾空白被 trim', trimmed.name, '带空白的名字');
  checkEq('仓储内同样是 trim 后的值',
      (await env.knowledge.getBase(base.id))?.name, '带空白的名字');

  // —— 空名抛 kb.name_empty ——
  await checkThrowsCode(
      '空串抛 kb.name_empty', () => env.knowledge.renameBase(base.id, ''), 'kb.name_empty');
  await checkThrowsCode('纯空白串抛 kb.name_empty',
      () => env.knowledge.renameBase(base.id, '   \t  '), 'kb.name_empty');
  checkEq('空名失败后原名保持（无副作用）',
      (await env.knowledge.getBase(base.id))?.name, '带空白的名字');

  // —— 不存在 id 抛 kb.not_found ——
  await checkThrowsCode('不存在的 id 抛 kb.not_found',
      () => env.knowledge.renameBase('kb_no_such_id', '随便'), 'kb.not_found');
  checkEq('失败不影响既有数据', (await env.knowledge.listBases()).length, 1);
}
