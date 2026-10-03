/// 知识库「文件夹关联」：扫描 / 增量对账 / 同步编排（第 4 轮设计 §1.2、§1.3、§4）。
///
/// 三部分：
/// - [FolderScanner]：递归扫描 + 过滤（复用 `DirectoryScanner.isIgnored` 规则），
///   只 stat、零内容读取；
/// - [FolderDiffCalculator]：**纯决策逻辑**的增量对账（mtime+size 预筛 + sha256 确认），
///   内容哈希经 [FolderDiffCalculator.compute] 的 `readHash` 回调注入（纯函数可测）；
/// - [FolderSyncService]：编排——link / unlink（二选一）/ backfill / planRescan →
///   executeRescan 两阶段，复用 `KnowledgeService.importDocument` / `deleteDocument`
///   全链（解析→分块→索引→统计），**不新写任何 FTS / 向量路径**（共享约定 #6）。
///
/// **三条防线**（全部落在本服务，UI 只负责展示确认）：
/// 1. 失联检测（扫描前置）：文件夹不存在 → 重扫中止、零删除，`abortedReason='folder_missing'`；
/// 2. 大比例删除确认：deleted ≥50% 或 ≥20 → `needsConfirmation=true` 只出计划，
///    未携 `confirmDeletes: true` 执行则抛 `kb.folder.abort_deletes`；
/// 3. 删除铁律：同步路径只允许对精确文档 id 逐个调用 `deleteDocument`
///    （它已级联 chunks → embeddings → FTS → vectorStore）；按知识库整体批删的
///    仓储入口在本文件中**零出现**（QA grep 验证）。
///
/// **归属铁律**（§1.1）：归属判定 = `folder_id` 登记事实（`WHERE folder_id = ?`），
/// 删除路径**严禁路径前缀匹配**；前缀匹配只允许出现在补绑回填（只增不删）与
/// 重扫对账键。孤儿文档（`folder_id IS NULL`）任何同步路径绝对不碰。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/common.dart';
import '../domain/knowledge.dart';
import '../domain/path_canon.dart';
import 'import_batch.dart' show DirectoryScanner, kMaxImportBytes;
import 'repositories.dart';
import 'services.dart';

// ---------------------------------------------------------------------------
// 扫描器
// ---------------------------------------------------------------------------

/// 文件夹扫描结果：受支持的文件 stat + 计划阶段拒绝项（超大小上限）。
class FolderScanResult {
  const FolderScanResult({required this.files, required this.rejections});

  final List<ScannedFileStat> files;
  final List<ScanRejection> rejections;
}

/// 关联文件夹扫描器（递归 + 过滤隐藏/临时文件 + 扩展名过滤 + 50MB 上限）。
abstract final class FolderScanner {
  /// 扫描单个关联文件夹。
  ///
  /// - [folderPath]：文件夹路径（用 `displayPath` 原样路径做 IO）；
  /// - [supportedExtensions]：解析器并集（小写、含点，如 `.md`）；
  /// - [recursive]：是否递归（第 4 轮 UI 固定 true）；
  /// - 忽略规则复用 [DirectoryScanner.isIgnored]（`.` 开头、`~$`、Thumbs.db 等）；
  /// - 单文件超过 [maxBytes] → 进 [FolderScanResult.rejections]（不进 diff）。
  static FolderScanResult scan(
    String folderPath, {
    required Set<String> supportedExtensions,
    bool recursive = true,
    int maxBytes = kMaxImportBytes,
  }) {
    final files = <ScannedFileStat>[];
    final rejections = <ScanRejection>[];
    _scanDir(Directory(folderPath), recursive, supportedExtensions, maxBytes, files, rejections);
    return FolderScanResult(files: files, rejections: rejections);
  }

