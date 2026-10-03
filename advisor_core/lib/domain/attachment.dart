/// 会话附件领域（第 8 轮 · 附件上传）。
///
/// **边界（架构 §2.1 / 共享约定 7）**：
/// - 本文件属 `advisor_core` 的 **domain** —— **零 IO、零 Flutter、零 SQLite**，纯 Dart 可测；
/// - `Attachment` 实体 + `AttachmentPolicy`（**纯函数、表驱动**）+ `AttachmentStore`（**端口**，零 IO）；
/// - 物理存取实现 `LocalAttachmentStore`（`dart:io`）放 `advisor_core/application`（第 4 轮
///   `DirectoryScanner` 同款先例）；`AttachmentRepository`（SQLite）只放 `advisor_storage`；
/// - SQLite 实现**不得**出现在本文件（三包铁律）。
///
/// **硬规则（架构 §1 / 共享约定 1、3、9、10、11）**：
/// - 附件归属**只认 `message_id`**；任何文件系统扫描**不得**参与归属判定；
/// - 物理文件是否删除由 **DB 引用计数**（`countByStoredPath`）决定，**绝不扫盘**；
/// - 白名单 / 20MB 上限 / 文件名安全化 / 路径逃逸拒绝——**不静默**：一律返回明确原因。
library;

import 'common.dart';

// ---------------------------------------------------------------------------
// 附件类型
// ---------------------------------------------------------------------------

/// 附件类别（kind）。
enum AttachmentKind {
  /// 图片（白名单图片集扩展名）。
  image('图片'),

  /// 普通文件（其余白名单扩展名）。
  file('文件');

  const AttachmentKind(this.label);

  /// 中文标签（UI 展示）。
  final String label;

  /// 解析（未知值回退 [file]）。
  static AttachmentKind parse(String? value) => AttachmentKind.values
      .firstWhere((e) => e.name == value, orElse: () => AttachmentKind.file);
}

/// 图片展示适配模式（**二期**放大视图预留，本期未使用）。
enum ImageFit {
  /// 裁切填充。
  cover,

  /// 完整包含。
  contain,
}

// ---------------------------------------------------------------------------
// 附件实体
// ---------------------------------------------------------------------------

/// 消息附件（领域实体）。
///
/// [`sentToModelAt`] / [`width`] / [`height`] / [`pageCount`] 为**二期 vision 预留**，
/// 本期**恒 NULL**（架构 §1.5：MVP 不送 LLM）。
class Attachment {
  const Attachment({
    required this.id,
    required this.messageId,
    required this.kind,
    required this.fileName,
    required this.storedPath,
    required this.sha256,
    required this.sizeBytes,
    this.mimeType,
    this.width,
    this.height,
    this.pageCount,
    this.sentToModelAt,
    required this.createdAt,
  });

  /// `Ids.next('att')` 生成的本地 id。
  final String id;

  /// 所属消息 id（**归属唯一依据**）。
  final String messageId;

  final AttachmentKind kind;

  /// 原始文件名（**已安全化**；展示用）。
  final String fileName;

  /// 内容寻址绝对路径：`<data>/attachments/<sha256[0:2]>/<sha256>.<ext>`。
  final String storedPath;

  /// 内容 sha256 十六进制（小写）。
  final String sha256;

  final int sizeBytes;

  /// MIME 猜测值（本期由白名单扩展名推导；可为 null）。
  final String? mimeType;

  // ---- 二期预留（本期恒 NULL）----
  final int? width;
  final int? height;
  final int? pageCount;
  final int? sentToModelAt;

  final int createdAt;

  Attachment copyWith({
    AttachmentKind? kind,
    String? fileName,
    String? storedPath,
    String? sha256,
    int? sizeBytes,
    String? mimeType,
    int? width,
    int? height,
    int? pageCount,
    int? sentToModelAt,
    int? createdAt,
  }) =>
      Attachment(
        id: id,
        messageId: messageId,
        kind: kind ?? this.kind,
        fileName: fileName ?? this.fileName,
        storedPath: storedPath ?? this.storedPath,
        sha256: sha256 ?? this.sha256,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        mimeType: mimeType ?? this.mimeType,
        width: width ?? this.width,
        height: height ?? this.height,
        pageCount: pageCount ?? this.pageCount,
        sentToModelAt: sentToModelAt ?? this.sentToModelAt,
        createdAt: createdAt ?? this.createdAt,
      );
}

