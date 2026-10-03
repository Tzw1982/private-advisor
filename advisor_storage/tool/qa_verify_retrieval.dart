/// QA 独立验证脚本（严过关）——第 2 轮 FTS5 中文检索链路。
///
/// 运行：`cd advisor_storage && dart run tool/qa_verify_retrieval.dart`
///
/// 与工程师的 `verify_retrieval.dart` **相互独立**：不复制其断言；用真实中文语料
/// （`market/packages-src/*/agents/main.md`）自造查询与场景。覆盖：
/// R1 批量多文档×多查询（旧「恒 0」缺陷的触发条件）
/// R2 bigram 规约（索引端/查询端共用 tokenize；OR 召回，无 AND；尾单字不追加）
/// R3 FTS 与业务表一致性（删除后绕开 API 直查 FTS 表）
/// R4 降级路径（FTS 不可用时不静默）
/// R5 阈值复核（自造查询，给出各阈值召回数据）
library;

import 'dart:ffi';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';
import 'package:advisor_storage/advisor_storage.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

// ---------------------------------------------------------------------------
// 独立断言框架
// ---------------------------------------------------------------------------

class RCase {
  RCase(this.id, this.name, this.expected, this.actual, this.pass, [this.note]);
  final String id, name, expected, actual;
  final bool pass;
  final String? note;
}

final List<RCase> _res = [];
int _pass = 0, _fail = 0;

void t(String id, String name, Object? expected, Object? actual, {String? note}) {
  final ok = expected == actual;
  if (ok) {
    _pass++;
  } else {
    _fail++;
  }
  _res.add(RCase(id, name, '$expected', '$actual', ok, note));
  stdout.writeln('  ${ok ? '✓' : '✗'} [$id] $name  (期望=$expected 实际=$actual)');
}

void section(String s) => stdout.writeln('\n── $s ──────────────────────────');

// ---------------------------------------------------------------------------