  static void _scanDir(
    Directory dir,
    bool recursive,
    Set<String> supportedExtensions,
    int maxBytes,
    List<ScannedFileStat> files,
    List<ScanRejection> rejections,
  ) {
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return; // 无权限等：跳过该目录，不阻断整批。
    }
    for (final e in entries) {
      final name = _baseName(e.path);
      if (DirectoryScanner.isIgnored(name)) continue;
      if (e is Directory) {
        if (recursive) _scanDir(e, recursive, supportedExtensions, maxBytes, files, rejections);
        continue;
      }
      if (e is! File) continue;
      FileStat stat;
      try {
        stat = e.statSync();
      } catch (_) {
        continue; // stat 失败：本周期跳过该文件（不删除既有文档）。
      }
      final ext = DirectoryScanner.extensionOf(name);
      if (!supportedExtensions.contains(ext)) continue;
      if (stat.size > maxBytes) {
        rejections.add(ScanRejection(
          path: e.path,
          name: name,
          reason: '超过 ${maxBytes ~/ (1024 * 1024)}MB 上限（${stat.size} 字节）',
        ));
        continue;
      }
      files.add(ScannedFileStat(
        path: e.path,
        name: name,
        sizeBytes: stat.size,
        mtimeMs: stat.modified.millisecondsSinceEpoch,
      ));
    }
  }

  static String _baseName(String path) {
    final i1 = path.lastIndexOf('/');
    final i2 = path.lastIndexOf(r'\');
    final i = i1 > i2 ? i1 : i2;
    return i < 0 ? path : path.substring(i + 1);
  }
}

// ---------------------------------------------------------------------------
// 增量对账（纯决策逻辑）
// ---------------------------------------------------------------------------

/// 一次对账的判定结果（按 §1.2 五规则产出，deleted 为精确 id 列表）。
class FolderDiff {
  const FolderDiff({
    required this.added,
    required this.updated,
    required this.deleted,
    required this.unchanged,
  });

  /// 新增文件（走导入链）。
  final List<ScannedFileStat> added;

  /// 内容变化（sha 不同 / failed 重试）→ 执行时删旧重建。
  final List<DocumentChange> updated;

  /// 既有文档（folder_id 匹配）路径在文件系统不存在 → 精确删除列表。
  final List<DocumentChange> deleted;

  /// 未变文档（含 mtime 漂移但 sha 确认未变的）→ 执行时回填 source_mtime。
  final List<DocumentChange> unchanged;
}

/// 增量对账计算器（§1.2 规则，按序短路）。
///
/// **纯决策逻辑**：内容哈希经 [compute] 的 `readHash` 注入（生产 = 读文件算 sha256；
/// 测试可注入假哈希函数）。对账键 = [folderKey]（存储原样、比较用键——路径三律）。
abstract final class FolderDiffCalculator {
  /// 对账。[files] 为扫描结果；[existing] 为 `folder_id` 精确命中的既有文档。
  ///
  /// 规则（按序短路）：
  /// ① 路径（比较键）不在 [existing] → added；
  /// ② size == fileSize && mtime == source_mtime && status == indexed → unchanged（零读取）；
  /// ③ 否则 `readHash` 确认：hash 相同 → unchanged（mtime 漂移不算更新）；不同 → updated；
  /// ④ status == failed 且文件在 → 一律按 updated 重试导入；
  /// ⑤ 既有文档路径在文件系统不存在 → deleted（精确 id）。
  ///
  /// `readHash` 返回 `null`（文件读取失败，如被占用）→ **保守按 unchanged 处理**
  /// （宁可漏检一次更新，绝不因读取抖动误删/误改）。
  static FolderDiff compute({
    required List<ScannedFileStat> files,
    required List<KnowledgeDocument> existing,
    required String? Function(String path) readHash,
  }) {
    // 既有文档：比较键 → 文档（先到先得，防同键重复覆盖）。
    final existingByKey = <String, KnowledgeDocument>{};
    for (final doc in existing) {
      existingByKey.putIfAbsent(folderKey(doc.filePath), () => doc);
    }
    // 文件系统：比较键 → stat。
    final fsByKey = <String, ScannedFileStat>{};
    for (final f in files) {
      fsByKey.putIfAbsent(folderKey(f.path), () => f);
    }

    final added = <ScannedFileStat>[];
    final updated = <DocumentChange>[];
    final unchanged = <DocumentChange>[];

    for (final entry in fsByKey.entries) {
      final f = entry.value;
      final doc = existingByKey[entry.key];
      // ① 新增
      if (doc == null) {
        added.add(f);
        continue;
      }
      final change = DocumentChange(
        documentId: doc.id,
        fileName: doc.fileName,
        filePath: f.path,
        fileSize: f.sizeBytes,
        mtimeMs: f.mtimeMs,
      );
      // ④ failed → 一律按 updated 重试（优先于 ②③；文件仍在磁盘才重试）。
      if (doc.status == DocumentStatus.failed) {
        updated.add(change);
        continue;
      }
      // ② mtime+size 快速路径（零内容读取）。
      if (f.sizeBytes == doc.fileSize &&
          f.mtimeMs == doc.sourceMtime &&
          doc.status == DocumentStatus.indexed) {
        unchanged.add(change);
        continue;
      }
      // ③ sha256 确认（mtime/size 变了才走到这里）。
      final hash = readHash(f.path);
      if (hash == null || hash == doc.fileHash) {
        // 读取失败或内容未变（mtime 漂移不算更新）→ unchanged。
        unchanged.add(change);
        continue;
      }
      updated.add(change);
    }

    // ⑤ deleted：既有文档（folder_id 匹配）的路径在文件系统不存在 → 精确列表。
    final deleted = <DocumentChange>[];
    for (final entry in existingByKey.entries) {
      if (fsByKey.containsKey(entry.key)) continue;
      final doc = entry.value;
      deleted.add(DocumentChange(
        documentId: doc.id,
        fileName: doc.fileName,
        filePath: doc.filePath,
        fileSize: doc.fileSize,
        mtimeMs: doc.sourceMtime ?? 0,
      ));
    }

    return FolderDiff(
      added: added,
      updated: updated,
      deleted: deleted,
      unchanged: unchanged,
    );
  }
}

