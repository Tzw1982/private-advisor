/// Knowledge 领域：四层模型 + 检索端口 + Grounding（V1.3 §12 / §13 / §14 / §17 / §21 / §23）。
///
/// 四层：`KnowledgeBase → Document → Chunk → Embedding`
/// 核心目标：**让"专家回答基于什么"可以被验证。**
library;

import 'common.dart';
import 'expert.dart' show GroundingPolicy;

// ---------------------------------------------------------------------------
// 四层模型
// ---------------------------------------------------------------------------

/// 知识库状态。
enum KnowledgeBaseStatus {
  idle('就绪'),
  indexing('索引中'),
  failed('索引失败');

  const KnowledgeBaseStatus(this.label);
  final String label;

  static KnowledgeBaseStatus parse(String? v) => KnowledgeBaseStatus.values
      .firstWhere((e) => e.name == v, orElse: () => KnowledgeBaseStatus.idle);
}

/// 知识库。
class KnowledgeBase {
  const KnowledgeBase({
    required this.id,
    required this.name,
    this.description,
    this.type = 'local_folder',
    this.embeddingModelId,
    this.indexPath,
    this.status = KnowledgeBaseStatus.idle,
    this.fileCount = 0,
    this.chunkCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String? description;

  /// 一期固定 `local_folder`（本地文件）。
  final String type;

  final String? embeddingModelId;
  final String? indexPath;
  final KnowledgeBaseStatus status;
  final int fileCount;
  final int chunkCount;
  final int createdAt;
  final int updatedAt;

  KnowledgeBase copyWith({
    String? name,
    String? description,
    String? embeddingModelId,
    String? indexPath,
    KnowledgeBaseStatus? status,
    int? fileCount,
    int? chunkCount,
    int? updatedAt,
  }) =>
      KnowledgeBase(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        type: type,
        embeddingModelId: embeddingModelId ?? this.embeddingModelId,
        indexPath: indexPath ?? this.indexPath,
        status: status ?? this.status,
        fileCount: fileCount ?? this.fileCount,
        chunkCount: chunkCount ?? this.chunkCount,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 文档解析状态。
enum DocumentStatus {
  pending('待解析'),
  parsing('解析中'),
  indexed('已索引'),
  failed('解析失败');

  const DocumentStatus(this.label);
  final String label;

  static DocumentStatus parse(String? v) => DocumentStatus.values
      .firstWhere((e) => e.name == v, orElse: () => DocumentStatus.pending);
}

/// 文档。
class KnowledgeDocument {
  const KnowledgeDocument({
    required this.id,
    required this.knowledgeBaseId,
    required this.fileName,
    required this.filePath,
    required this.fileHash,
    required this.fileSize,
    this.mimeType,
    this.parser,
    this.parserVersion,
    this.status = DocumentStatus.pending,
    this.pageCount,
    this.folderId,
    this.sourceMtime,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String knowledgeBaseId;
  final String fileName;
  final String filePath;

  /// 内容哈希，用于同库内去重（UNIQUE(knowledge_base_id, file_hash)）。
  final String fileHash;
  final int fileSize;
  final String? mimeType;
  final String? parser;
  final String? parserVersion;
  final DocumentStatus status;
  final int? pageCount;

  /// 来源关联文件夹（**逻辑外键** → `knowledge_base_folders.id`，无 DB 级 FK）。
  ///
  /// 归属判定 = 本字段**登记事实**（`WHERE folder_id = ?`），严禁路径前缀推断
  /// （第 4 轮设计 §1.1）。`null` = 孤儿文档（旧导入 / 仅解除关联产物）：
  /// 可检索、可补绑，但**任何同步路径都不得触碰**。
  final String? folderId;

  /// 上次对账时源文件的 mtime（毫秒；§1.2 增量快速路径依据）。
  ///
  /// `null` = 旧导入未登记 → 首次重扫对该文档走 sha256 全量对账一次。
  final int? sourceMtime;

  final int createdAt;
  final int updatedAt;

  KnowledgeDocument copyWith({
    DocumentStatus? status,
    String? parser,
    String? parserVersion,
    int? pageCount,
    String? folderId,
    int? sourceMtime,
    int? updatedAt,
  }) =>
      KnowledgeDocument(
        id: id,
        knowledgeBaseId: knowledgeBaseId,
        fileName: fileName,
        filePath: filePath,
        fileHash: fileHash,
        fileSize: fileSize,
        mimeType: mimeType,
        parser: parser ?? this.parser,
        parserVersion: parserVersion ?? this.parserVersion,
        status: status ?? this.status,
        pageCount: pageCount ?? this.pageCount,
        folderId: folderId ?? this.folderId,
        sourceMtime: sourceMtime ?? this.sourceMtime,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 显式清空来源关联（unlink「仅解除关联」路径用——copyWith 的 `??` 语义无法置 null）。
  KnowledgeDocument withFolderCleared({required int updatedAt}) => KnowledgeDocument(
        id: id,
        knowledgeBaseId: knowledgeBaseId,
        fileName: fileName,
        filePath: filePath,
        fileHash: fileHash,
        fileSize: fileSize,
        mimeType: mimeType,
        parser: parser,
        parserVersion: parserVersion,
        status: status,
        pageCount: pageCount,
        folderId: null,
        sourceMtime: sourceMtime,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

/// 文本块。
class KnowledgeChunk {
  const KnowledgeChunk({
    required this.id,
    required this.documentId,
    this.parentChunkId,
    required this.text,
    this.headingPath,
    this.page,
    this.sheet,
    this.cellRange,
    required this.sequence,
    this.tokenCount,
    required this.chunkHash,
  });

  final String id;
  final String documentId;
  final String? parentChunkId;
  final String text;

  /// 标题层级路径，如 `3.2.1 车辆性能参数`。
  final String? headingPath;
  final int? page;
  final String? sheet;
  final String? cellRange;
  final int sequence;
  final int? tokenCount;
  final String chunkHash;

  /// 估算 token 数（中文约 1 字 ≈ 1 token，英文约 4 字符 ≈ 1 token）。
  static int estimateTokens(String text) {
    var cjk = 0;
    var other = 0;
    for (final r in text.runes) {
      if (r >= 0x4E00 && r <= 0x9FFF) {
        cjk++;
      } else {
        other++;
      }
    }
    return cjk + (other / 4).ceil();
  }
}

/// 向量记录（真实向量存 sqlite-vec，此处只存引用）。
class ChunkEmbedding {
  const ChunkEmbedding({
    required this.chunkId,
    required this.embeddingModelId,
    required this.dimension,
    required this.vectorRef,
    required this.createdAt,
  });

  final String chunkId;
  final String embeddingModelId;
  final int dimension;
  final String vectorRef;
  final int createdAt;
}

/// Embedding 模型档案。
class EmbeddingModelProfile {
  const EmbeddingModelProfile({
    required this.id,
    required this.name,
    required this.dimension,
    required this.runtime,
    this.version,
    this.modelPath,
    this.checksum,
  });

  final String id;
  final String name;
  final int dimension;

  /// `onnx`（本地）或 `remote_api`。
  final String runtime;
  final String? version;
  final String? modelPath;
  final String? checksum;

  /// 一期默认：本地 ONNX bge-small-zh（约 100MB，离线可用，内容不出机）。
  static const bgeSmallZh = EmbeddingModelProfile(
    id: 'emb_bge_small_zh',
    name: 'bge-small-zh-v1.5',
    dimension: 512,
    runtime: 'onnx',
    version: '1.5',
  );
}

// ---------------------------------------------------------------------------
// Citation（V1.3 §17 / §22）
// ---------------------------------------------------------------------------

/// 一条知识证据。回答的每个 grounded 断言都应可回溯到 Citation。
class Citation {
  const Citation({
    required this.chunkId,
    required this.documentId,
    required this.fileName,
    required this.text,
    required this.score,
    this.page,
    this.headingPath,
    this.sheet,
    this.cellRange,
  });

  final String chunkId;
  final String documentId;
  final String fileName;
  final String text;
  final double score;
  final int? page;
  final String? headingPath;
  final String? sheet;
  final String? cellRange;

  /// UI 展示：`来源：xxx.docx ｜ 位置：3.2.1 车辆性能参数 ｜ 相关度：0.91`
  String toDisplay() {
    final buf = StringBuffer('来源：$fileName');
    if (headingPath != null && headingPath!.isNotEmpty) {
      buf.write(' ｜ 位置：$headingPath');
    } else if (page != null) {
      buf.write(' ｜ 位置：第 $page 页');
    }
    if (sheet != null) buf.write(' ｜ 工作表：$sheet');
    if (cellRange != null) buf.write(' ｜ 区域：$cellRange');
    buf.write(' ｜ 相关度：${score.toStringAsFixed(2)}');
    return buf.toString();
  }
}

// ---------------------------------------------------------------------------
// 检索端口（V1.3 §13 / §23）
// ---------------------------------------------------------------------------

/// 解析后的文档（解析器输出）。
class ParsedDocument {
  const ParsedDocument({
    required this.blocks,
    this.pageCount,
    this.parser,
    this.parserVersion,
  });

  final List<ParsedBlock> blocks;
  final int? pageCount;
  final String? parser;
  final String? parserVersion;
}

/// 解析出的文本块（含定位信息）。
class ParsedBlock {
  const ParsedBlock({
    required this.text,
    this.headingPath,
    this.page,
    this.sheet,
    this.cellRange,
  });

  final String text;
  final String? headingPath;
  final int? page;
  final String? sheet;
  final String? cellRange;
}

/// 文档解析器端口。
abstract interface class DocumentParser {
  String get name;
  String get version;

  /// 支持的扩展名（小写，含点）。
  Set<String> get supportedExtensions;

  Future<ParsedDocument> parse(String filePath);
}

/// 老版 Office（`.doc` / `.xls` / `.ppt`）→ OOXML 预转换端口。
///
/// 老二进制复合文档**无纯 Dart 解**，须借本机 Office（Windows COM）先转换为
/// `docx` / `xlsx` / `pptx`，再走同一批 OOXML 解析器（第 3 轮架构设计 §1.2）。
///
/// **实现放在 `app/` 基础设施层**（`PowerShellOfficeConverter`，Windows 专属、外部进程、
/// **沙箱内不可验证**）；`advisor_core` 只定义端口，`LegacyOfficeParser` 依赖注入。
abstract interface class OfficeConverter {
  /// 本机是否具备转换能力（Windows 且 Office 可用）。
  bool isAvailable();

  /// 把 [path]（doc/xls/ppt）转换为 OOXML，输出到 [targetDir]，返回新文件路径。
  ///
  /// 转换能力不可用时须抛明确错误（**不静默**）。
  Future<String> convertToOoxml(String path, String targetDir);
}

/// 分块器端口。
abstract interface class Chunker {
  String get name;

  /// 目标块大小（token）。
  int get targetTokens;

  List<KnowledgeChunk> chunk(String documentId, ParsedDocument doc);
}

/// Embedding 模型端口。
abstract interface class EmbeddingModel {
  String get modelId;
  int get dimension;

  Future<List<List<double>>> embed(List<String> texts);

  Future<void> warmUp();
}

/// 检索结果。
class RetrievalHit {
  const RetrievalHit({required this.chunk, required this.score, required this.citation});

  final KnowledgeChunk chunk;
  final double score;
  final Citation citation;
}

/// 向量库端口（上层**不直接**依赖 sqlite-vec）。
abstract interface class VectorStore {
  Future<void> upsert(List<KnowledgeChunk> chunks, List<List<double>> vectors, String modelId);

  Future<List<RetrievalHit>> search(
    List<double> queryVector, {
    required List<String> knowledgeBaseIds,
    int topK = 5,
    double threshold = 0.75,
  });

  Future<void> deleteByDocument(String documentId);

  Future<void> deleteByKnowledgeBase(String knowledgeBaseId);

  Future<void> rebuild(String knowledgeBaseId);

  Future<bool> health();
}

/// 检索覆盖率阈值默认值（第 2 轮实测标定后的产品默认）。
///
/// 语义：`similarity_threshold` 现表示「**查询 bigram 的最低命中比例**」（coverage），
/// 值域 `[0,1]`；与旧向量相似度（cosine）语义不同（见第 2 轮设计 §3.4）。
/// 由旧默认 `0.75` 下调为 `0.5`：长多概念查询在 0.75 下极易 0 命中。
const double kDefaultCoverageThreshold = 0.5;

/// 关键词 / 全文检索端口（FTS5 等实现）。
///
/// 与 [VectorStore]（向量检索）**并列且正交**：
/// - [VectorStore] 承载语义向量检索（未来 ONNX / sqlite-vec）；
/// - [Retriever] 承载关键词 / BM25 检索（当前 FTS5 + 应用层中文 bigram）。
///
/// 契约要点（见第 2 轮设计 §3.4 / §8）：
/// - [search] 的 [threshold] 表示"查询 bigram 的最低命中比例（coverage）"；
/// - 分块文本进出 FTS 索引的唯一分词器是 `ChineseBigram.tokenize`（索引端与查询端共用）；
/// - 索引须随 `insertChunks` / `deleteDocument` / `deleteBase` **同步维护**（由上层编排）。
abstract interface class Retriever {
  /// 为一批分块建立 / 更新索引（**幂等**：同 `chunkId` 先删后插）。
  Future<void> indexChunks(
    List<KnowledgeChunk> chunks, {
    required String knowledgeBaseId,
    required String documentId,
  });

  /// 删除某文档的全部索引项。
  Future<void> deleteByDocument(String documentId);

  /// 删除某知识库的全部索引项。
  Future<void> deleteByKnowledgeBase(String knowledgeBaseId);

  /// 关键词检索：OR 召回 + coverage 过滤，按 `coverage DESC` 排序。
  Future<List<RetrievalHit>> search(
    String query, {
    required List<String> knowledgeBaseIds,
    int topK = 5,
    double threshold = 0.0,
  });

  /// 依据 `knowledge_chunks` 重建某知识库的索引（幂等）。
  Future<void> rebuild(String knowledgeBaseId);

  /// 后端健康探测（FTS5 是否可用）；`false` 时上层应降级。
  Future<bool> health();
}

// ---------------------------------------------------------------------------
// Grounding（V1.3 §14 / §15 / §21）
// ---------------------------------------------------------------------------

/// 严格模式下无命中时的固定回答。
const String kNoAnswerText = '知识库中未找到相关内容。';

/// Grounding 决策结果。
sealed class GroundingDecision {
  const GroundingDecision();
}

/// 正常生成（可带证据，也可无证据）。
class GroundedProceed extends GroundingDecision {
  const GroundedProceed(this.citations);
  final List<Citation> citations;

  bool get hasEvidence => citations.isNotEmpty;
}

/// 严格模式无证据：**不调用 LLM**，直接返回固定回答。
class GroundedNoAnswer extends GroundingDecision {
  const GroundedNoAnswer(this.reason);
  final String reason;
}

/// Grounding 解析器：把 policy + 检索结果收敛为一个明确决策。
///
/// 这是**应用层策略**，不是 prompt 里的一句话（V1.3 §15）。
abstract final class GroundingResolver {
  static GroundingDecision resolve({
    required GroundingPolicy policy,
    required List<Citation> evidence,
  }) {
    switch (policy) {
      case GroundingPolicy.off:
        return const GroundedProceed([]);
      case GroundingPolicy.preferred:
        return GroundedProceed(evidence);
      case GroundingPolicy.strict:
        if (evidence.isEmpty) {
          return const GroundedNoAnswer('未检索到达到阈值的知识片段');
        }
        return GroundedProceed(evidence);
      case GroundingPolicy.localOnly:
        if (evidence.isEmpty) {
          return const GroundedNoAnswer('未检索到达到阈值的知识片段');
        }
        return GroundedProceed(evidence);
    }
  }

  /// 构造 grounded 提示词片段（注入到 system / user 上下文）。
  static String buildEvidenceBlock(List<Citation> citations) {
    if (citations.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln('以下是可引用的知识库片段，请**只依据这些内容**回答，并标注引用编号：')
      ..writeln();
    for (var i = 0; i < citations.length; i++) {
      final c = citations[i];
      buf.writeln('[${i + 1}] ${c.fileName}${c.headingPath == null ? '' : ' · ${c.headingPath}'}');
      buf.writeln(c.text);
      buf.writeln();
    }
    return buf.toString();
  }

  /// 严格模式下的系统约束前缀。
  static const String strictSystemRule =
      '你只能依据提供的知识库片段回答。若片段中没有相关信息，必须直接回答"知识库中未找到相关内容。"，'
      '禁止使用你自己的先验知识，禁止编造。回答末尾用 [n] 标注引用的片段编号。';
}

// ---------------------------------------------------------------------------
// 文件夹关联（第 4 轮）：领域模型
// ---------------------------------------------------------------------------

/// 知识库关联文件夹登记（对应 `knowledge_base_folders` 表）。
class KnowledgeBaseFolder {
  const KnowledgeBaseFolder({
    required this.id,
    required this.knowledgeBaseId,
    required this.folderPath,
    required this.displayPath,
    this.recursive = true,
    this.lastScanAt,
    required this.createdAt,
  });

  final String id;

  /// 所属知识库（DB 级 FK → `knowledge_bases.id`，ON DELETE CASCADE）。
  final String knowledgeBaseId;

  /// **比较键**（`folderKey`，小写规约路径）——UNIQUE(knowledge_base_id, folder_path)
  /// 依据此列拦截大小写变体重复关联。
  final String folderPath;

  /// 用户选择时的**原样路径**（仅供 UI 展示与文件系统 IO——存储原样律）。
  final String displayPath;

  /// 是否递归扫描（第 4 轮 UI 固定 true；关闭递归列 P2）。
  final bool recursive;

  /// 最近一次成功重扫时间（毫秒 epoch）；null = 尚未重扫过。
  final int? lastScanAt;

  final int createdAt;

  KnowledgeBaseFolder copyWith({int? lastScanAt}) => KnowledgeBaseFolder(
        id: id,
        knowledgeBaseId: knowledgeBaseId,
        folderPath: folderPath,
        displayPath: displayPath,
        recursive: recursive,
        lastScanAt: lastScanAt ?? this.lastScanAt,
        createdAt: createdAt,
      );
}

/// 增量对账判定（§1.2 五规则，按序短路）。
enum SyncDecision {
  /// 路径不在既有文档集合 → 新增（走导入链）。
  added('新增'),

  /// 内容 sha256 变化（或 failed 重试）→ 删旧重建。
  updated('更新'),

  /// 既有文档（folder_id 匹配）路径在文件系统不存在 → 删除（精确 id）。
  deleted('删除'),

  /// mtime+size 快速路径命中，或 sha256 确认未变 → 不动（零写入）。
  unchanged('未变');

  const SyncDecision(this.label);
  final String label;
}

/// 重扫计划（`planRescan` 产物，两阶段之一——**只计划不执行**）。
class RescanPlan {
  const RescanPlan({
    required this.folder,
    required this.existingCount,
    required this.added,
    required this.updated,
    required this.deleted,
    this.unchanged = const [],
    this.failedFiles = const [],
    this.needsConfirmation = false,
    this.deleteRatio = 0,
    this.abortedReason,
  });

  /// 关联文件夹登记行。
  final KnowledgeBaseFolder folder;

  /// 该文件夹名下既有文档数（folder_id 精确命中；防线 2 分母）。
  final int existingCount;

  /// 新增文件（路径 + stat）。
  final List<ScannedFileStat> added;

  /// 内容变化文件（既有文档 id → 文件 stat，执行时删旧重建）。
  final List<DocumentChange> updated;

  /// 待删除既有文档（精确 id 列表——防线 3 铁律：只许逐个 deleteDocument）。
  final List<DocumentChange> deleted;

  /// 未变文档（执行时逐个回填 source_mtime；含 mtime 漂移与旧文档 NULL 两种情况）。
  final List<DocumentChange> unchanged;

  /// 未变文档数（= [unchanged].length；UI 摘要用）。
  int get unchangedCount => unchanged.length;

  /// 扫描到但超 50MB 上限的文件（执行阶段跳过并计入 failed）。
  final List<ScanRejection> failedFiles;

  /// 防线 2：大比例删除（deleted/max(既有,1) ≥ 0.5 或 deleted ≥ 20）→ 须确认后执行。
  final bool needsConfirmation;

  /// 删除占比（UI 弹窗展示用）。
  final double deleteRatio;

  /// 防线 1 失联中止原因（非 null = 本次重扫已中止、零删除）。
  /// - `folder_missing`：找不到关联文件夹（拔盘 / 断网 / 移动 / 重命名）。
  final String? abortedReason;

  bool get isAborted => abortedReason != null;
}

/// 扫描到的源文件 stat（重扫对账输入；零内容读取——只 stat）。
class ScannedFileStat {
  const ScannedFileStat({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.mtimeMs,
  });

  /// 文件系统真实路径（原样大小写；对账时另算比较键）。
  final String path;
  final String name;
  final int sizeBytes;

  /// 最后修改时间（毫秒 epoch，与 `source_mtime` 同源同单位）。
  final int mtimeMs;
}

/// 重扫中一个"既有文档 ↔ 源文件"的对账条目。
class DocumentChange {
  const DocumentChange({
    required this.documentId,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.mtimeMs,
  });

  final String documentId;
  final String fileName;
  final String filePath;
  final int fileSize;
  final int mtimeMs;
}

/// 扫描拒绝项（超大小上限等；计划阶段即确定，不进入 diff）。
class ScanRejection {
  const ScanRejection({required this.path, required this.name, required this.reason});

  final String path;
  final String name;
  final String reason;
}

/// 重扫进度（`executeRescan` 逐文件推送）。
class RescanProgress {
  const RescanProgress({
    required this.processed,
    required this.total,
    required this.added,
    required this.updated,
    required this.deleted,
    required this.skipped,
    required this.failed,
    this.currentFile,
    this.done = false,
  });

  final int processed;
  final int total;
  final int added;
  final int updated;
  final int deleted;
  final int skipped;
  final int failed;
  final String? currentFile;
  final bool done;
}

/// 重扫摘要（终态；UI 摘要行：新增X/更新Y/删除Z/跳过W/失败F）。
class RescanSummary {
  const RescanSummary({
    required this.added,
    required this.updated,
    required this.deleted,
    required this.skipped,
    required this.failed,
    required this.finishedAt,
  });

  final int added;
  final int updated;
  final int deleted;
  final int skipped;
  final int failed;
  final int finishedAt;
}

/// 断开文件夹（unlink）结果。
class UnlinkResult {
  const UnlinkResult({required this.keepDocuments, required this.affectedDocuments});

  /// true = 仅解除关联（文档保留为孤儿）；false = 已删除文档。
  final bool keepDocuments;

  /// 受影响文档数（keep=true 时为清空 folder_id 的数量；keep=false 时为删除数量）。
  final int affectedDocuments;
}

/// 补绑回填（backfill）结果：matched = 本次回填数；unmatched = 回填后仍为孤儿的文档数。
class BackfillResult {
  const BackfillResult({required this.matched, required this.unmatched});

  final int matched;
  final int unmatched;
}
