/// 附件物理存取实现（第 8 轮 T03）。
///
/// **为什么允许 `dart:io` 放在 `advisor_core/application`**（三包铁律的例外，第 4 轮先例）：
/// `application/folder_sync.dart` 的 `FolderScanner` / `DirectoryScanner` 已在本目录使用
/// `dart:io`（沙箱内 `dart run` 可测）。本文件同款：端口 [AttachmentStore] 在
/// `domain/attachment.dart`（零 IO），**实现在此**——core 依然**零 Flutter / 零 SQLite**，
/// SQLite 实现仍只在 `advisor_storage`。
///
/// **内容寻址（架构 §1 裁定 2）**：
/// - 路径 `<root>/<sha256[0:2]>/<sha256>.<ext>`（[AttachmentPolicy.storedRelPath]）；
/// - **同内容复用同一物理文件，不复制两份**（`save` 检测目标已存在即跳过复制）；
/// - 落盘前**二次断言**目标路径必须位于 `<root>` 之内（`AttachmentPolicy.isInsideRoot`），
///   防任何上游脏值把文件写到底目录之外（纵深防御）。
///
/// **归属红线**：物理文件是否删**只由 DB 引用计数**（[referenceCount]）决定，
/// **绝不扫盘**——本类没有任何"遍历目录"代码（QA 可 grep 验证：`listSync` 零出现）。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/attachment.dart';
import '../domain/common.dart';
import 'repositories.dart';

/// 本地文件系统附件存储（内容寻址）。
class LocalAttachmentStore implements AttachmentStore {
  LocalAttachmentStore(this.root, this._attachments);

  /// 附件根目录（`<data>/attachments`）。
  final String root;

  /// 附件仓储（仅用于 [referenceCount] 的 DB 登记计数；**不做任何文件系统扫描**）。
  final AttachmentRepository _attachments;

  @override
  Future<String> save({
    required String sourcePath,
    required String sha256,
    required String fileName,
  }) async {
    final ext = AttachmentPolicy.extensionOf(fileName);
    final rel = AttachmentPolicy.storedRelPath(sha256, ext);
    final dest = p.join(root, rel);

    // 二次断言（防逃逸）：即使上游传入脏 sha / 脏扩展名，也不得写出根目录。
    if (!AttachmentPolicy.isInsideRoot(dest, root)) {
      throw ValidationError(
        'attach.path_escape',
        '附件存储路径越界，已拒绝写入（$dest）',
      );
    }

    final target = File(dest);
    if (target.existsSync()) {
      // 内容寻址复用：同内容已存在 → **跳过复制**（不复制两份）。
      return dest;
    }

    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw StorageError(
        'attach.source_missing',
        '找不到要上传的文件：${AttachmentPolicy.sanitizeFileName(fileName)}',
      );
    }

    try {
      final dir = Directory(p.dirname(dest));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      // 先写临时文件再原子改名：避免"复制一半"的残缺文件被当作已存在内容复用。
      final tmp = File('$dest.part');
      source.copySync(tmp.path);
      if (target.existsSync()) {
        // 并发情形：复制期间别的写入已落好 → 丢弃临时文件，复用既有文件。
        _quietDelete(tmp);
        return dest;
      }
      tmp.renameSync(dest);
      return dest;
    } on AppError {
      rethrow;
    } catch (e) {
      throw StorageError('attach.save', '保存附件失败：${AttachmentPolicy.sanitizeFileName(fileName)}', e);
    }
  }

  @override
  Future<int> referenceCount(String storedPath, {required String excludeId}) =>
      _attachments.countByStoredPath(storedPath, excludeId: excludeId);

  @override
  Future<void> deleteIfUnreferenced(String storedPath) async {
    // 断言在根内：绝不因脏值删掉根目录之外的文件。
    if (!AttachmentPolicy.isInsideRoot(storedPath, root)) {
      throw ValidationError('attach.path_escape', '附件路径越界，已拒绝删除（$storedPath）');
    }
    _quietDelete(File(storedPath));
  }

  @override
  Future<bool> exists(String storedPath) async {
    if (!AttachmentPolicy.isInsideRoot(storedPath, root)) return false;
    try {
      return File(storedPath).existsSync();
    } catch (_) {
      return false;
    }
  }

  static void _quietDelete(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // 删除失败不阻断（文件可能被占用）；不静默到调用方的是"引用计数"判定，
      // 物理残留由后续再次删除消息时重试清理。
    }
  }
}