// ---------------------------------------------------------------------------
// 同步编排服务
// ---------------------------------------------------------------------------

/// 文件夹关联同步服务（link / unlink / backfill / 两阶段重扫）。
///
/// 依赖：[KnowledgeService]（复用 importDocument / deleteDocument 全链）与
/// [Repositories]（folder 登记读写）。防线 2 阈值 [deleteRatioThreshold] /
/// [deleteCountThreshold] 可调（设计 §1.3 回退项）。
class FolderSyncService {
  FolderSyncService(
    this._repos, {
    required KnowledgeService knowledge,
    this.deleteRatioThreshold = 0.5,
    this.deleteCountThreshold = 20,
  }) : _knowledge = knowledge;

  final Repositories _repos;
  final KnowledgeService _knowledge;

  /// 防线 2 阈值：删除占比（deleted / max(既有,1)）。
  final double deleteRatioThreshold;

  /// 防线 2 阈值：删除绝对数。
  final int deleteCountThreshold;

  /// 受支持扩展名集合（从解析器并集派生——单一事实来源）。
  Set<String> get supportedExtensions {
    final out = <String>{};
    for (final p in _knowledge.parsers) {
      out.addAll(p.supportedExtensions);
    }
    return out;
  }

  // -- 只读查询（UI 只调用应用服务，不直接触碰仓储） --------------------------

  /// 列出某知识库的全部关联文件夹（按创建时间）。
  Future<List<KnowledgeBaseFolder>> listFolders(String knowledgeBaseId) =>
      _repos.knowledge.listFolders(knowledgeBaseId);

  /// 列出某关联文件夹名下的文档（folder_id 登记事实；UI 弹窗精确计数用）。
  Future<List<KnowledgeDocument>> listDocumentsByFolder(String folderId) =>
      _repos.knowledge.listDocumentsByFolder(folderId);

  // -- 关联（link） -----------------------------------------------------------

