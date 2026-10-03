/// 覆盖率阈值**实验标定**（纯 Dart）——用真实中文文档，不拍脑袋。
///
/// 运行：`cd advisor_storage && dart run tool/calibrate_threshold.dart`
///
/// 目的（第 2 轮裁定 #1）：`similarity_threshold` 语义已改为"查询 bigram 的最低命中
/// 比例（coverage）"。本脚本在真实语料 `market/packages-src/*/agents/main.md` 上，
/// 枚举不同**查询长度**与不同**阈值系数**，输出命中数量矩阵与最佳覆盖率，供产品定夺。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';
import 'package:advisor_storage/advisor_storage.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

Future<void> main() async {
  open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));

  final src = _locatePackagesSrc();
  if (src == null) {
    stderr.writeln('未找到 market/packages-src');
    exitCode = 1;
    return;
  }

  stdout.writeln('私人顾问团 · 覆盖率阈值标定实验（真实中文文档）');
  stdout.writeln('=' * 70);

  final tmp = Directory.systemTemp.createTempSync('pa_calibrate_');
  final db = openAdvisorDatabase('${tmp.path}${Platform.pathSeparator}cal.sqlite');
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final retriever = Fts5Retriever(db);
  final knowledge = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 200),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    retriever: retriever,
  );

  final kb = await knowledge.createBase(name: '标定语料');
  final sep = Platform.pathSeparator;
  for (final pkg in [
    'bid-tender-expert',
    'bid-proposal-expert',
    'bid-pricing-expert',
    'contract-review-expert',
    'tech-spec-expert',
  ]) {
    final f = File('${src.path}$sep$pkg${sep}agents${sep}main.md');
    await knowledge.importDocument(
      knowledgeBaseId: kb.id,
      filePath: f.path,
      fileName: '$pkg/main.md',
      fileBytes: f.readAsBytesSync(),
    );
  }
  final ftsRows = ftsRowCount(db);
  stdout.writeln('语料：5 个专家 main.md，索引分块 = $ftsRows');
  stdout.writeln();

  // 查询样本：按"查询 bigram 数"分组（bigram 数 ≈ 字数 - 1，单字为 1）。
  final queries = <String>[
    // 单字（bigram 数 = 0）
    '标',
    // 2 字（bigram 数 = 1）
    '商务', '成本', '质保', '偏离',
    // 3 字（bigram 数 = 2）
    '长篇文档', '价格分', '参数比对', '废标条款',
    // 4 字（bigram 数 = 3）
    '评标办法', '风险条款', '时间节点',
    // 5-6 字（bigram 数 = 4~5）
    '不平衡成本', '合同风险条款', '技术参数负偏离',
    // 多概念长句（bigram 数 >= 6）
    '商务保证金递交开标时间节点', '工程车长臂喷射臂架系统额定流量',
  ];

  const thresholds = [0.3, 0.4, 0.5, 0.6, 0.75, 1.0];

  // 表头
  final header = StringBuffer('| 查询 | 字数 | bigram数 | ' );
  for (final t in thresholds) {
    header.write('≥${t.toStringAsFixed(2)} | ');
  }
  header.write('最佳覆盖 |');
  stdout.writeln(header.toString());
  stdout.writeln('|' + '---|' * (thresholds.length + 4));

  for (final q in queries) {
    final tokens = ChineseBigram.tokenize(q).toSet();
    final loose =
        await retriever.search(q, knowledgeBaseIds: [kb.id], topK: 100, threshold: 0.0);
    final best = loose.isEmpty ? 0.0 : loose.map((h) => h.score).reduce((a, b) => a > b ? a : b);

    final row = StringBuffer('| $q | ${q.runes.length} | ${tokens.length} | ');
    for (final t in thresholds) {
      final n = loose.where((h) => h.score + 1e-9 >= t).length;
      row.write('$n | ');
    }
    row.write('${best.toStringAsFixed(2)} |');
    stdout.writeln(row.toString());
  }

  // 关键结论：在候选阈值下，有多少查询"仍然有命中"（不被过滤空）。
  stdout.writeln();
  stdout.writeln('== 各阈值下"有命中的查询数"（共 ${queries.where((q) => ChineseBigram.tokenize(q).isNotEmpty).length} 个有效查询，排除单字）==');
  for (final t in thresholds) {
    var withHits = 0;
    for (final q in queries) {
      if (ChineseBigram.tokenize(q).isEmpty) continue;
      final n = await retriever.search(q, knowledgeBaseIds: [kb.id], topK: 5, threshold: t);
      if (n.isNotEmpty) withHits++;
    }
    stdout.writeln('  阈值 ${t.toStringAsFixed(2)} → $withHits 个查询有命中');
  }

  db.dispose();
  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {}
  stdout.writeln('\nCALIBRATE_OK');
}

Directory? _locatePackagesSrc() {
  final candidates = <String>['market/packages-src', '../market/packages-src'];
  try {
    final scriptDir = File.fromUri(Platform.script).parent;
    final repoRoot = scriptDir.parent.parent;
    candidates.add('${repoRoot.path}${Platform.pathSeparator}market'
        '${Platform.pathSeparator}packages-src');
  } catch (_) {}
  for (final c in candidates) {
    final d = Directory(c);
    if (d.existsSync()) return d;
  }
  return null;
}
