/// 第 7 轮核心逻辑验证 T01（纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_core && dart run tool/verify_round7.dart`
///
/// 覆盖（任务 #38 · T01 完成标准）：
/// 1. **AvatarPaletteIndex（确定性色板哈希）**：
///    ① `of()` 确定性（同 seed 调 1000 次恒同值）；② FNV-1a **测试向量写死 3 组**；
///    ③ 大小写敏感（`hash('A') != hash('a')`，`of` 层允许碰撞）；④ 边界（空串/中文/emoji/超长）；
///    ⑤ **分布检查**（真实 `packageId` ≥100 → 8 桶无空桶、单桶 ≤40%）。
/// 2. **KnowledgeTreeBuilder（知识库层级树）**：§1.1.2 **6 条边界**逐条用例
///    （跨根 / 根外 / 大小写 / 分隔符 / rename 降级 / 空目录不显示）+ 孤儿桶 + 搜索过滤 +
///    默认展开层级（库根 + 关联文件夹 + 一级子文件夹）。
///
/// ⚠️ 本脚本**不得 import `app/` 任何东西**（纯 core 逻辑）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（与 verify_round6 同款）
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

// ---------------------------------------------------------------------------
// 夹具（知识库树）
// ---------------------------------------------------------------------------

KnowledgeBaseFolder _folder(String id, String displayPath) =>
    KnowledgeBaseFolder(
      id: id,
      knowledgeBaseId: 'kb1',
      folderPath: folderKey(displayPath),
      displayPath: displayPath,
      createdAt: 1,
    );

KnowledgeDocument _doc(
  String id,
  String fileName,
  String filePath, {
  required String? folderId,
  DocumentStatus status = DocumentStatus.indexed,
}) =>
    KnowledgeDocument(
      id: id,
      knowledgeBaseId: 'kb1',
      fileName: fileName,
      filePath: filePath,
      fileHash: 'h_$id',
      fileSize: 100,
      status: status,
      folderId: folderId,
      createdAt: 1,
      updatedAt: 1,
    );

const KnowledgeBase _base = KnowledgeBase(
  id: 'kb1',
  name: '消防车规格库',
  createdAt: 1,
  updatedAt: 1,
);

// ---------------------------------------------------------------------------
// 色板：边界 + 向量 + 分布
// ---------------------------------------------------------------------------