  /// 关联一个本地文件夹到知识库（新建登记行，比较键去重）。
  ///
  /// 抛 [KnowledgeError]：
  /// - `kb.folder.missing`：文件夹不存在（防线 1 复用）；
  /// - `kb.folder.duplicate`：同库重复关联（大小写变体也被拦截）。
  Future<KnowledgeBaseFolder> linkFolder(
    String knowledgeBaseId,
    String folderPath, {
    bool recursive = true,
  }) async {
    final trimmed = folderPath.trim();
    if (trimmed.isEmpty) {
      throw const KnowledgeError('kb.folder.missing', '文件夹路径为空');
    }
    final dir = Directory(trimmed);
    if (!dir.existsSync()) {
      throw KnowledgeError('kb.folder.missing', '找不到文件夹：$trimmed');
    }
    final key = folderKey(trimmed);
    final existing = await _repos.knowledge.listFolders(knowledgeBaseId);
    final dup = existing.where((f) => f.folderPath == key).toList();
    if (dup.isNotEmpty) {
      throw KnowledgeError('kb.folder.duplicate', '该文件夹已关联本知识库：${dup.first.displayPath}');
    }
    final folder = KnowledgeBaseFolder(
      id: Ids.next('kbf'),
      knowledgeBaseId: knowledgeBaseId,
      folderPath: key,
      displayPath: trimmed,
      recursive: recursive,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _repos.knowledge.upsertFolder(folder);
    return folder;
  }

  // -- 断开（unlink，二选一语义；主理人裁定） ---------------------------------

  /// 断开关联文件夹。
  ///
  /// - [keepDocuments] = true（**默认**「仅解除关联」）：删登记行 + 文档 folder_id
  ///   置 NULL——内容保留、可检索，转为孤儿文档（不再被重扫管理，可补绑认领）；
  /// - [keepDocuments] = false（「解除并删除已索引内容」）：删登记行 + 按 folder_id
  ///   **精确列表**逐个 `deleteDocument`（级联 chunks → embeddings → FTS →
  ///   vectorStore）。UI 必须先显示精确计数并二次确认。
  ///
  /// 两条路径均**绝不动** `folder_id IS NULL` 的既有孤儿文档。
  Future<UnlinkResult> unlinkFolder(String folderId, {required bool keepDocuments}) async {
    final folder = await _repos.knowledge.getFolder(folderId);
    if (folder == null) {
      throw const KnowledgeError('kb.folder.missing', '关联记录不存在（可能已断开）');
    }
    final docs = await _repos.knowledge.listDocumentsByFolder(folderId);
    if (keepDocuments) {
      await _repos.knowledge.assignDocumentsFolder(docs.map((d) => d.id).toList(), null);
      await _repos.knowledge.deleteFolder(folderId);
      return UnlinkResult(keepDocuments: true, affectedDocuments: docs.length);
    }
    // 删除路径：精确 id 逐个删（防线 3 铁律；删除数 == folder_id 命中数）。
    for (final d in docs) {
      await _knowledge.deleteDocument(d.id);
    }
    await _repos.knowledge.deleteFolder(folderId);
    return UnlinkResult(keepDocuments: false, affectedDocuments: docs.length);
  }

  // -- 补绑回填（backfill；一次性、只增不删） ---------------------------------

  /// 补绑回填（§2.3）：把既有孤儿/旧导入文档按路径前缀 + 文件系统在位条件，
  /// 回填 `folder_id`。**只 UPDATE folder_id，绝不删除任何行**。
  ///
  /// 规则：
  /// - 只认领 `folder_id IS NULL` 的文档（先到先得，不覆盖其他关联的归属）；
  /// - 条件 = `key(doc.filePath)` 位于本文件夹前缀之下（带分隔符边界）**且**
  ///   文件当前仍在文件夹内（∈ FS）——文件已被移走的文档不回填（孤儿保护，
  ///   重扫不会把它误判为 deleted）；
  /// - 不回填 source_mtime：旧文档哈希是导入时刻的，回填 mtime 会让快速路径
  ///   跳过一次必要的 sha 对账——首次重扫全量确认由 §1.2 设计明确承担。
  ///
  /// 抛 `kb.folder.missing`：登记行不存在或文件夹失联。
  Future<BackfillResult> backfillFolder(String folderId) async {
    final folder = await _repos.knowledge.getFolder(folderId);
    if (folder == null) {
      throw const KnowledgeError('kb.folder.missing', '关联记录不存在');
    }
    if (!Directory(folder.displayPath).existsSync()) {
      throw KnowledgeError('kb.folder.missing', '找不到文件夹：${folder.displayPath}');
    }
    final scan = FolderScanner.scan(
      folder.displayPath,
      supportedExtensions: supportedExtensions,
      recursive: folder.recursive,
    );
    final fsKeys = scan.files.map((f) => folderKey(f.path)).toSet();

    final allDocs = await _repos.knowledge.listDocuments(folder.knowledgeBaseId);
    final orphans = allDocs.where((d) => d.folderId == null).toList();
    final matchedIds = <String>[];
    for (final doc in orphans) {
      if (!isUnderFolder(doc.filePath, folder.folderPath)) continue;
      if (!fsKeys.contains(folderKey(doc.filePath))) continue; // 文件已移走 → 不认领。
      matchedIds.add(doc.id);
    }
    await _repos.knowledge.assignDocumentsFolder(matchedIds, folderId);
    final unmatched = orphans.length - matchedIds.length;
    return BackfillResult(matched: matchedIds.length, unmatched: unmatched < 0 ? 0 : unmatched);
  }

  // -- 重扫（两阶段：plan → execute） ----------------------------------------

  /// 阶段一：产出重扫计划（**只计划不执行**）。
  ///
  /// 防线 1：`Directory(displayPath).existsSync()` 失败 → 返回
  /// `abortedReason='folder_missing'` 的空计划（**零删除**），由 UI 显著提示
  /// 「找不到关联文件夹，请检查路径」。拔盘 / 断网 / 移动 / 重命名全部被拦截。
  ///
  /// 防线 2：diff 完成后 deleted > 0 且（占比 ≥ [deleteRatioThreshold] 或
  /// 数量 ≥ [deleteCountThreshold]）→ `needsConfirmation=true`，UI 弹窗确认。
  Future<RescanPlan> planRescan(String folderId) async {
    final folder = await _repos.knowledge.getFolder(folderId);
    if (folder == null) {
      throw const KnowledgeError('kb.folder.missing', '关联记录不存在');
    }
    final existing = await _repos.knowledge.listDocumentsByFolder(folderId);

    // —— 防线 1：失联检测（扫描前置，零删除）——
    if (!Directory(folder.displayPath).existsSync()) {
      return RescanPlan(
        folder: folder,
        existingCount: existing.length,
        added: const [],
        updated: const [],
        deleted: const [],
        unchanged: const [],
        abortedReason: 'folder_missing',
      );
    }

    final scan = FolderScanner.scan(
      folder.displayPath,
      supportedExtensions: supportedExtensions,
      recursive: folder.recursive,
    );
    final diff = FolderDiffCalculator.compute(
      files: scan.files,
      existing: existing,
      readHash: _readHash,
    );

    // —— 防线 2：大比例删除确认（先出计划，不执行）——
    final ratio = existing.isEmpty ? 0.0 : diff.deleted.length / existing.length;
    final needsConfirmation = diff.deleted.isNotEmpty &&
        (ratio >= deleteRatioThreshold || diff.deleted.length >= deleteCountThreshold);

    return RescanPlan(
      folder: folder,
      existingCount: existing.length,
      added: diff.added,
      updated: diff.updated,
      deleted: diff.deleted,
      unchanged: diff.unchanged,
      failedFiles: scan.rejections,
      needsConfirmation: needsConfirmation,
      deleteRatio: ratio,
    );
  }

  /// 阶段二：执行重扫计划（逐文件推送 [RescanProgress]；末帧 `done=true`）。
  ///
  /// - `plan.needsConfirmation && !confirmDeletes` → 抛 `kb.folder.abort_deletes`
  ///   （防线 2：未经确认绝不执行删除）；
  /// - updated：先 `deleteDocument(旧id)`（级联清理）→ `importDocument` 走导入链
  ///   重建（落库即带 folder_id + source_mtime）；导入失败按失败隔离计数，不中断；
  /// - deleted：逐个 `deleteDocument`（防线 3：精确 id；除它以外无任何删除入口）；
  /// - added：`importDocument`（内容哈希与库内既有文档重复 → 计 skipped，不夺归属）；
  /// - unchanged：回填 source_mtime（覆盖 mtime 漂移与旧文档 NULL 两种情况）；
  /// - 全部成功后更新 `folder.last_scan_at`。
  Stream<RescanProgress> executeRescan(RescanPlan plan, {bool confirmDeletes = false}) async* {
    if (plan.isAborted) {
      throw const KnowledgeError(
          'kb.folder.missing', '关联文件夹失联，重扫已中止（请检查路径后重试）');
    }
    if (plan.needsConfirmation && !confirmDeletes) {
      throw KnowledgeError(
        'kb.folder.abort_deletes',
        '本次重扫将删除 ${plan.deleted.length} 个文档（占该文件夹文档数的 '
            '${(plan.deleteRatio * 100).toStringAsFixed(0)}%），需用户确认后执行',
      );
    }

    final folder = plan.folder;
    final total = plan.added.length + plan.updated.length + plan.deleted.length +
        plan.failedFiles.length;
    var processed = 0;
    var added = 0;
    var updated = 0;
    var deleted = 0;
    var skipped = 0;
    var failed = 0;

    RescanProgress snap({String? currentFile, bool done = false}) => RescanProgress(
          processed: processed,
          total: total,
          added: added,
          updated: updated,
          deleted: deleted,
          skipped: skipped,
          failed: failed,
          currentFile: currentFile,
          done: done,
        );

    yield snap();

    // 超限文件：计划阶段已拒绝 → 记 failed（不进导入链）。
    for (final r in plan.failedFiles) {
      processed++;
      failed++;
      yield snap(currentFile: r.name);
    }

    // updated：删旧 → 重建（导入失败不中断整批）。
    for (final change in plan.updated) {
      processed++;
      try {
        await _knowledge.deleteDocument(change.documentId);
        final res = await _importFromFs(folder.knowledgeBaseId, change, folder.id);
        if (res) {
          updated++;
        } else {
          skipped++; // 内容与库内其他文档重复 → 不夺归属。
        }
      } catch (_) {
        failed++;
      }
      yield snap(currentFile: change.fileName);
    }

    // deleted：精确 id 逐个删（防线 3 铁律）。
    for (final change in plan.deleted) {
      processed++;
      try {
        await _knowledge.deleteDocument(change.documentId);
        deleted++;
      } catch (_) {
        failed++;
      }
      yield snap(currentFile: change.fileName);
    }

    // added：走导入链（folder_id 落库即登记）。
    for (final f in plan.added) {
      processed++;
      try {
        final res = await _importNew(folder.knowledgeBaseId, f, folder.id);
        if (res) {
          added++;
        } else {
          skipped++; // 与库内既有文档内容重复。
        }
      } catch (_) {
        failed++;
      }
      yield snap(currentFile: f.name);
    }

    // unchanged：回填 source_mtime（mtime 漂移 / 旧文档 NULL 两种情况一并覆盖）。
    for (final change in plan.unchanged) {
      await _repos.knowledge.updateSourceMtime(change.documentId, change.mtimeMs);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    await _repos.knowledge.upsertFolder(folder.copyWith(lastScanAt: now));
    yield snap(done: true);
  }

  /// 便捷封装：plan → （需要确认且未确认则抛错）→ execute → 汇总。
  Future<RescanSummary> rescan(String folderId, {bool confirmDeletes = false}) async {
    final plan = await planRescan(folderId);
    if (plan.isAborted) {
      throw const KnowledgeError('kb.folder.missing', '找不到关联文件夹，请检查路径');
    }
    if (plan.needsConfirmation && !confirmDeletes) {
      throw KnowledgeError(
        'kb.folder.abort_deletes',
        '本次重扫将删除 ${plan.deleted.length} 个文档，需用户确认后执行',
      );
    }
    var added = 0, updated = 0, deleted = 0, skipped = 0, failed = 0;
    await for (final p in executeRescan(plan, confirmDeletes: confirmDeletes)) {
      added = p.added;
      updated = p.updated;
      deleted = p.deleted;
      skipped = p.skipped;
      failed = p.failed;
    }
    return RescanSummary(
      added: added,
      updated: updated,
      deleted: deleted,
      skipped: skipped,
      failed: failed,
      finishedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 读文件算 sha256；读取失败返回 null（对账按保守 unchanged 处理）。
  String? _readHash(String path) {
    try {
      return sha256.convert(File(path).readAsBytesSync()).toString();
    } catch (_) {
      return null;
    }
  }

  /// 从文件系统导入（added / updated 共用）：内容哈希与库内既有文档重复时返回
  /// false（调用方计 skipped），且**不夺走**既有文档的 folder_id 归属。
  Future<bool> _importNew(String kbId, ScannedFileStat f, String folderId) async {
    final bytes = File(f.path).readAsBytesSync();
    final res = await _knowledge.importDocument(
      knowledgeBaseId: kbId,
      filePath: f.path,
      fileName: f.name,
      fileBytes: bytes,
      folderId: folderId,
      sourceMtime: f.mtimeMs,
    );
    // 去重命中的信号：返回文档的路径不是本次文件（服务层返回的是库内既有 doc）。
    return folderKey(res.doc.filePath) == folderKey(f.path);
  }

  Future<bool> _importFromFs(String kbId, DocumentChange change, String folderId) =>
      _importNew(
        kbId,
        ScannedFileStat(
          path: change.filePath,
          name: change.fileName,
          sizeBytes: change.fileSize,
          mtimeMs: change.mtimeMs,
        ),
        folderId,
      );
}
