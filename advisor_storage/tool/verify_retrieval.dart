/// 检索质量验证脚本（纯 Dart，可 `dart run`）——用**真实中文文档**验证。
///
/// 运行：`cd advisor_storage && dart run tool/verify_retrieval.dart`
///
/// 覆盖（第 2 轮验收标准）：
/// 1. 真实语料：`market/packages-src/*/agents/main.md` 建库导入后，中文查询命中正确块；
/// 2. **「批量不再返回 0」回归**：源自古 `fts_probe2` 的"尾单字 + AND"缺陷场景，
///    多字中文查询必须命中（旧实现恒 0）；
/// 3. 知识库过滤（`knowledge_base_id` 生效）；
/// 4. coverage 阈值过滤 + 排序；
/// 5. 删除文档后不再命中（索引随删除同步维护）；
/// 6. 单字 CJK 查询无结果（bigram 方案的自然取向，符合预期）；
/// 7. 拉丁 / 数字分词（`MPa` 小写、`6000` 整体）；
/// 8. `InMemoryRetriever` 自证（advisor_core 侧无 SQLite 即可命中）。
///
/// SQLite 原生库：本机 Windows 使用系统 `winsqlite3.dll`（仅验证脚本 override）。
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

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));

  stdout.writeln('私人顾问团 · 检索质量验证（advisor_storage · 真实中文文档）');
  stdout.writeln('=' * 64);
  stdout.writeln('sqlite3 版本 = ${sqlite3.version.libVersion}');

  final src = _locatePackagesSrc();
  if (src == null) {
    stdout.writeln('✗ 未找到 market/packages-src（无法用真实文档验证）');
    exitCode = 1;
    return;
  }
  stdout.writeln('语料目录 = ${src.path}');

  final tmp = Directory.systemTemp.createTempSync('pa_retrieval_verify_');
  final sep = Platform.pathSeparator;
  final dbPath = '${tmp.path}${sep}retrieval.sqlite';

  final db = openAdvisorDatabase(dbPath);
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final retriever = Fts5Retriever(db);

  // 走完整服务链路（importDocument → retriever.indexChunks）。
  final knowledge = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 200),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    // 不注入 embeddingModel：retriever 独占路径，验证"不做 embedding 双写"。
    retriever: retriever,
  );

  final kb1 = await knowledge.createBase(name: '商务合规知识库');
  final kb2 = await knowledge.createBase(name: '技术规格知识库');

  section('导入真实中文文档');
  final bidTender = await _import(knowledge, repos, kb1.id, src, 'bid-tender-expert');
  final bidProposal = await _import(knowledge, repos, kb1.id, src, 'bid-proposal-expert');
  final bidPricing = await _import(knowledge, repos, kb1.id, src, 'bid-pricing-expert');
  final contractReview = await _import(knowledge, repos, kb1.id, src, 'contract-review-expert');
  final techSpec = await _import(knowledge, repos, kb2.id, src, 'tech-spec-expert');
  for (final d in [bidTender, bidProposal, bidPricing, contractReview, techSpec]) {
    check('导入 ${d.fileName} → 已索引且分块 > 0',
        d.status == DocumentStatus.indexed && d.chunkCount > 0, 'chunks=${d.chunkCount}');
  }

  final totalChunks = await _totalChunks(repos, [kb1.id, kb2.id]);
  section('索引一致性');
  check('FTS5 health() = true', await retriever.health());
  checkEq('FTS 索引行数 = 知识库分块总数', ftsRowCount(db), totalChunks);

  // —— 回归：批量不再返回 0（每条多字中文查询都必须命中）——
  section('回归：批量查询不再返回 0（源自古 fts_probe2 场景）');
  const regressionQueries = [
    '商务',
    '技术规格',
    '评分办法',
    '废标条款',
    '价格分',
    '参数比对',
    '偏离表',
    '风险条款',
  ];
  for (final q in regressionQueries) {
    final hits = await retriever.search(q, knowledgeBaseIds: [kb1.id, kb2.id], topK: 5);
    check('查 “$q” 命中 ≥1', hits.isNotEmpty, 'hits=${hits.length}');
  }

  // —— 命中正确块 + 来源文件 ——
  section('命中正确块 / 来源文件 / 相关度');
  final tenderHits = await retriever.search('废标条款清单', knowledgeBaseIds: [kb1.id], topK: 3);
  check('查 “废标条款清单” 命中', tenderHits.isNotEmpty);
  if (tenderHits.isNotEmpty) {
    check('来源为长篇解读文档',
        tenderHits.first.citation.fileName.contains('bid-tender-expert'),
        'file=${tenderHits.first.citation.fileName}');
    check('相关度 ∈ (0,1]',
        tenderHits.first.score > 0 && tenderHits.first.score <= 1,
        'score=${tenderHits.first.score}');
    stdout.writeln('    · 命中片段：'
        '${tenderHits.first.citation.text.replaceAll('\n', ' ').substring(0, 40)}…');
    stdout.writeln('    · ${tenderHits.first.citation.toDisplay()}');
  }

  final specHits = await retriever.search('参数逐条比对与偏离表', knowledgeBaseIds: [kb2.id], topK: 3);
  check('查 “参数逐条比对与偏离表”（kb2）命中', specHits.isNotEmpty);
  check('来源为技术规格文档（kb2 过滤生效）',
      specHits.isEmpty ? false : specHits.first.citation.fileName.contains('tech-spec-expert'),
      'file=${specHits.isEmpty ? null : specHits.first.citation.fileName}');

  // —— 知识库过滤 ——
  section('知识库过滤（knowledge_base_id）');
  final cross = await retriever.search('参数比对', knowledgeBaseIds: [kb1.id], topK: 5);
  final inKb2 = await retriever.search('参数比对', knowledgeBaseIds: [kb2.id], topK: 5);
  check('查 “参数比对” 限定 kb1 → 无命中（该词只属 kb2）', cross.isEmpty,
      'kb1 hits=${cross.length}');
  check('查 “参数比对” 限定 kb2 → 命中', inKb2.isNotEmpty, 'kb2 hits=${inKb2.length}');

  // —— 阈值过滤 + 排序 ——
  section('coverage 阈值过滤');
  final loose = await retriever.search('商务保证金递交开标时间节点',
      knowledgeBaseIds: [kb1.id], threshold: 0.0, topK: 5);
  final strict50 = await retriever.search('商务保证金递交开标时间节点',
      knowledgeBaseIds: [kb1.id], threshold: 0.5, topK: 5);
  final strict90 = await retriever.search('商务保证金递交开标时间节点',
      knowledgeBaseIds: [kb1.id], threshold: 0.9, topK: 5);
  check('阈值越高命中数单调不增', strict90.length <= strict50.length && strict50.length <= loose.length,
      '0.0→${loose.length}  0.5→${strict50.length}  0.9→${strict90.length}');

  // —— 单字 CJK：无结果 ——
  section('单字 / 边界查询');
  final singleCjk = await retriever.search('标', knowledgeBaseIds: [kb1.id, kb2.id]);
  check('单字 CJK 查询无结果（bigram 方案预期）', singleCjk.isEmpty);
  final empty = await retriever.search('   ', knowledgeBaseIds: [kb1.id]);
  check('空 / 纯空白查询无结果', empty.isEmpty);

  // —— 拉丁 / 数字分词 ——
  section('拉丁 / 数字分词（真实规格书文本）');
  final kb3 = await knowledge.createBase(name: '参数验证库');
  final specFile = File('${tmp.path}${sep}参数.md')
    ..writeAsStringSync('油箱容积 6000 L，额定压力 1.0 MPa，最高车速 100 km/h。');
  await knowledge.importDocument(
    knowledgeBaseId: kb3.id,
    filePath: specFile.path,
    fileName: '参数.md',
    fileBytes: specFile.readAsBytesSync(),
  );
  final hitNum = await retriever.search('6000', knowledgeBaseIds: [kb3.id]);
  check('数字串 “6000” 作为 1 token 命中', hitNum.isNotEmpty, 'hits=${hitNum.length}');
  final hitLatin = await retriever.search('mpa', knowledgeBaseIds: [kb3.id]);
  check('拉丁串 “mpa” 小写后命中 MPa', hitLatin.isNotEmpty, 'hits=${hitLatin.length}');
  final hitDecimal = await retriever.search('1.0', knowledgeBaseIds: [kb3.id]);
  check('含小数点数字 “1.0” 命中', hitDecimal.isNotEmpty, 'hits=${hitDecimal.length}');

  // —— 删除一致性 ——
  section('删除一致性');
  await knowledge.deleteDocument(techSpec.docId);
  final afterDelete = await retriever.search('参数比对', knowledgeBaseIds: [kb2.id]);
  check('删除 tech-spec 后，kb2 查 “参数比对” 不再命中', afterDelete.isEmpty,
      'hits=${afterDelete.length}');
  final afterDelete2 = await retriever.search('偏离表', knowledgeBaseIds: [kb1.id, kb2.id]);
  check('删除后全库查 “偏离表” 不再命中该文档', afterDelete2.every((h) =>
      !h.citation.fileName.contains('tech-spec-expert')));

  // —— InMemoryRetriever 自证（advisor_core 侧无 SQLite 即可命中）——
  section('InMemoryRetriever 自证（advisor_core 侧）');
  final memRetriever = InMemoryRetriever(repos.knowledge);
  final memBase = await knowledge.createBase(name: '内存检索验证');
  const memChunks = [
    KnowledgeChunk(id: 'mc1', documentId: 'mdoc', text: '工程车长臂喷射臂架', sequence: 0, chunkHash: 'm1'),
    KnowledgeChunk(id: 'mc2', documentId: 'mdoc', text: '油箱工程车额定流量', sequence: 1, chunkHash: 'm2'),
  ];
  await memRetriever.indexChunks(memChunks, knowledgeBaseId: memBase.id, documentId: 'mdoc');
  final memHits = await memRetriever.search('长臂', knowledgeBaseIds: [memBase.id]);
  check('InMemoryRetriever 查 “长臂” 命中 mc1',
      memHits.isNotEmpty && memHits.first.chunk.id == 'mc1');
  check('InMemoryRetriever health() = true', await memRetriever.health());

  // —— 检索质量小结（打印前若干命中，供人工核对）——
  section('检索质量小结（真实文档）');
  for (final q in ['长篇文档解读', '不平衡成本', '合同风险条款', '技术参数负偏离']) {
    final hits = await retriever.search(q, knowledgeBaseIds: [kb1.id, kb2.id], topK: 2);
    if (hits.isEmpty) {
      stdout.writeln('  查 “$q” → （无命中）');
    } else {
      final h = hits.first;
      stdout.writeln('  查 “$q” → ${h.citation.fileName}  cov=${h.score.toStringAsFixed(2)}');
    }
  }

  db.dispose();

  stdout.writeln('\n${'=' * 64}');
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

  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {
    // 忽略清理失败（WAL 可能被占用）。
  }
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

