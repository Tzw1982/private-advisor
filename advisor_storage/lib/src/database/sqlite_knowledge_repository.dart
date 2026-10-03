/// `SqliteKnowledgeRepository`：`KnowledgeRepository` 端口的 SQLite 实现。
///
/// 覆盖六张表：`knowledge_bases` / `knowledge_documents` / `knowledge_chunks` /
/// `chunk_embeddings` / `embedding_models` / `expert_knowledge_bindings`（绑定由
/// `SqliteExpertRepository` 负责，本仓储不涉及）。
///
/// 关键点：
/// - `insertChunks`：批量 + **单事务**（幂等 `ON CONFLICT(id) DO UPDATE`）。
/// - `upsertEmbedding`：**外键陷阱防御** —— `chunk_embeddings.embedding_model_id`
///   外键指向 `embedding_models(id)`，若模型档案尚未落库会外键失败；此处先
///   `INSERT OR IGNORE` 一行占位（`runtime='unknown'`），保证写入不因缺档案而失败。
/// - 所有 SQLite 异常均归一化为 [StorageError]（`storage.knowledge.*`）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support.dart';

class SqliteKnowledgeRepository implements KnowledgeRepository {
  SqliteKnowledgeRepository(this.db);

  final Database db;

  // -------------------------------------------------------------------------
  // 知识库
  // -------------------------------------------------------------------------

  @override
  Future<void> upsertBase(KnowledgeBase base) async {
    _guard('storage.knowledge.upsert_base', () {
      db.execute('''
        INSERT INTO knowledge_bases
          (id,name,description,type,embedding_model_id,index_path,status,
           file_count,chunk_count,created_at,updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          name=excluded.name, description=excluded.description, type=excluded.type,
          embedding_model_id=excluded.embedding_model_id, index_path=excluded.index_path,
          status=excluded.status, file_count=excluded.file_count,
          chunk_count=excluded.chunk_count, updated_at=excluded.updated_at
      ''', [
        base.id, base.name, base.description, base.type, base.embeddingModelId,
        base.indexPath, base.status.name, base.fileCount, base.chunkCount,
        base.createdAt, base.updatedAt,
      ]);
    });
  }

  @override
  Future<KnowledgeBase?> getBase(String id) async {
    final rs = _guard('storage.knowledge.get_base',
        () => db.select('SELECT * FROM knowledge_bases WHERE id = ?', [id]));
    return rs.isEmpty ? null : _base(rs.first);
  }

  @override
  Future<List<KnowledgeBase>> listBases() async {
    final rows = _guard('storage.knowledge.list_bases',
        () => db.select('SELECT * FROM knowledge_bases ORDER BY created_at DESC'));
    return rows.map(_base).toList();
  }

  @override
  Future<void> deleteBase(String id) async {
    // 依赖 FK ON DELETE CASCADE：级联删除 documents → chunks → embeddings → bindings。
    _guard('storage.knowledge.delete_base',
        () => db.execute('DELETE FROM knowledge_bases WHERE id = ?', [id]));
  }

  KnowledgeBase _base(Row r) => KnowledgeBase(
        id: r['id'] as String,
        name: r['name'] as String,
        description: rowString(r['description']),
        type: r['type'] as String? ?? 'local_folder',
        embeddingModelId: rowString(r['embedding_model_id']),
        indexPath: rowString(r['index_path']),
        status: KnowledgeBaseStatus.parse(r['status'] as String?),
        fileCount: rowInt(r['file_count']) ?? 0,
        chunkCount: rowInt(r['chunk_count']) ?? 0,
        createdAt: rowInt(r['created_at'])!,
        updatedAt: rowInt(r['updated_at'])!,
      );

  // -------------------------------------------------------------------------
  // 文档
  // -------------------------------------------------------------------------