// ---------------------------------------------------------------------------
// 附件应用服务（两阶段数据流）
// ---------------------------------------------------------------------------

/// 单附件发送结果（**失败隔离**：失败不抛异常，由 UI 标红 + 重试）。
class AttachmentSendOutcome {
  const AttachmentSendOutcome({
    this.attachment,
    required this.pending,
    this.error,
    this.cause,
  });

  /// 成功时非空。
  final Attachment? attachment;

  /// 回传的 pending（失败时已带上 error，UI 直接复用渲染）。
  final PendingAttachment pending;

  /// 失败原因（面向用户；成功为 null）。
  final String? error;

  /// 原始异常（排查用）。
  final Object? cause;

  bool get ok => attachment != null;
}

/// 物理文件清理报告（按 DB 引用计数）。
class AttachmentPurgeReport {
  const AttachmentPurgeReport({required this.purged, required this.kept});

  /// 已删除物理文件的路径。
  final List<String> purged;

  /// 仍被其他消息引用、**保留**物理文件的路径。
  final List<String> kept;
}

/// 附件应用服务（第 8 轮 T03）：**两阶段数据流**（架构 §1.1）。
///
/// - **阶段① 选择**（[AttachmentService.draft]）：**纯校验，不落盘不落库**——
///   超限 / 类型不符 → `rejected`，**明确报错不静默**（调用方必须展示原因）；
/// - **阶段② 发送**（[AttachmentService.send]）：读源文件 → 计 sha256 →
///   [AttachmentStore.save]（内容寻址，已存在则**跳过复制**）→ 落库。
///
/// **失败隔离（架构 §1.1 / 共享约定 4）**：单个附件失败**不影响消息已发出**——
/// [send] 不抛异常，返回带 error 的结果，UI 标红 + 重试；**绝不**让附件失败把消息也拖没。
///
/// **不预复制（共享约定 11）**：选择阶段不碰文件系统；"选了又取消"因此**不可能**产生孤儿文件。
/// > 实现位置说明：本类含 IO（读源文件算 sha256），故与 [LocalAttachmentStore] 同置
/// > `application/attachment_store.dart`（`application/services.dart` 保持零 `dart:io`）。
class AttachmentService {
  AttachmentService(this._repos, this._store);

  final Repositories _repos;
  final AttachmentStore _store;

  /// 阶段①：**纯校验**（不落盘不落库）。
  ///
  /// 通过 → `status = ready`；不通过 → `status = rejected` 且带明确原因。
  static PendingAttachment draft({
    required String sourcePath,
    required String fileName,
    required int sizeBytes,
  }) {
    final safeName = AttachmentPolicy.sanitizeFileName(fileName);
    final reason = AttachmentPolicy.validate(fileName: fileName, sizeBytes: sizeBytes);
    return PendingAttachment(
      id: Ids.next('att'),
      sourcePath: sourcePath,
      fileName: safeName,
      sizeBytes: sizeBytes,
      kind: AttachmentPolicy.kindOf(fileName),
      mimeType: AttachmentPolicy.mimeTypeOf(fileName),
      status: reason == null ? PendingAttachmentStatus.ready : PendingAttachmentStatus.rejected,
      error: reason,
    );
  }