void verifyPalette() {
  section('AvatarPaletteIndex · 确定性 / 向量');

  checkEq('size == 8', AvatarPaletteIndex.size, 8);

  // ① 确定性：同 seed 调 1000 次恒同值
  const seeds = [
    'org.private-advisor.design-ui-designer',
    'e_mupgta7u_09tu0vj003',
    '',
    '人类学家',
    '🔥 emoji 种子',
  ];
  for (final s in seeds) {
    final first = AvatarPaletteIndex.of(s);
    var allSame = true;
    for (var i = 0; i < 1000; i++) {
      if (AvatarPaletteIndex.of(s) != first) {
        allSame = false;
        break;
      }
    }
    check('确定性：of(${s.isEmpty ? '""' : s}) 1000 次恒同值', allSame, 'first=$first');
  }

  // ② FNV-1a 测试向量（写死；防止日后有人换哈希实现）
  //    向量独立由 Python 按 FNV-1a-32 口径算出，作为 ground truth 钉住。
  const v1 = 'org.private-advisor.design-ui-designer';
  const v2 = 'e_mupgta7u_09tu0vj003';
  const v3 = '';
  checkEq('向量① hash("$v1")', AvatarPaletteIndex.hash(v1), 4196479378);
  checkEq('向量① of  ("$v1")', AvatarPaletteIndex.of(v1), 2);
  checkEq('向量② hash("$v2")', AvatarPaletteIndex.hash(v2), 2308046983);
  checkEq('向量② of  ("$v2")', AvatarPaletteIndex.of(v2), 7);
  checkEq('向量③ hash("")', AvatarPaletteIndex.hash(v3), 2166136261);
  checkEq('向量③ of  ("")', AvatarPaletteIndex.of(v3), 5);

  // ③ 大小写敏感（哈希层；of 层 % 8 只看低 3 位，ASCII 大小写位不改变低 3 位 → 允许碰撞）
  check('大小写敏感 hash("A") != hash("a")',
      AvatarPaletteIndex.hash('A') != AvatarPaletteIndex.hash('a'));
  check('大小写敏感 hash("Design") != hash("design")',
      AvatarPaletteIndex.hash('Design') != AvatarPaletteIndex.hash('design'));
  check(
      'of 层合法（A/a 均落 0..7）',
      _inRange(AvatarPaletteIndex.of('A')) &&
          _inRange(AvatarPaletteIndex.of('a')));

  section('AvatarPaletteIndex · 边界');

  check('空串不抛异常且返回确定值（=5）', () {
    try {
      return AvatarPaletteIndex.of('') == 5;
    } catch (_) {
      return false;
    }
  }());
  checkEq('纯中文 of("人类学家")', AvatarPaletteIndex.of('人类学家'), 3);
  checkEq('emoji  of("🔥")', AvatarPaletteIndex.of('🔥'), 3);
  check('超长串可算且在范围内', _inRange(AvatarPaletteIndex.of('x' * 10000)));
  check(
      '非 ASCII 混合可算且在范围内', _inRange(AvatarPaletteIndex.of('投标-决策群_2024·中文🔥')));

  section('AvatarPaletteIndex · 分布（真实 packageId）');
  final seedsFromCatalog = _loadPackageIds();
  stdout.writeln('  样本数 = ${seedsFromCatalog.length}');
  check('样本 ≥ 100', seedsFromCatalog.length >= 100,
      'n=${seedsFromCatalog.length}');
  final buckets = List<int>.filled(8, 0);
  for (final s in seedsFromCatalog) {
    buckets[AvatarPaletteIndex.of(s)]++;
  }
  stdout.writeln('  桶分布 = $buckets');
  final empty = <int>[];
  for (var i = 0; i < 8; i++) {
    if (buckets[i] == 0) empty.add(i);
  }
  check('无空桶', empty.isEmpty, 'empty=$empty');
  final maxShare =
      buckets.reduce((a, b) => a > b ? a : b) / seedsFromCatalog.length;
  check('单桶占比 ≤ 40%', maxShare <= 0.40,
      'max=${(maxShare * 100).toStringAsFixed(1)}%');
}

bool _inRange(int i) => i >= 0 && i < AvatarPaletteIndex.size;

/// 读取真实市场索引的 packageId；读不到则退回固定样本（≥128）。
List<String> _loadPackageIds() {
  final candidates = [
    '../market/catalog/index.json',
    'E:/APP/私人顾问团/market/catalog/index.json',
    '../../market/catalog/index.json',
  ];
  for (final path in candidates) {
    final f = File(path);
    if (!f.existsSync()) continue;
    try {
      final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final pkgs = data['packages'] as List;
      final ids = <String>[];
      for (final p in pkgs) {
        if (p is Map && p['packageId'] is String)
          ids.add(p['packageId'] as String);
      }
      if (ids.length >= 100) return ids;
    } catch (_) {
      // 继续尝试下一个候选
    }
  }
  // 固定样本（确定性；≥128 条）
  return List<String>.generate(
    128,
    (i) => 'org.private-advisor.sample-agent-$i',
  );
}

// ---------------------------------------------------------------------------
// 知识树
// ---------------------------------------------------------------------------