  @override
  Future<void> upsertDocument(KnowledgeDocument doc) async {
    // 防御：表级 UNIQUE(knowledge_base_id, file_hash)。服务层已用
    // findDocumentByHash 预判去重；若此处仍撞唯一键，归一化为可读 StorageError。
    _guard('storage.knowledge.upsert_document', () {
      db.execute('''
        INSERT INTO knowledge_documents
          (id,knowledge_base_id,file_name,file_path,file_hash,file_size,mime_type,
           parser,parser_version,status,page_count,folder_id,source_mtime,
           created_at,updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          file_name=excluded.file_name, file_path=excluded.file_path,
          file_hash=excluded.file_hash, file_size=excluded.file_size,
          mime_type=excluded.mime_type, parser=excluded.parser,
          parser_version=excluded.parser_version, status=excluded.status,
          page_count=excluded.page_count, folder_id=excluded.folder_id,
          source_mtime=excluded.source_mtime, updated_at=excluded.updated_at
      ''', [
        doc.id, doc.knowledgeBaseId, doc.fileName, doc.filePath, doc.fileHash,
        doc.fileSize, doc.mimeType, doc.parser, doc.parserVersion, doc.status.name,
        doc.pageCount, doc.folderId, doc.sourceMtime, doc.createdAt, doc.updatedAt,
      ]);
    });
  }

  @override
  Future<List<KnowledgeDocument>> listDocuments(String knowledgeBaseId) async {
    final rows = _guard('storage.knowledge.list_documents', () => db.select(
          'SELECT * FROM knowledge_documents WHERE knowledge_base_id = ? ORDER BY created_at',
          [knowledgeBaseId],
        ));
    return rows.map(_document).toList();
  }

  @override
  Future<KnowledgeDocument?> findDocumentByHash(String knowledgeBaseId, String fileHash) async {
    final rs = _guard('storage.knowledge.find_document_by_hash', () => db.select(
          'SELECT * FROM knowledge_documents WHERE knowledge_base_id = ? AND file_hash = ?',
          [knowledgeBaseId, fileHash],
        ));
    return rs.isEmpty ? null : _document(rs.first);
  }

  @override
  Future<void> deleteDocument(String id) async {
    // 依赖 FK ON DELETE CASCADE：级联删除 chunks → embeddings。
    _guard('storage.knowledge.delete_document',
        () => db.execute('DELETE FROM knowledge_documents WHERE id = ?', [id]));
  }

  KnowledgeDocument _document(Row r) => KnowledgeDocument(
        id: r['id'] as String,
        knowledgeBaseId: r['knowledge_base_id'] as String,
        fileName: r['file_name'] as String,
        filePath: r['file_path'] as String,
        fileHash: r['file_hash'] as String,
        fileSize: rowInt(r['file_size']) ?? 0,
        mimeType: rowString(r['mime_type']),
        parser: rowString(r['parser']),
        parserVersion: rowString(r['parser_version']),
        status: DocumentStatus.parse(r['status'] as String?),
        pageCount: rowInt(r['page_count']),
        folderId: rowString(r['folder_id']),
        sourceMtime: rowInt(r['source_mtime']),
        createdAt: rowInt(r['created_at'])!,
        updatedAt: rowInt(r['updated_at'])!,
      );

  // -------------------------------------------------------------------------
  // 文件夹关联（第 4 轮新增）
  // -------------------------------------------------------------------------

  @override
  Future<void> upsertFolder(KnowledgeBaseFolder folder) async {
    // 防御：UNIQUE(knowledge_base_id, folder_path)——folder_path 存比较键（小写），
    // 大小写变体重复关联在 DB 层被拦截；服务层已预判并归一化为 KnowledgeError。
    _guard('storage.knowledge.upsert_folder', () {
      db.execute('''
        INSERT INTO knowledge_base_folders
          (id,knowledge_base_id,folder_path,display_path,recursive,last_scan_at,created_at)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          folder_path=excluded.folder_path, display_path=excluded.display_path,
          recursive=excluded.recursive, last_scan_at=excluded.last_scan_at
      ''', [
        folder.id, folder.knowledgeBaseId, folder.folderPath, folder.displayPath,
        boolToInt(folder.recursive), folder.lastScanAt, folder.createdAt,
      ]);
    });
  }

  @override
  Future<KnowledgeBaseFolder?> getFolder(String id) async {
    final rs = _guard('storage.knowledge.get_folder',
        () => db.select('SELECT * FROM knowledge_base_folders WHERE id = ?', [id]));
    return rs.isEmpty ? null : _folder(rs.first);
  }

