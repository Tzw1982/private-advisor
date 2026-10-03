/// `Fts5Retriever`：`Retriever` 端口的 **FTS5 实现**（纯 Dart，无 Flutter）。
///
/// 机制（第 2 轮设计 §3.2 / §3.3 / §3.4）：
/// 1. 索引：对每个分块取 `ChineseBigram.tokenize(text)`，以空格连接写入 FTS5 的
///    `bg` 列（唯一被索引的列）；
/// 2. 召回：查询同样经 `ChineseBigram.tokenize`，多个 token 以 **`OR`** 连接执行
///    `MATCH`（**绝不使用 AND，也不追加尾单字**——否则恒 0 命中，见 text_index.dart）；
/// 3. 精排：对候选块按 **coverage**（`|Q∩C| / |Q|`）过滤并排序，同分再按 `bm25` 升序；
/// 4. 回连：命中后按 `chunk_id` 回连 `knowledge_chunks` + `knowledge_documents`
///    取正文与来源文件名（正文不进 FTS）。
///
/// 错误一律归一化为 [StorageError]（`storage.retrieval.*`）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support.dart';

class Fts5Retriever implements Retriever {
  Fts5Retriever(this.db);

  /// 已打开并 `ensureSchema` 的数据库连接。
  final Database db;

  @override
  Future<bool> health() async => ftsAvailable(db);

  @override
  Future<void> indexChunks(
    List<KnowledgeChunk> chunks, {
    required String knowledgeBaseId,
    required String documentId,
  }) async {
    if (chunks.isEmpty) return;
    _guard('storage.retrieval.index_chunks', () {
      if (!ftsTableExists(db)) {
        throw const StorageError('storage.retrieval.no_fts', '检索索引不可用（FTS5 未就绪）');
      }
      transaction(db, () {
        insertFtsRows(
          db,
          chunks.map((c) => (
                chunkId: c.id,
                documentId: documentId,
                knowledgeBaseId: knowledgeBaseId,
                text: c.text,
              )),
        );
      });
    });
  }

  @override
  Future<void> deleteByDocument(String documentId) async {
    _guard('storage.retrieval.delete_document', () {
      if (!ftsTableExists(db)) return;
      db.execute('DELETE FROM $kFtsTable WHERE document_id = ?', [documentId]);
    });
  }

  @override
  Future<void> deleteByKnowledgeBase(String knowledgeBaseId) async {
    _guard('storage.retrieval.delete_knowledge_base', () {
      if (!ftsTableExists(db)) return;
      db.execute('DELETE FROM $kFtsTable WHERE knowledge_base_id = ?', [knowledgeBaseId]);
    });
  }

  @override
  Future<List<RetrievalHit>> search(
    String query, {
    required List<String> knowledgeBaseIds,
    int topK = 5,
    double threshold = 0.0,
  }) async {
    // 分词（与索引端同一函数）；查询集去重。
    final queryTokens = ChineseBigram.tokenize(query).toSet();
    // 单字 / 空查询：bigram 集合为空 → 无结果（bigram 方案的自然取向，符合预期）。
    if (queryTokens.isEmpty || knowledgeBaseIds.isEmpty || topK <= 0) return const [];

    return _guard('storage.retrieval.search', () {
      if (!ftsTableExists(db)) return <RetrievalHit>[];

      // OR 召回：`"t1" OR "t2" ...`。token 仅含 CJK / 字母 / 数字 / 小数点，无引号，无需转义。
      final match = queryTokens.map((t) => '"$t"').join(' OR ');
      final candidates = topK * 4 < 20 ? 20 : topK * 4;
      final kbPlaceholders = List.filled(knowledgeBaseIds.length, '?').join(',');

      final rows = db.select(
        'SELECT chunk_id, bm25($kFtsTable) AS score FROM $kFtsTable '
        'WHERE $kFtsTable MATCH ? AND knowledge_base_id IN ($kbPlaceholders) '
        'ORDER BY score LIMIT ?',
        [match, ...knowledgeBaseIds, candidates],
      );

      // 对候选块回连正文，计算 coverage 并过滤。
      final scored = <({KnowledgeChunk chunk, String fileName, double cov, double bm25})>[];
      for (final r in rows) {
        final loaded = _loadChunk(r['chunk_id'] as String);
        if (loaded == null) continue;
        final (chunk, fileName) = loaded;
        final cov = ChineseBigram.coverage(queryTokens, ChineseBigram.tokenize(chunk.text).toSet());
        if (cov + 1e-9 < threshold) continue;
        scored.add((chunk: chunk, fileName: fileName, cov: cov, bm25: (r['score'] as num).toDouble()));
      }

      // 排序：coverage DESC，同分再 bm25 ASC（越小越相关）。
      scored.sort((a, b) {
        final byCov = b.cov.compareTo(a.cov);
        return byCov != 0 ? byCov : a.bm25.compareTo(b.bm25);
      });

      final out = <RetrievalHit>[];
      for (final s in scored) {
        if (out.length >= topK) break;
        out.add(RetrievalHit(
          chunk: s.chunk,
          score: s.cov,
          citation: Citation(
            chunkId: s.chunk.id,
            documentId: s.chunk.documentId,
            fileName: s.fileName,
            text: s.chunk.text,
            score: s.cov,
            page: s.chunk.page,
            headingPath: s.chunk.headingPath,
          ),
        ));
      }
      return out;
    });
  }

  @override
  Future<void> rebuild(String knowledgeBaseId) async {
    _guard('storage.retrieval.rebuild', () {
      if (!ftsTableExists(db)) return;
      transaction(db, () {
        db.execute('DELETE FROM $kFtsTable WHERE knowledge_base_id = ?', [knowledgeBaseId]);
        final rows = db.select(
          'SELECT c.id AS chunk_id, c.document_id AS document_id, c.text AS text '
          'FROM knowledge_chunks c JOIN knowledge_documents d ON d.id = c.document_id '
          'WHERE d.knowledge_base_id = ?',
          [knowledgeBaseId],
        );
        insertFtsRows(
          db,
          rows.map((r) => (
                chunkId: r['chunk_id'] as String,
                documentId: r['document_id'] as String,
                knowledgeBaseId: knowledgeBaseId,
                text: r['text'] as String,
              )),
        );
      });
    });
  }

  /// 按 `chunk_id` 回连分块正文与来源文件名。
  (KnowledgeChunk, String)? _loadChunk(String chunkId) {
    final rs = db.select(
      'SELECT c.*, d.file_name AS __file_name '
      'FROM knowledge_chunks c JOIN knowledge_documents d ON d.id = c.document_id '
      'WHERE c.id = ?',
      [chunkId],
    );
    if (rs.isEmpty) return null;
    final r = rs.first;
    final chunk = KnowledgeChunk(
      id: r['id'] as String,
      documentId: r['document_id'] as String,
      parentChunkId: rowString(r['parent_chunk_id']),
      text: r['text'] as String,
      headingPath: rowString(r['heading_path']),
      page: rowInt(r['page']),
      sheet: rowString(r['sheet']),
      cellRange: rowString(r['cell_range']),
      sequence: rowInt(r['sequence']) ?? 0,
      tokenCount: rowInt(r['token_count']),
      chunkHash: r['chunk_hash'] as String,
    );
    return (chunk, rowString(r['__file_name']) ?? '未知文件');
  }

  /// 执行 [body]，把任何异常归一化为 [StorageError]（不泄漏 `SqliteException`）。
  T _guard<T>(String code, T Function() body) {
    try {
      return body();
    } catch (e) {
      if (e is StorageError) rethrow;
      throw normalizeStorageError(code, e);
    }
  }
}