Future<int> _totalChunks(Repositories repos, List<String> kbIds) async {
  var total = 0;
  for (final kbId in kbIds) {
    for (final d in await repos.knowledge.listDocuments(kbId)) {
      total += (await repos.knowledge.listChunks(d.id)).length;
    }
  }
  return total;
}

Future<({String docId, String fileName, DocumentStatus status, int chunkCount})> _import(
  KnowledgeService knowledge,
  Repositories repos,
  String kbId,
  Directory src,
  String pkg,
) async {
  final file = File('${src.path}${Platform.pathSeparator}$pkg${Platform.pathSeparator}'
      'agents${Platform.pathSeparator}main.md');
  final name = '$pkg/main.md';
  final r = await knowledge.importDocument(
    knowledgeBaseId: kbId,
    filePath: file.path,
    fileName: name,
    fileBytes: file.readAsBytesSync(),
  );
  return (docId: r.doc.id, fileName: name, status: r.doc.status, chunkCount: r.chunkCount);
}

/// 定位仓库内真实语料目录 `market/packages-src`（优先 CWD，其次脚本相对路径）。
Directory? _locatePackagesSrc() {
  final candidates = <String>['market/packages-src', '../market/packages-src'];
  try {
    final scriptDir = File.fromUri(Platform.script).parent; // .../advisor_storage/tool
    final advisorStorage = scriptDir.parent; // .../advisor_storage
    final repoRoot = advisorStorage.parent; // 仓库根
    candidates.add('${repoRoot.path}${Platform.pathSeparator}market'
        '${Platform.pathSeparator}packages-src');
    candidates.add('${repoRoot.path}${Platform.pathSeparator}..'
        '${Platform.pathSeparator}market${Platform.pathSeparator}packages-src');
  } catch (_) {
    // Platform.script 不可用时忽略。
  }
  for (final c in candidates) {
    final d = Directory(c);
    if (d.existsSync()) return d;
  }
  return null;
}