  @override
  Future<List<KnowledgeBaseFolder>> listFolders(String knowledgeBaseId) async {
    final rows = _guard('storage.knowledge.list_folders', () => db.select(
          'SELECT * FROM knowledge_base_folders WHERE knowledge_base_id = ? ORDER BY created_at',
          [knowledgeBaseId],
        ));
    return rows.map(_folder).toList();
  }

  @override
  Future<void> deleteFolder(String id) async {
    // 只删登记行。folder_id 为逻辑外键（无 DB 级级联），文档处置由服务层
    // unlinkFolder 二选一语义完成——本方法绝不触碰 knowledge_documents。
    _guard('storage.knowledge.delete_folder',
        () => db.execute('DELETE FROM knowledge_base_folders WHERE id = ?', [id]));
  }

  @override
  Future<List<KnowledgeDocument>> listDocumentsByFolder(String folderId) async {
    final rows = _guard('storage.knowledge.list_documents_by_folder', () => db.select(
          'SELECT * FROM knowledge_documents WHERE folder_id = ? ORDER BY created_at',
          [folderId],
        ));
    return rows.map(_document).toList();
  }

  @override
  Future<void> assignDocumentsFolder(List<String> documentIds, String? folderId) async {
    if (documentIds.isEmpty) return;
    _guard('storage.knowledge.assign_documents_folder', () {
      transaction(db, () {
        for (final id in documentIds) {
          db.execute(
            'UPDATE knowledge_documents SET folder_id = ?, updated_at = ? WHERE id = ?',
            [folderId, DateTime.now().millisecondsSinceEpoch, id],
          );
        }
      });
    });
  }

  @override
  Future<void> updateSourceMtime(String documentId, int sourceMtime) async {
    _guard('storage.knowledge.update_source_mtime', () {
      // 文档在对账与回填之间被删（对账竞态）时 UPDATE 命中 0 行——可容忍，
      // 不抛错、不中断整批回填。
      db.execute(
        'UPDATE knowledge_documents SET source_mtime = ? WHERE id = ?',
        [sourceMtime, documentId],
      );
    });
  }

  KnowledgeBaseFolder _folder(Row r) => KnowledgeBaseFolder(
        id: r['id'] as String,
        knowledgeBaseId: r['knowledge_base_id'] as String,
        folderPath: r['folder_path'] as String,
        displayPath: r['display_path'] as String,
        recursive: rowBool(r['recursive']),
        lastScanAt: rowInt(r['last_scan_at']),
        createdAt: rowInt(r['created_at'])!,
      );

  // -------------------------------------------------------------------------
  // 文本块
  // -------------------------------------------------------------------------

  @override
  Future<void> insertChunks(List<KnowledgeChunk> chunks) async {
    if (chunks.isEmpty) return;
    _guard('storage.knowledge.insert_chunks', () {
      transaction(db, () {
        for (final c in chunks) {
          db.execute('''
            INSERT INTO knowledge_chunks
              (id,document_id,parent_chunk_id,text,heading_path,page,sheet,cell_range,
               sequence,token_count,chunk_hash)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              parent_chunk_id=excluded.parent_chunk_id, text=excluded.text,
              heading_path=excluded.heading_path, page=excluded.page, sheet=excluded.sheet,
              cell_range=excluded.cell_range, sequence=excluded.sequence,
              token_count=excluded.token_count, chunk_hash=excluded.chunk_hash
          ''', [
            c.id, c.documentId, c.parentChunkId, c.text, c.headingPath, c.page,
            c.sheet, c.cellRange, c.sequence, c.tokenCount, c.chunkHash,
          ]);
        }
      });
    });
  }

  @override
  Future<List<KnowledgeChunk>> listChunks(String documentId) async {
    final rows = _guard('storage.knowledge.list_chunks', () => db.select(
          'SELECT * FROM knowledge_chunks WHERE document_id = ? ORDER BY sequence',
          [documentId],
        ));
    return rows.map(_chunk).toList();
  }

  @override
  Future<KnowledgeChunk?> getChunk(String id) async {
    final rs = _guard('storage.knowledge.get_chunk',
        () => db.select('SELECT * FROM knowledge_chunks WHERE id = ?', [id]));
    return rs.isEmpty ? null : _chunk(rs.first);
  }

  @override
  Future<void> deleteChunksByDocument(String documentId) async {
    _guard('storage.knowledge.delete_chunks_by_document',
        () => db.execute('DELETE FROM knowledge_chunks WHERE document_id = ?', [documentId]));
  }