Future<void> main() async {
  open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  stdout.writeln('严过关 · QA 独立验证（第 2 轮检索链路）');
  stdout.writeln('=' * 62);
  stdout.writeln('sqlite3 = ${sqlite3.version.libVersion}');

  final src = _locatePackagesSrc();
  if (src == null) {
    stdout.writeln('✗ 未找到 market/packages-src，终止');
    exitCode = 1;
    return;
  }
  stdout.writeln('语料 = ${src.path}');

  final tmp = Directory.systemTemp.createTempSync('pa_qa_retr_');
  final sep = Platform.pathSeparator;

  await _r2_bigramRules(); // 纯函数 + 静态源码检查（无 DB）

  await _r1_batch(tmp, sep, src); // 批量多文档×多查询 + R3 一致性（同一 DB）
  await _r4_degradation(tmp, sep); // 降级
  await _r5_threshold(tmp, sep, src); // 阈值复核
  await _s_o1StartupBackfill(tmp, sep); // O-1 启动兜底回填（独立场景，非重跑工程师脚本）

  _print();
  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {}
  exitCode = _fail == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// R1 批量多文档 × 多查询（旧「恒 0」触发条件）+ R3 FTS/业务表一致性
// ---------------------------------------------------------------------------

Future<void> _r1_batch(Directory tmp, String sep, Directory src) async {
  section('R1 批量：多文档 × 多查询（旧「恒 0」缺陷触发条件）');
  final db = openAdvisorDatabase('${tmp.path}${sep}r1.sqlite');
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final rt = Fts5Retriever(db);
  final svc = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 200),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    retriever: rt, // 关键词独占，不注入 embedding
  );

  // 5 篇真实文档分属 2 个知识库 —— 制造"多文档"批量条件
  final kbA = await svc.createBase(name: 'A库');
  final kbB = await svc.createBase(name: 'B库');
  final docs = <String, String>{}; // pkg → fileName
  for (final pkg in [
    'bid-tender-expert',
    'bid-proposal-expert',
    'bid-pricing-expert',
    'contract-review-expert',
    'tech-spec-expert',
  ]) {
    final kb = (pkg == 'tech-spec-expert') ? kbB : kbA;
    final f = File('${src.path}$sep$pkg${sep}agents${sep}main.md');
    final name = '$pkg/main.md';
    await svc.importDocument(
      knowledgeBaseId: kb.id,
      filePath: f.path,
      fileName: name,
      fileBytes: f.readAsBytesSync(),
    );
    docs[pkg] = name;
  }
  final allKb = [kbA.id, kbB.id];
  var totalChunks = 0;
  for (final kbId in allKb) {
    for (final d in await repos.knowledge.listDocuments(kbId)) {
      totalChunks += (await repos.knowledge.listChunks(d.id)).length;
    }
  }
  t('R1.1', 'FTS 行数 = 业务分块总数', totalChunks, ftsRowCount(db));

  // 自造的多查询集：每条形如 (查询, 期望命中文档 pkg)
  final cases = <(String, String)>[
    ('废标条款', 'bid-tender-expert'),
    ('评分办法还原', 'bid-tender-expert'),
    ('资格条件提取', 'bid-tender-expert'),
    ('逐条响应表', 'bid-proposal-expert'),
    ('不平衡成本', 'bid-pricing-expert'),
    ('价格分策略', 'bid-pricing-expert'),
    ('风险分级', 'contract-review-expert'),
    ('条款风险识别', 'contract-review-expert'),
    ('偏离表编制', 'tech-spec-expert'),
    ('参数逐条比对', 'tech-spec-expert'),
  ];
  var zero = 0, wrongDoc = 0;
  for (final (q, pkg) in cases) {
    final hits = await rt.search(q, knowledgeBaseIds: allKb, topK: 5);
    if (hits.isEmpty) {
      zero++;
      t('R1.batch', '查“$q”命中≥1', true, false, note: '返回 0');
      continue;
    }
    final okDoc = hits.take(3).any((h) => h.citation.fileName.contains(pkg));
    if (!okDoc) wrongDoc++;
    final top = hits.first.citation.fileName;
    t('R1.batch', '查“$q”→ Top3 含 $pkg', true, okDoc, note: 'top1=$top');
  }
  t('R1.2', '批量查询全部非 0（旧缺陷已根治）', 0, zero);
  t('R1.3', '批量查询 Top3 文档全部正确', 0, wrongDoc);

  // —— R3 FTS 与业务表一致性（绕开 API 直查 FTS）——
  section('R3 FTS 索引与业务表一致性（直查 FTS 表）');
  final techDoc = (await repos.knowledge.listDocuments(kbB.id)).first;
  final otherDoc = (await repos.knowledge.listDocuments(kbA.id)).first;
  t('R3.1', '删除前：该文档 FTS 行数>0', true,
      _ftsByDoc(db, techDoc.id) > 0, note: 'rows=${_ftsByDoc(db, techDoc.id)}');
  final otherBefore = _ftsByDoc(db, otherDoc.id);

  await svc.deleteDocument(techDoc.id);
  t('R3.2', '删文档后该文档 FTS 行数=0（同步清理）', 0, _ftsByDoc(db, techDoc.id));
  t('R3.3', '他文档 FTS 不受影响', otherBefore, _ftsByDoc(db, otherDoc.id));
  t('R3.4', '无孤儿 FTS 行（chunk_id 均存在业务表）', 0, _ftsOrphans(db));

  await svc.deleteBase(kbA.id);
  t('R3.5', '删知识库后该库 FTS 行数=0', 0, _ftsByKb(db, kbA.id));
  t('R3.6', '删库后仍无孤儿 FTS 行', 0, _ftsOrphans(db));

  db.dispose();
}

// ---------------------------------------------------------------------------
// R2 bigram 规约（静态源码 + 纯函数行为）
// ---------------------------------------------------------------------------