// ---------------------------------------------------------------------------
// 附件策略（纯函数）
// ---------------------------------------------------------------------------

/// 附件策略：白名单 / 上限 / 安全化 / 内容寻址路径 / 校验。
///
/// **全部为纯函数**（无 IO），表驱动、可逐条断言（`tool/verify_round8.dart` 红队用例）。
abstract final class AttachmentPolicy {
  /// 单附件大小上限：**20MB**（小于知识库 50MB——聊天附件应更轻）。
  static const int kMaxAttachmentBytes = 20 * 1024 * 1024;

  /// 图片扩展名集合（`kindOf` 判定 `image` 的依据）。
  static const Set<String> kImageExtensions = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp',
  };

  /// 文档 / 压缩包扩展名集合。
  static const Set<String> kDocumentExtensions = {
    'pdf', 'txt', 'md', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'zip',
  };

  /// 允许上传的全部扩展名（图片 ∪ 文档，不含点、小写）。
  static const Set<String> kAllowedExtensions = {
    ...kImageExtensions,
    ...kDocumentExtensions,
  };

  /// 安全化后的文件名最大长度（超长截断）。
  static const int kMaxFileNameChars = 80;

  /// 扩展名最大长度（防止 `x.averyverylongextension` 之类噪音）。
  static const int kMaxExtensionChars = 10;

  /// Windows 保留设备名（含 COM1–9 / LPT1–9；大小写与尾部点空格不敏感）。
  static const Set<String> kWindowsReservedNames = {
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };

  /// 控制字符（C0 + DEL + C1 区段）。
  static final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F\x80-\x9F]');

  /// 结果尾部的点与空格（Windows "CON.txt." 隐式扩展陷阱）。
  static final RegExp _trailingDotsSpaces = RegExp(r'[. ]+$');

  /// 提取（规范化后的）扩展名：小写、仅字母数字、长度 ≤10；不合法返回空串。
  ///
  /// 取**最后**一个 `.` 之后的内容 —— `x.jpg.exe` 会被判为 `exe`（多扩展名伪装即被拒）。
  static String extensionOf(String fileName) {
    final trimmed = fileName.trim();
    final dot = trimmed.lastIndexOf('.');
    if (dot < 0 || dot == trimmed.length - 1) return '';
    final raw = trimmed.substring(dot + 1);
    if (raw.length > kMaxExtensionChars) return '';
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(raw)) return '';
    return raw.toLowerCase();
  }

  /// 扩展名是否在白名单内。
  static bool isAllowedExtension(String fileName) =>
      kAllowedExtensions.contains(extensionOf(fileName));

  /// 附件类别：图片集扩展名 → `image`，其余白名单 → `file`。
  static AttachmentKind kindOf(String fileName) =>
      kImageExtensions.contains(extensionOf(fileName))
          ? AttachmentKind.image
          : AttachmentKind.file;

  /// MIME 猜测（本期兜底；`null` 表示未知）。
  static String? mimeTypeOf(String fileName) {
    switch (extensionOf(fileName)) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'pdf':
        return 'application/pdf';
      case 'zip':
        return 'application/zip';
      case 'txt':
        return 'text/plain';
      case 'md':
        return 'text/markdown';
      default:
        return null;
    }
  }

  /// 人类可读体积（如 `25.6MB`）。
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)}KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)}MB';
  }

  /// 文件名安全化（**纯字符串操作，不碰文件系统**）。
  ///
  /// 依次去除 / 中和：目录分隔符与冒号、控制字符、`..` 序列、Windows 保留名、
  /// 尾部点与空格、超长（截断至 [kMaxFileNameChars]，保留扩展名）、
  /// 非法扩展名（非字母数字或超长 → 丢弃扩展名）；空结果回退 `file`。
  ///
  /// > 返回值**不含任何路径分隔符**，可直接作为单段文件名使用。
  static String sanitizeFileName(String raw) {
    var s = raw.trim();

    // ① 只取最后一段：把所有路径分隔符替换为 `_`（同时中和 `..` 前缀的穿透尝试）。
    s = s.replaceAll('\\', '_').replaceAll('/', '_');
    // ② 冒号（Windows 盘符 / ADS alternate data stream）。
    s = s.replaceAll(':', '_');
    // ③ 控制字符（NUL、CR、LF、tab、C1 区段）。
    s = s.replaceAll(_controlChars, '');
    // ④ 残留相对路径陷阱。
    s = s.replaceAll('..', '.');

    if (s.trim().isEmpty) return 'file';

    // ⑤ 拆 stem / ext，先判定 Windows 保留名再加 `_` 前缀。
    final rawExt = extensionOf(s);
    final stem = rawExt.isEmpty ? s : s.substring(0, s.length - rawExt.length - 1);
    final stemKey = stem.replaceAll(_trailingDotsSpaces, '').toUpperCase();
    final isReserved = kWindowsReservedNames.contains(stemKey);
    if (isReserved) s = '_$s';

    // ⑥ 去掉结果尾部点 / 空格。
    s = s.replaceAll(_trailingDotsSpaces, '');
    if (s.isEmpty) return 'file';

    // ⑦ 超长截断（保留扩展名）。
    if (s.length > kMaxFileNameChars) {
      final keepExt = extensionOf(s);
      if (keepExt.isEmpty) {
        s = s.substring(0, kMaxFileNameChars);
      } else {
        final budget = kMaxFileNameChars - keepExt.length - 1;
        s = budget <= 0 ? s.substring(0, kMaxFileNameChars) : s.substring(0, budget) + '.$keepExt';
      }
      s = s.replaceAll(_trailingDotsSpaces, '');
      if (s.isEmpty) return 'file';
    }
    return s;
  }

  /// 内容寻址相对路径：`"<sha256[0:2]>/<sha256>.<ext>"`（无扩展名则不带点）。
  ///
  /// 同一 `sha256` **恒得同一路径**（内容寻址去重的地基）。`sha256` 会被
  /// 强制校验为 ≥4 位十六进制，否则抛 [ValidationError]（防脏值拼出逃逸路径）。
  static String storedRelPath(String sha256, String ext) {
    final sha = sha256.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{4,}$').hasMatch(sha)) {
      throw const ValidationError(
        'attach.sha_invalid',
        '附件 sha256 非法（需 ≥4 位十六进制小写）',
      );
    }
    final cleanExt = ext.trim().toLowerCase().replaceAll('.', '');
    if (cleanExt.isEmpty) return '${sha.substring(0, 2)}/$sha';
    return '${sha.substring(0, 2)}/$sha.$cleanExt';
  }

  /// 路径对比规范化（把 `\` 统一为 `/`、去掉多余尾斜杠）。
  static String normalizePath(String path) {
    var s = path.trim().replaceAll('\\', '/');
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 二次断言（防逃逸）：[path] 规范化后必须位于 [root] 之内（或等于 [root]）。
  ///
  /// 这是安全化之后的**兜底防线**——即使上游传入脏值，也不会把附件写到底目录之外。
  static bool isInsideRoot(String path, String root) {
    final p = normalizePath(path);
    final r = normalizePath(root);
    if (r.isEmpty) return false;
    return p == r || p.startsWith('$r/');
  }

  /// 单附件校验（选择阶段调用，**不落盘不落库**）。
  ///
  /// 返回 `null` = 通过；否则返回**明确的人类可读原因**（调用方转 `AppError` 上抛，不静默）。
  /// 不做 IO，因此也不知道文件是否可读——可读性在保存阶段由 [AttachmentStore] 报错。
  static String? validate({
    required String fileName,
    required int sizeBytes,
  }) {
    if (fileName.trim().isEmpty) {
      return '文件名为空，无法上传';
    }
    if (sizeBytes > kMaxAttachmentBytes) {
      final name = sanitizeFileName(fileName);
      return '文件 $name 为 ${formatBytes(sizeBytes)}，超过 '
          '${formatBytes(kMaxAttachmentBytes)} 上限';
    }
    if (sizeBytes < 0) {
      return '文件 ${sanitizeFileName(fileName)} 大小为负，无法上传';
    }
    if (!isAllowedExtension(fileName)) {
      final ext = extensionOf(fileName);
      final name = sanitizeFileName(fileName);
      if (ext.isEmpty) {
        return '文件 $name 没有扩展名，不在允许类型内（图片 / 文档 / zip）';
      }
      return '文件 $name 的类型（.$ext）不在允许范围内（图片 / 文档 / zip）';
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// 选择阶段（pending）视图模型
// ---------------------------------------------------------------------------

/// pending 附件状态（**四态**，架构 §1 裁定 8）。
///
/// - [ready]：通过校验，等待发送；
/// - [uploading]：正在落盘 + 落库（发阶段进行中）；
/// - [failed]：**校验失败或 IO 失败**（红字原因 + 可重试 / 可移除）；
/// - [rejected]：**选择阶段即被拒**（超限 / 类型不符）——**不静默**，调用方必须展示原因。
///
/// 「取消」（pending 从输入框移除）不是状态，而是**从列表移除**该对象。
enum PendingAttachmentStatus {
  ready,
  uploading,
  failed,
  rejected;

  static PendingAttachmentStatus parse(String? value) => PendingAttachmentStatus.values
      .firstWhere((e) => e.name == value, orElse: () => PendingAttachmentStatus.failed);
}

/// pending 附件描述（**阶段① 选择**的产物：不落盘、不落库）。
///
/// 由 `AttachmentService.draft(...)` 产出；发送阶段（阶段②）才 `save` + `insert`。
/// **不预复制**（共享约定 11）：预复制必然产生孤儿文件、清理必然扫盘，而扫盘是归属红线禁的。
class PendingAttachment {
  const PendingAttachment({
    required this.id,
    required this.sourcePath,
    required this.fileName,
    required this.sizeBytes,
    required this.kind,
    required this.status,
    this.mimeType,
    this.error,
  });

  /// 预生成的附件 id（发送阶段直接用作 `Attachment.id`，便于 UI 键控）。
  final String id;

  /// 用户选中的源文件路径（**发送阶段**才读取复制）。
  final String sourcePath;

  /// 安全化后的展示名（原名的安全化结果）。
  final String fileName;

  final int sizeBytes;

  final AttachmentKind kind;

  final PendingAttachmentStatus status;

  final String? mimeType;

  /// 失败 / 拒绝原因（面向用户，**绝不静默**）。
  final String? error;

  bool get isReady => status == PendingAttachmentStatus.ready;
  bool get canRetry => status == PendingAttachmentStatus.failed;
  bool get canRemove => status != PendingAttachmentStatus.uploading;

  PendingAttachment copyWith({
    PendingAttachmentStatus? status,
    String? error,
    String? mimeType,
    int? sizeBytes,
  }) =>
      PendingAttachment(
        id: id,
        sourcePath: sourcePath,
        fileName: fileName ?? this.fileName,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        kind: kind,
        status: status ?? this.status,
        mimeType: mimeType ?? this.mimeType,
        error: error ?? this.error,
      );
}

// ---------------------------------------------------------------------------
// 附件存取端口（core 零 IO）
// ---------------------------------------------------------------------------

/// 附件文件存取端口。
///
/// **实现在 `advisor_core/application`（`LocalAttachmentStore`，`dart:io`）**——
/// 端口本身**零 IO**（core 铁律）。
abstract interface class AttachmentStore {
  /// 保存源文件到**内容寻址**路径；已存在则**跳过复制**（同内容不复制两份）。
  ///
  /// 返回存储绝对路径。任何 IO 异常归一化为 [AppError]。
  Future<String> save({
    required String sourcePath,
    required String sha256,
    required String fileName,
  });

  /// 该存储路径当前被**数据库登记引用**的次数（排除 [excludeId] 自身）。
  ///
  /// 走仓储计数（**不是文件系统扫描**）——归属红线：扫盘禁止参与判定。
  Future<int> referenceCount(String storedPath, {required String excludeId});

  /// 删除物理文件。调用方必须已确认引用计数为 0。
  Future<void> deleteIfUnreferenced(String storedPath);

  /// 存储路径是否已存在（内容寻址去重的快速判据）。
  Future<bool> exists(String storedPath);
}