  /// 阶段②：save（内容寻址）+ insert。**失败隔离，不抛异常**。
  Future<AttachmentSendOutcome> send({
    required String messageId,
    required PendingAttachment pending,
  }) async {
    if (pending.status == PendingAttachmentStatus.rejected) {
      return AttachmentSendOutcome(
        attachment: null,
        pending: pending,
        error: pending.error ?? '该附件不符合上传要求',
      );
    }

    // ① 读源文件 + 计 sha256（发送阶段才读；选择阶段不预复制）。
    final List<int> bytes;
    try {
      final f = File(pending.sourcePath);
      if (!f.existsSync()) {
        return _failed(pending, '找不到要上传的文件：${pending.fileName}');
      }
      bytes = f.readAsBytesSync();
    } catch (e) {
      return _failed(pending, '读取文件失败：${pending.fileName}', e);
    }

    // ② 选择阶段之后文件可能被改动 → 复验大小（内容寻址的 sha 以**实际字节**为准）。
    if (bytes.length > AttachmentPolicy.kMaxAttachmentBytes) {
      return _failed(
        pending,
        '文件 ${pending.fileName} 为 ${AttachmentPolicy.formatBytes(bytes.length)}，'
        '超过 ${AttachmentPolicy.formatBytes(AttachmentPolicy.kMaxAttachmentBytes)} 上限',
      );
    }

    final sha = sha256.convert(bytes).toString();

    // ③ 内容寻址保存（同内容已存在 → 跳过复制）。
    final String storedPath;
    try {
      storedPath = await _store.save(
        sourcePath: pending.sourcePath,
        sha256: sha,
        fileName: pending.fileName,
      );
    } on AppError catch (e) {
      return _failed(pending, e.message, e);
    } catch (e) {
      return _failed(pending, '保存附件失败：${pending.fileName}', e);
    }

    // ④ 落库。
    final attachment = Attachment(
      id: pending.id,
      messageId: messageId,
      kind: pending.kind,
      fileName: pending.fileName,
      storedPath: storedPath,
      sha256: sha,
      sizeBytes: bytes.length,
      mimeType: pending.mimeType,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      await _repos.attachments.insertAttachment(attachment);
    } on AppError catch (e) {
      // 落库失败：物理文件已写，但无 DB 行引用 → 立即按"无引用"清理，避免孤儿。
      try {
        await _store.deleteIfUnreferenced(storedPath);
      } catch (_) {
        // 清理失败不掩盖原始错误。
      }
      return _failed(pending, '保存附件记录失败：${pending.fileName}', e);
    } catch (e) {
      return _failed(pending, '保存附件记录失败：${pending.fileName}', e);
    }

    return AttachmentSendOutcome(
      attachment: attachment,
      pending: pending.copyWith(status: PendingAttachmentStatus.ready),
    );
  }

  /// 删除消息后：按 **DB 引用计数**清理"再无任何消息引用"的物理文件。
  ///
  /// **归属红线**：只用 `countByStoredPath`（DB 登记计数）判定，**绝不扫盘**；
  /// 同一路径被多条记录共享时只清一次。
  Future<AttachmentPurgeReport> purgeUnreferenced(Iterable<String> storedPaths) async {
    final purged = <String>[];
    final kept = <String>[];
    final seen = <String>{};
    for (final path in storedPaths) {
      if (!seen.add(path)) continue; // 同内容多行 → 只判一次
      final remaining = await _store.referenceCount(path, excludeId: '');
      if (remaining == 0) {
        await _store.deleteIfUnreferenced(path);
        purged.add(path);
      } else {
        kept.add(path);
      }
    }
    return AttachmentPurgeReport(purged: purged, kept: kept);
  }

  /// 查询某消息的附件。
  Future<List<Attachment>> forMessage(String messageId) =>
      _repos.attachments.listAttachmentsByMessage(messageId);

  /// **批量**查询多条消息的附件（防 N+1；消息流一次取全）。
  Future<List<Attachment>> forMessages(List<String> messageIds) =>
      _repos.attachments.listAttachmentsByMessages(messageIds);

  AttachmentSendOutcome _failed(
    PendingAttachment pending,
    String message, [
    Object? cause,
  ]) =>
      AttachmentSendOutcome(
        attachment: null,
        pending: pending.copyWith(
          status: PendingAttachmentStatus.failed,
          error: message,
        ),
        error: message,
        cause: cause,
      );
}