Future<void> _r2_bigramRules() async {
  section('R2 bigram 规约：三处共用 tokenize / OR 召回 / 无尾单字');

  // —— 静态：索引端与查询端是否共用 ChineseBigram.tokenize ——
  final retr = File('lib/src/database/fts_retriever.dart').readAsStringSync();
  final supp = File('lib/src/database/support.dart').readAsStringSync();
  t('R2.1', '查询端使用 ChineseBigram.tokenize', true, retr.contains('ChineseBigram.tokenize'));
  t('R2.2', '索引端(insertFtsRows)使用 ChineseBigram.tokenize', true,
      supp.contains('ChineseBigram.tokenize'));
  t('R2.3', '召回用 OR 连接（无 AND）', true,
      retr.contains(".join(' OR ')") && !retr.contains(".join(' AND ')"));
  t('R2.4', 'fts_retriever.dart 内不存在 join(\' AND \')', false,
      retr.contains(".join(' AND ')"));

  // —— 行为：纯函数规约 ——
  t('R2.5', 'tokenize("长臂") 只产 bigram、无尾单字', '[长臂]', '${ChineseBigram.tokenize('长臂')}');
  t('R2.6', 'tokenize("工程车长臂") 无尾单字"臂"', '[工程, 程车, 车长, 长臂]',
      '${ChineseBigram.tokenize('工程车长臂')}');
  t('R2.7', 'tokenize 尾字不单独成 token', false,
      ChineseBigram.tokenize('工程车长臂').contains('臂'));
  t('R2.8', '单字 CJK 才产单 token', '[泵]', '${ChineseBigram.tokenize('泵')}');
  t('R2.9', '拉丁串小写整体成 token', '[mpa]', '${ChineseBigram.tokenize('MPa')}');
  t('R2.10', '数字含小数点整体成 token', '[1.0]', '${ChineseBigram.tokenize('1.0')}');
  t('R2.11', '句末数字去尾点（kg.→kg）', '[6000, kg]', '${ChineseBigram.tokenize('6000 kg.')}');

  // —— 行为：旧 bug 场景（尾单字 + AND）不再复现 ——
  section('R2b 旧缺陷场景（尾单字 + AND 恒 0）行为复核');
  final tmp2 = Directory.systemTemp.createTempSync('pa_qa_r2_');
  final db = openAdvisorDatabase('${tmp2.path}${Platform.pathSeparator}r2.sqlite');
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final rt = Fts5Retriever(db);
  final now = DateTime.now().millisecondsSinceEpoch;
  await repos.knowledge.upsertBase(
      KnowledgeBase(id: 'kb2', name: 'R2', createdAt: now, updatedAt: now));
  await repos.knowledge.upsertDocument(KnowledgeDocument(
      id: 'd2', knowledgeBaseId: 'kb2', fileName: 'r2.md', filePath: '/r2', fileHash: 'R2',
      fileSize: 1, status: DocumentStatus.indexed, createdAt: now, updatedAt: now));
  const chunks = [
    KnowledgeChunk(id: 'r2c1', documentId: 'd2', text: '火警长臂喷射臂架系统', sequence: 1, chunkHash: 'x1'),
    KnowledgeChunk(id: 'r2c2', documentId: 'd2', text: '油箱容积六千升', sequence: 2, chunkHash: 'x2'),
  ];
  await repos.knowledge.insertChunks(chunks);
  await rt.indexChunks(chunks, knowledgeBaseId: 'kb2', documentId: 'd2');

  final tail = await rt.search('长臂', knowledgeBaseIds: ['kb2']);
  t('R2.12', '“长臂”命中（旧实现恒 0）', true, tail.isNotEmpty,
      note: 'hits=${tail.length}');
  final multi = await rt.search('长臂喷射臂架', knowledgeBaseIds: ['kb2']);
  t('R2.13', '“长臂喷射臂架”命中', true, multi.isNotEmpty);
  final single = await rt.search('高', knowledgeBaseIds: ['kb2']);
  t('R2.14', '单字“高”无命中（尾字未入索引，符合 bigram 取向）', true, single.isEmpty);
  db.dispose();
  try {
    tmp2.deleteSync(recursive: true);
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// R4 降级路径（FTS 不可用时不得静默）
// ---------------------------------------------------------------------------

Future<void> _r4_degradation(Directory tmp, String sep) async {
  section('R4 降级路径：FTS 不可用时不静默');
  final db = openAdvisorDatabase('${tmp.path}${sep}r4.sqlite');
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final rt = Fts5Retriever(db);
  final svc = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 200),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    retriever: rt, // 无 embeddingModel → 无真正降级后备
  );

  // 模拟 FTS 不可用：删掉虚表
  db.execute('DROP TABLE IF EXISTS $kFtsTable');
  t('R4.1', 'FTS 表已移除（模拟不可用）', false, ftsTableExists(db));
  t('R4.2', 'health() = false', false, await rt.health());
  t('R4.3', 'ftsAvailable = false', false, ftsAvailable(db));

  // 索引写入必须显式失败（不静默吞）
  Object? idxErr;
  try {
    await rt.indexChunks(const [
      KnowledgeChunk(id: 'z1', documentId: 'z', text: 'x', sequence: 1, chunkHash: 'z'),
    ], knowledgeBaseId: 'kbz', documentId: 'z');
  } catch (e) {
    idxErr = e;
  }
  t('R4.4', 'indexChunks 抛 StorageError（不静默）', true, idxErr is StorageError);
  t('R4.5', '错误码 storage.retrieval.no_fts', 'storage.retrieval.no_fts',
      idxErr is StorageError ? idxErr.code : '${idxErr.runtimeType}');

  // search 在不可用时返回空（而非抛）——可接受，但 UI 需据 health/label 提示
  final emptyHits = await rt.search('长篇', knowledgeBaseIds: ['kbx']);
  t('R4.6', 'search 不可用时安全返回空', 0, emptyHits.length);

  // 服务层：不得静默降级为「无结果」
  Object? svcErr;
  try {
    await svc.retrieve(query: '长篇文档', knowledgeBaseIds: ['kbx']);
  } catch (e) {
    svcErr = e;
  }
  t('R4.7', 'retrieve() 无后备时显式抛错（不静默返回空）', true, svcErr != null,
      note: '实际=${svcErr.runtimeType}');
  t('R4.8', '抛的是 KnowledgeError(kb.no_embedding)', 'kb.no_embedding',
      svcErr is KnowledgeError ? svcErr.code : '${svcErr.runtimeType}');

  // 降级标签必须显式（严禁静默）
  final label = await svc.retrievalBackendLabel();
  t('R4.9', 'retrievalBackendLabel 显式标注降级', '降级：向量检索（FTS5 不可用）', label);
  t('R4.10', 'isKeywordRetrievalHealthy = false', false, await svc.isKeywordRetrievalHealthy());

  db.dispose();

  // 对照：FTS 可用时标签为「FTS5 中文检索」
  final db2 = openAdvisorDatabase('${tmp.path}${sep}r4b.sqlite');
  ensureSchema(db2);
  final repos2 = sqliteRepositories(db2, secrets: InMemorySecretStore());
  final svc2 = KnowledgeService(
    repos2,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 200),
    vectorStore: InMemoryVectorStore(repos2.knowledge),
    retriever: Fts5Retriever(db2),
  );
  t('R4.11', 'FTS 可用时标签=FTS5 中文检索', 'FTS5 中文检索', await svc2.retrievalBackendLabel());
  t('R4.12', 'FTS 可用时 isKeywordRetrievalHealthy=true', true,
      await svc2.isKeywordRetrievalHealthy());
  db2.dispose();

  // 真正的降级走通：retriever 不可用 + 有向量后备（embeddingModel）→ 走 vector 路径
  final dbv = openAdvisorDatabase('${tmp.path}${sep}r4c.sqlite');
  ensureSchema(dbv);
  dbv.execute('DROP TABLE IF EXISTS $kFtsTable'); // 令关键词后端不可用
  final reposV = sqliteRepositories(dbv, secrets: InMemorySecretStore());
  final vec = InMemoryVectorStore(reposV.knowledge);
  final svcV = KnowledgeService(
    reposV,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 200),
    vectorStore: vec,
    embeddingModel: HashEmbeddingModel(dimension: 256),
    retriever: Fts5Retriever(dbv),
  );
  final kbV = await svcV.createBase(name: '降级库');
  final fv = File('${tmp.path}${sep}降级.md')
    ..writeAsStringSync('工程车油箱容积六千升。液压泵额定流量六十升每秒。');
  final imported = await svcV.importDocument(
    knowledgeBaseId: kbV.id,
    filePath: fv.path,
    fileName: '降级.md',
    fileBytes: fv.readAsBytesSync(),
  );
  t('R4.13', '降级时 importDocument 仍成功（走 embedding 路径）', DocumentStatus.indexed,
      imported.doc.status);
  final dhits = await svcV.retrieve(query: '油箱容积', knowledgeBaseIds: [kbV.id], threshold: 0.0);
  t('R4.14', '降级到向量路径并返回命中（真的走通）', true, dhits.isNotEmpty,
      note: 'hits=${dhits.length}');
  dbv.dispose();
}