void verifyTree() {
  final f1 = _folder('f1', r'D:\Docs\规格书');
  final f2 = _folder('f2', r'E:\手册');
  final f3 = _folder('f3', r'C:\Empty'); // 空目录 → 不应出现

  final docs = <KnowledgeDocument>[
    _doc('d1', 'a.docx', r'D:\Docs\规格书\2024\a.docx', folderId: 'f1'),
    _doc('d2', 'b.pdf', r'E:\手册\b.pdf', folderId: 'f2'),
    _doc('d3', 'c.md', r'F:\Elsewhere\c.md', folderId: 'f1'), // 根外
    _doc('d4', 'Upper.DOCX', r'd:\DOCS\规格书\2024\Upper.DOCX',
        folderId: 'f1'), // 大小写
    _doc('d5', 'slash.docx', r'D:/Docs/规格书/2024/slash.docx',
        folderId: 'f1'), // 分隔符
    _doc('d6', 'gone.txt', r'Z:\OldName\gone.txt', folderId: 'f2'), // rename 降级
    _doc('d7', 'deep.md', r'D:\Docs\规格书\2024\子级\deep.md',
        folderId: 'f1'), // 二级子文件夹
    _doc('d8', 'orphan.md', r'G:\Loose\orphan.md', folderId: null), // 孤儿
    _doc('d9', 'top.md', r'D:\Docs\规格书\top.md', folderId: 'f1'), // 直接位于根下
  ];

  final chunkCounts = {'d1': 12, 'd2': 3};

  final root = KnowledgeTreeBuilder.build(
    base: _base,
    folders: [f1, f2, f3],
    docs: docs,
    chunkCounts: chunkCounts,
  );

  section('知识树 · 结构 / 空目录');
  checkEq('根为 base', root.kind, KbNodeKind.base);
  checkEq('根 label = 库名', root.label, '消防车规格库');

  final folderNodes =
      root.children.where((c) => c.kind == KbNodeKind.folder).toList();
  checkEq('关联文件夹节点数 = 2（f3 空目录不显示）', folderNodes.length, 2);

  final n1 = folderNodes.firstWhere((c) => c.id == 'f1');
  final n2 = folderNodes.firstWhere((c) => c.id == 'f2');
  checkEq('f1 副标题 = 文档计数 6 篇', n1.subtitle, '6 篇');
  checkEq('f1 label = displayPath 原样大小写', n1.label, r'D:\Docs\规格书');

  final orphan =
      root.children.where((c) => c.kind == KbNodeKind.orphanBucket).toList();
  checkEq(
      '未关联桶存在且 1 篇', orphan.length == 1 ? orphan.first.subtitle : null, '1 篇');
  check('未关联桶含 orphan.md', orphan.first.children.any((c) => c.id == 'd8'));

  section('知识树 · 边界 §1.1.2');

  // ① 跨根：相对路径只对 folderId 指向的根计算
  checkEq('① 跨根 relativePath(d2, f1) == null',
      KnowledgeTreeBuilder.relativePath(docs[1], f1), null);
  checkEq('① 跨根 relativePath(d2, f2) == b.pdf',
      KnowledgeTreeBuilder.relativePath(docs[1], f2), 'b.pdf');
  check('① f1 子树不含 d2（b.pdf 错挂检测）', !n1.allIds().contains('d2'));
  check('① f2 子树不含 d1（a.docx 错挂检测）', !n2.allIds().contains('d1'));

  // ② 根外 → 「其他」桶
  final other1 = n1.children.firstWhere(
    (c) => c.kind == KbNodeKind.subfolder && c.label == '其他',
  );
  check('② 根外 c.md 落 f1「其他」桶', other1.children.any((c) => c.id == 'd3'));

  // ③ 大小写敏感前缀 + 原样大小写剥除
  checkEq('③ relativePath(d4, f1) = 2024/Upper.DOCX',
      KnowledgeTreeBuilder.relativePath(docs[3], f1), '2024/Upper.DOCX');
  check(
      '③ Upper.DOCX 归入 2024 子文件夹',
      n1
          .firstWhereOrNull((n) => n.id == 'dir:f1/2024')!
          .allIds()
          .contains('d4'));

  // ④ 分隔符 `/` 与 `\` 等价
  checkEq('④ relativePath(d5, f1) = 2024/slash.docx',
      KnowledgeTreeBuilder.relativePath(docs[4], f1), '2024/slash.docx');
  final sub2024 = n1.firstWhereOrNull((n) => n.id == 'dir:f1/2024')!;
  check('④ d1 与 d5 同归 2024/（分隔符归一）',
      sub2024.allIds().contains('d1') && sub2024.allIds().contains('d5'));

  // ⑤ rename 降级 → 「其他」桶，无崩溃
  final other2 = n2.children.firstWhere(
    (c) => c.kind == KbNodeKind.subfolder && c.label == '其他',
  );
  check('⑤ 根 rename 后 gone.txt 落 f2「其他」桶',
      other2.children.any((c) => c.id == 'd6'));
  checkEq('⑤ rename 降级 relativePath(d6, f2) == null',
      KnowledgeTreeBuilder.relativePath(docs[5], f2), null);

  // ⑥ 空目录不显示（f3 零文档）
  check('⑥ 空目录 f3 不出现在树中', !root.allIds().contains('f3'));
  check('⑥ 无文档的子目录不出现（构造即无）',
      n1.firstWhereOrNull((n) => n.label == '不存在目录') == null);

  // 根下文档
  check('根下文档 d9 直挂 f1 下', n1.children.any((c) => c.id == 'd9'));

  // 文档叶状态·分块数
  final leaf1 = n1.firstWhereOrNull((n) => n.id == 'd1')!;
  checkEq('文档叶副标题 = 状态·分块数', leaf1.subtitle, '已索引 · 12 块');
  final leaf3 = n1.firstWhereOrNull((n) => n.id == 'd3')!;
  checkEq('无分块数时只显状态', leaf3.subtitle, '已索引');

  section('知识树 · 默认展开层级');
  final auto = KnowledgeTreeBuilder.defaultExpandedIds(root);
  check('默认展开含库根', auto.contains('kb1'));
  check('默认展开含关联文件夹 f1/f2', auto.contains('f1') && auto.contains('f2'));
  check('默认展开含一级子文件夹 2024', auto.contains('dir:f1/2024'));
  check('默认展开**不含**二级子文件夹 子级', !auto.contains('dir:f1/2024/子级'));

  section('知识树 · 搜索过滤');
  final r1 = KnowledgeTreeBuilder.filter(root, 'a.docx');
  check('搜索 a.docx → 命中叶保留', r1.tree.allIds().contains('d1'));
  check(
      '搜索 a.docx → 祖先自动展开（f1/2024/根）',
      r1.autoExpanded.contains('f1') &&
          r1.autoExpanded.contains('dir:f1/2024') &&
          r1.autoExpanded.contains('kb1'));
  check('搜索 a.docx → 无关分支被剪枝（不含 d2）', !r1.tree.allIds().contains('d2'));

  final r2 = KnowledgeTreeBuilder.filter(root, 'deep');
  check('搜索 deep → 二级子目录自动展开', r2.autoExpanded.contains('dir:f1/2024/子级'));

  final r3 = KnowledgeTreeBuilder.filter(root, '规格书');
  check('搜索命中文件夹名 → 整子树保留（含 d1/d5）',
      r3.tree.allIds().contains('d1') && r3.tree.allIds().contains('d5'));

  final r4 = KnowledgeTreeBuilder.filter(root, 'zzz-无匹配-xyz');
  check('无命中 → 空树且无自动展开', r4.tree.children.isEmpty && r4.autoExpanded.isEmpty);

  final r5 = KnowledgeTreeBuilder.filter(root, '   ');
  check(
      '空查询 → 返回整树 + 默认展开',
      r5.tree.allIds().contains('kb1') &&
          r5.tree.allIds().contains('d1') &&
          r5.autoExpanded.contains('f1'));
}

// ---------------------------------------------------------------------------

void main() {
  stdout.writeln('第 7 轮 T01 核心逻辑验证（AvatarPaletteIndex + KnowledgeTreeBuilder）');
  verifyPalette();
  verifyTree();

  stdout.writeln('\n${'=' * 60}');
  stdout.writeln('结果：通过 $_passed ／ 失败 $_failed');
  if (_failed > 0) {
    stdout.writeln('\n失败明细：');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
    exit(1);
  }
  stdout.writeln('全部通过 ✅');
}