  KnowledgeChunk _chunk(Row r) => KnowledgeChunk(
        id: r['id'] as String,
        documentId: r['document_id'] as String,
        parentChunkId: rowString(r['parent_chunk_id']),
        text: r['text'] as String,
        headingPath: rowString(r['heading_path']),
        page: rowInt(r['page']),
        sheet: rowString(r['sheet']),
        cellRange: rowString(r['cell_range']),
        sequence: rowInt(r['sequence'])!,
        tokenCount: rowInt(r['token_count']),
        chunkHash: r['chunk_hash'] as String,
      );

  // -------------------------------------------------------------------------
  // 向量引用
  // -------------------------------------------------------------------------

  @override
  Future<void> upsertEmbedding(ChunkEmbedding embedding) async {
    _guard('storage.knowledge.upsert_embedding', () {
      // 外键陷阱防御：先补齐 embedding_models 占位行，避免 chunk_embeddings 外键失败。
      db.execute('''
        INSERT OR IGNORE INTO embedding_models
          (id,name,version,dimension,runtime,model_path,checksum)
        VALUES (?,?,?,?,?,?,?)
      ''', [
        embedding.embeddingModelId, embedding.embeddingModelId, null,
        embedding.dimension, 'unknown', null, null,
      ]);

      db.execute('''
        INSERT INTO chunk_embeddings
          (chunk_id,embedding_model_id,dimension,vector_ref,created_at)
        VALUES (?,?,?,?,?)
        ON CONFLICT(chunk_id,embedding_model_id) DO UPDATE SET
          dimension=excluded.dimension, vector_ref=excluded.vector_ref,
          created_at=excluded.created_at
      ''', [
        embedding.chunkId, embedding.embeddingModelId, embedding.dimension,
        embedding.vectorRef, embedding.createdAt,
      ]);
    });
  }

  @override
  Future<List<ChunkEmbedding>> listEmbeddings(List<String> chunkIds) async {
    if (chunkIds.isEmpty) return const [];
    final placeholders = List.filled(chunkIds.length, '?').join(',');
    final rows = _guard('storage.knowledge.list_embeddings', () => db.select(
          'SELECT * FROM chunk_embeddings WHERE chunk_id IN ($placeholders)',
          chunkIds,
        ));
    return rows.map(_embedding).toList();
  }

  ChunkEmbedding _embedding(Row r) => ChunkEmbedding(
        chunkId: r['chunk_id'] as String,
        embeddingModelId: r['embedding_model_id'] as String,
        dimension: rowInt(r['dimension'])!,
        vectorRef: r['vector_ref'] as String,
        createdAt: rowInt(r['created_at'])!,
      );

  // -------------------------------------------------------------------------
  // Embedding 模型档案
  // -------------------------------------------------------------------------

  @override
  Future<void> upsertEmbeddingModel(EmbeddingModelProfile model) async {
    _guard('storage.knowledge.upsert_embedding_model', () {
      db.execute('''
        INSERT INTO embedding_models
          (id,name,version,dimension,runtime,model_path,checksum)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          name=excluded.name, version=excluded.version, dimension=excluded.dimension,
          runtime=excluded.runtime, model_path=excluded.model_path, checksum=excluded.checksum
      ''', [
        model.id, model.name, model.version, model.dimension, model.runtime,
        model.modelPath, model.checksum,
      ]);
    });
  }

  @override
  Future<List<EmbeddingModelProfile>> listEmbeddingModels() async {
    final rows = _guard('storage.knowledge.list_embedding_models',
        () => db.select('SELECT * FROM embedding_models ORDER BY name'));
    return rows.map(_embeddingModel).toList();
  }

  EmbeddingModelProfile _embeddingModel(Row r) => EmbeddingModelProfile(
        id: r['id'] as String,
        name: r['name'] as String,
        dimension: rowInt(r['dimension']) ?? 0,
        runtime: r['runtime'] as String? ?? 'unknown',
        version: rowString(r['version']),
        modelPath: rowString(r['model_path']),
        checksum: rowString(r['checksum']),
      );

  // -------------------------------------------------------------------------
  // 内部工具
  // -------------------------------------------------------------------------

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