// ---------------------------------------------------------------------------
// R5 阈值复核（自造查询，输出召回数据）
// ---------------------------------------------------------------------------

Future<void> _r5_threshold(Directory tmp, String sep, Directory src) async {
  section('R5 coverage 阈值复核（自造查询 × 真实语料）');
  final db = openAdvisorDatabase('${tmp.path}${sep}r5.sqlite');
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final rt = Fts5Retriever(db);
  final svc = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 200),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    retriever: rt,
  );
  final kb = await svc.createBase(name: '阈值库');
  for (final pkg in [
    'bid-tender-expert',
    'bid-proposal-expert',
    'bid-pricing-expert',
    'contract-review-expert',
    'tech-spec-expert',
  ]) {
    final f = File('${src.path}$sep$pkg${sep}agents${sep}main.md');
    await svc.importDocument(
      knowledgeBaseId: kb.id,
      filePath: f.path,
      fileName: '$pkg/main.md',
      fileBytes: f.readAsBytesSync(),
    );
  }

  // 自造查询（区别于工程师样本）：混合短词 / 长句
  final queries = <String>[
    '废标', // 2 字
    '偏离表', // 3 字
    '不平衡成本', // 5 字
    '商务人资格条件', // 7 字
    '价格分与技术分的权重', // 10 字
    '商务保证金递交开标时间节点', // 13 字（多概念长句）
  ];
  const thresholds = [0.3, 0.4, 0.5, 0.6, 0.75, 1.0];

  final header = StringBuffer('| 查询 | bigram数 | ');
  for (final th in thresholds) {
    header.write('≥${th.toStringAsFixed(2)} | ');
  }
  header.write('最佳覆盖 |');
  stdout.writeln(header);
  stdout.writeln('|' + '---|' * (thresholds.length + 3));

  final withHitsAt = <double, int>{for (final th in thresholds) th: 0};
  var validQueries = 0;
  for (final q in queries) {
    final nTok = ChineseBigram.tokenize(q).toSet().length;
    if (nTok == 0) continue;
    validQueries++;
    final loose = await rt.search(q, knowledgeBaseIds: [kb.id], topK: 100, threshold: 0.0);
    final best = loose.isEmpty ? 0.0 : loose.map((h) => h.score).reduce((a, b) => a > b ? a : b);
    final row = StringBuffer('| $q | $nTok | ');
    for (final th in thresholds) {
      final n = loose.where((h) => h.score + 1e-9 >= th).length;
      row.write('$n | ');
      if (n > 0) withHitsAt[th] = withHitsAt[th]! + 1;
    }
    row.write('${best.toStringAsFixed(2)} |');
    stdout.writeln(row);
  }

  stdout.writeln('\n各阈值下"仍有命中的查询数"（共 $validQueries 条有效查询）：');
  for (final th in thresholds) {
    stdout.writeln('  阈值 ${th.toStringAsFixed(2)} → ${withHitsAt[th]}/$validQueries');
  }

  // 断言：命中数随阈值单调不增（数据健全性）
  var monotonic = true;
  for (var i = 1; i < thresholds.length; i++) {
    if (withHitsAt[thresholds[i]]! > withHitsAt[thresholds[i - 1]]!) monotonic = false;
  }
  t('R5.1', '命中数随阈值单调不增', true, monotonic);

  // 断言：默认阈值 0.5 下，全部有效查询仍有 ≥1 命中（覆盖"长多概念查询不塌成 0"）
  t('R5.2', '默认阈值 0.5 下有效查询仍有命中的比例', validQueries, withHitsAt[0.5],
      note: '用于判断 0.5 是否合理');

  // 单字查询：bigram=0 → 无结果
  final one = await rt.search('标', knowledgeBaseIds: [kb.id]);
  t('R5.3', '单字查询无结果（bigram=0）', 0, one.length);

  db.dispose();
}

// ---------------------------------------------------------------------------
// S: O-1 启动兜底回填（独立构造 4 个场景，非重跑工程师脚本）
// ---------------------------------------------------------------------------

String _ftsSnapshot(Database db) => db
    .select('SELECT chunk_id, bg FROM $kFtsTable ORDER BY chunk_id')
    .map((r) => '${r['chunk_id']}=${r['bg']}')
    .join(' | ');

Future<void> _s_o1StartupBackfill(Directory tmp, String sep) async {
  section('S O-1 启动兜底回填（独立场景）');

  // —— S1: v2 库 + chunks 非空 + FTS 被清空 → ensureSchema 应自动回填且可检索 ——
  final db = openAdvisorDatabase('${tmp.path}${sep}s1.sqlite');
  ensureSchema(db);
  final repos = sqliteRepositories(db, secrets: InMemorySecretStore());
  final rt = Fts5Retriever(db);
  final now = DateTime.now().millisecondsSinceEpoch;
  await repos.knowledge.upsertBase(
      KnowledgeBase(id: 's_kb', name: 'S', createdAt: now, updatedAt: now));
  await repos.knowledge.upsertDocument(KnowledgeDocument(
      id: 's_doc', knowledgeBaseId: 's_kb', fileName: 's.md', filePath: '/s', fileHash: 'S',
      fileSize: 1, status: DocumentStatus.indexed, createdAt: now, updatedAt: now));
  const sChunks = [
    KnowledgeChunk(id: 's_c1', documentId: 's_doc', text: '工程车油箱容积六千升', sequence: 1, chunkHash: 's1'),
    KnowledgeChunk(id: 's_c2', documentId: 's_doc', text: '液压泵额定流量六十升每秒', sequence: 2, chunkHash: 's2'),
  ];
  await repos.knowledge.insertChunks(sChunks);
  await rt.indexChunks(sChunks, knowledgeBaseId: 's_kb', documentId: 's_doc');
  t('S1.1', '索引后 FTS=2', 2, ftsRowCount(db));
  db.execute('DELETE FROM $kFtsTable'); // 模拟索引被清空（异常/外部工具/半途失败）
  t('S1.2', '清空后 FTS=0（chunks 仍 2）', 0, ftsRowCount(db));
  t('S1.2b', 'chunks 业务表仍为 2（未动业务数据）', 2,
      (db.select("SELECT COUNT(*) c FROM knowledge_chunks WHERE document_id='s_doc'").first['c']
              as num)
          .toInt());

  ensureSchema(db); // 启动兜底回填
  t('S1.3', 'ensureSchema 后自动回填 FTS=2', 2, ftsRowCount(db));
  final hits = await rt.search('油箱容积', knowledgeBaseIds: ['s_kb']);
  t('S1.4', '回填后可通过检索命中存量分块', true, hits.isNotEmpty,
      note: 'hit=${hits.isEmpty ? null : hits.first.chunk.id}');
  final snap1 = _ftsSnapshot(db);

  // —— S2: 幂等——再跑一次 ensureSchema 不重复插入 ——
  ensureSchema(db);
  t('S2.1', '再次 ensureSchema 后 FTS 仍为 2（不重复插）', 2, ftsRowCount(db));
  t('S2.2', 'FTS 内容快照完全一致（无重复/无变化）', true, _ftsSnapshot(db) == snap1);

  // —— S3: FTS 非空正常库 → ensureSchema 不重建（内容不变、行数不变）——
  final db3 = openAdvisorDatabase('${tmp.path}${sep}s3.sqlite');
  ensureSchema(db3);
  final repos3 = sqliteRepositories(db3, secrets: InMemorySecretStore());
  final rt3 = Fts5Retriever(db3);
  await repos3.knowledge.upsertBase(
      KnowledgeBase(id: 's3_kb', name: 'S3', createdAt: now, updatedAt: now));
  await repos3.knowledge.upsertDocument(KnowledgeDocument(
      id: 's3_doc', knowledgeBaseId: 's3_kb', fileName: 's3.md', filePath: '/s3', fileHash: 'S3',
      fileSize: 1, status: DocumentStatus.indexed, createdAt: now, updatedAt: now));
  const s3Chunks = [
    KnowledgeChunk(id: 's3_c1', documentId: 's3_doc', text: '油箱容积六千升', sequence: 1, chunkHash: 'a1'),
    KnowledgeChunk(id: 's3_c2', documentId: 's3_doc', text: '液压泵流量六十升', sequence: 2, chunkHash: 'a2'),
    KnowledgeChunk(id: 's3_c3', documentId: 's3_doc', text: '长臂喷射臂架', sequence: 3, chunkHash: 'a3'),
  ];
  await repos3.knowledge.insertChunks(s3Chunks);
  await rt3.indexChunks(s3Chunks, knowledgeBaseId: 's3_kb', documentId: 's3_doc');
  final beforeCount = ftsRowCount(db3);
  final beforeSnap = _ftsSnapshot(db3);
  ensureSchema(db3);
  t('S3.1', 'FTS 非空时 ensureSchema 后行数不变', beforeCount, ftsRowCount(db3));
  t('S3.2', 'FTS 非空时 ensureSchema 后内容逐字不变（未全量重建）', true,
      _ftsSnapshot(db3) == beforeSnap);
  t('S3.3', '版本仍为 kSchemaVersion', kSchemaVersion, userVersion(db3));
  db3.dispose();

  // —— S4: FTS 表存在但 chunks 为空 → 不误插、无异常 ——
  final db4 = openAdvisorDatabase('${tmp.path}${sep}s4.sqlite');
  ensureSchema(db4);
  t('S4.1', '空库 FTS=0 且 chunks=0', '0/0',
      '${ftsRowCount(db4)}/${db4.select('SELECT COUNT(*) c FROM knowledge_chunks').first['c']}');
  var threw = false;
  try {
    ensureSchema(db4);
    ensureSchema(db4);
  } catch (_) {
    threw = true;
  }
  t('S4.2', 'chunks 为空时重复 ensureSchema 不抛异常', false, threw);
  t('S4.3', 'chunks 为空时不误插（FTS 仍 0）', 0, ftsRowCount(db4));
  db4.dispose();

  db.dispose();
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

int _ftsByDoc(Database db, String docId) =>
    (db.select('SELECT COUNT(*) AS c FROM $kFtsTable WHERE document_id = ?', [docId])
        .first['c'] as num)
        .toInt();

int _ftsByKb(Database db, String kbId) =>
    (db.select('SELECT COUNT(*) AS c FROM $kFtsTable WHERE knowledge_base_id = ?', [kbId])
        .first['c'] as num)
        .toInt();

int _ftsOrphans(Database db) => (db.select(
            'SELECT COUNT(*) AS c FROM $kFtsTable f '
            'LEFT JOIN knowledge_chunks c ON c.id = f.chunk_id WHERE c.id IS NULL')
        .first['c'] as num)
    .toInt();

Directory? _locatePackagesSrc() {
  final candidates = <String>['market/packages-src', '../market/packages-src'];
  try {
    final scriptDir = File.fromUri(Platform.script).parent; // .../advisor_storage/tool
    final repoRoot = scriptDir.parent.parent; // 仓库根
    candidates.add('${repoRoot.path}${Platform.pathSeparator}market'
        '${Platform.pathSeparator}packages-src');
  } catch (_) {}
  for (final c in candidates) {
    final d = Directory(c);
    if (d.existsSync()) return d;
  }
  return null;
}

void _print() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('# QA 检索链路用例表');
  stdout.writeln('| ID | 用例 | 期望 | 实际 | 结论 |');
  stdout.writeln('|----|------|------|------|------|');
  for (final r in _res) {
    stdout.writeln(
        '| ${r.id} | ${r.name} | ${r.expected.replaceAll('|', r'\|')} | ${r.actual.replaceAll('|', r'\|')} | ${r.pass ? 'PASS' : 'FAIL'} |');
  }
  stdout.writeln('\n合计：通过 $_pass ／ 失败 $_fail');
  if (_fail > 0) {
    stdout.writeln('\n失败明细：');
    for (final r in _res.where((r) => !r.pass)) {
      stdout.writeln('  - [${r.id}] ${r.name}：期望=${r.expected} 实际=${r.actual}'
          '${r.note == null ? '' : '  （${r.note}）'}');
    }
  }
}
