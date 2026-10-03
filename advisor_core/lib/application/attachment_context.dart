/// 会话附件的「可读内容」桥接（第 9 轮 · 文档阅读 + 图片多模态）。
///
/// 定位：把消息附件（[Attachment]）转换成**送给模型的输入**——
/// - **文档类**：复用知识库导入链**同一批** [DocumentParser] 抽文本
///   （照 `KnowledgeService.parserFor` 的接线方式，**不另造一套**）；
/// - **图片类**：读文件转 base64 data URL（供多模态 content-parts）。
///
/// 硬约束（与第 9 轮任务书逐条对应）：
/// - 单文档注入 ≤ [kMaxDocCharsPerAttachment]（6000）字、单轮（一条用户消息的
///   全部文档）合计 ≤ [kMaxDocCharsPerRound]（12000）字；超限**必须**在注入
///   文本里标注「（已截断，原长 N 字）」，**不许静默丢**；
/// - 单张图片 > [kMaxImageBytesForVision]（4MB）→ **拒绝注入**并给出原因
///   （base64 会把 4MB 放大到约 5.5MB，必爆上游请求体限制，不静默）；
/// - 解析失败 / 解析器缺失 / 读文件失败 → 返回**明确原因**（含错误码），
///   由调用方拼进告知段，**不静默**；
/// - 本文件只依赖 domain + parsers（纯 Dart）；**编排与文案组装留在
///   `application/services.dart`**（告知段文案集中一处，防第二处硬编码）。
library;

import 'dart:convert';
import 'dart:io';

import '../domain/attachment.dart';
import '../domain/common.dart';
import '../domain/knowledge.dart';
import '../parsers/docx_parser.dart';
import '../parsers/legacy_office_parser.dart';
import '../parsers/pdf_text_parser.dart';
import '../parsers/plain_text_parser.dart';
import '../parsers/pptx_parser.dart';
import '../parsers/xlsx_parser.dart';

// ---------------------------------------------------------------------------
// 上限常量（第 9 轮任务书口径）
// ---------------------------------------------------------------------------

/// 单个文档附件注入正文的字符上限。
///
/// 用户反馈 #61：长篇文档动辄数万至数十万字，按 64K 模型时代预留的 6000 字
/// 远远不够。现按模型实际上下文（百万级）与预算推导（[TokenBudget.forContext]）
/// 一并放宽到 3 万字；超限仍在注入文本中标注「（已截断，原长 N 字）」。
const int kMaxDocCharsPerAttachment = 30000;

/// 单轮（一条用户消息的全部文档附件）注入正文的字符总上限。
///
/// 群聊场景下同一份附件会被**每位发言者各读一次**，故上限略高于单篇；
/// 真正的总量护栏在 `TokenBudget.maxTotalGroupBudget`（按模型上下文推导），
/// 超预算会停在该轮而非无声失败。
const int kMaxDocCharsPerRound = 40000;

/// 单张图片走多模态的体积上限（字节）：**> 4MB 拒绝**。
///
/// base64 编码会把体积放大约 1/3（4MB → 约 5.5MB），叠加其余请求体后
/// 极易超出上游（DeepSeek 等）请求体上限而整体失败，故在注入前拦死。
const int kMaxImageBytesForVision = 4 * 1024 * 1024;

/// 附件内容提取的默认解析器集（与知识库导入链同一批实现）。
///
/// 老版 Office（`.doc/.xls/.ppt`）此处**不带** COM 转换器（实现在 `app/`，
/// 依赖本机 Office）→ 命中时返回明确失败原因（见 `LegacyOfficeParser`），
/// 由告知段呈现，**不静默**。
const List<DocumentParser> defaultAttachmentDocumentParsers = [
  PlainTextParser(),
  DocxParser(),
  XlsxParser(),
  PptxParser(),
  PdfTextParser(),
  LegacyOfficeParser(),
];

// ---------------------------------------------------------------------------
// 解析器挑选（与 KnowledgeService.parserFor 同口径）
// ---------------------------------------------------------------------------

/// 按文件名挑选解析器：扩展名小写后缀匹配（与知识库导入链一致）。
DocumentParser? documentParserFor(
    List<DocumentParser> parsers, String fileName) {
  final lower = fileName.toLowerCase();
  for (final parser in parsers) {
    for (final ext in parser.supportedExtensions) {
      if (lower.endsWith(ext)) return parser;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 文档附件 → 注入用正文（含上限控制）
// ---------------------------------------------------------------------------

/// 文档附件的提取结果。
class AttachmentDocText {
  const AttachmentDocText({
    required this.text,
    required this.parserName,
    required this.originalLength,
    required this.truncated,
    required this.failureReason,
  });

  /// 注入用正文；`null` = 未能注入（失败 / 无预算）。调用方判 [ok]。
  final String? text;

  /// 命中的解析器名（失败时为空串）。
  final String parserName;

  /// 解析出的原始长度（字）；失败时为 0。
  final int originalLength;

  /// 是否因上限被截断（注入文本必须标注「已截断，原长 N 字」）。
  final bool truncated;

  /// 失败 / 拒绝的明确原因（[ok] 时为空串）。
  final String failureReason;

  bool get ok => text != null;

  /// 超限标注文案（注入文本内使用）；未截断时为空串。
  String get truncationNote =>
      truncated ? '（已截断，原长 $originalLength 字）' : '';
}

/// 读取一个文档附件的正文，按 [remainingBudget]（本轮剩余预算）与
/// [kMaxDocCharsPerAttachment] 双重上限截断。
///
/// 失败一律返回 `ok == false` + 明确 [AttachmentDocText.failureReason]，
/// **不抛异常**（逐附件失败隔离，不中断本轮生成）。
Future<AttachmentDocText> readDocumentText({
  required Attachment attachment,
  required List<DocumentParser> parsers,
  required int remainingBudget,
}) async {
  final parser = documentParserFor(parsers, attachment.fileName);
  if (parser == null) {
    return const AttachmentDocText(
      text: null,
      parserName: '',
      originalLength: 0,
      truncated: false,
      failureReason: '无法读取正文：当前版本没有可解析该格式的解析器',
    );
  }
  try {
    final doc = await parser.parse(attachment.storedPath);
    final raw = doc.blocks.map((b) => b.text).join('\n\n').trim();
    if (raw.isEmpty) {
      return const AttachmentDocText(
        text: null,
        parserName: '',
        originalLength: 0,
        truncated: false,
        failureReason: '解析成功但未抽出任何文字（可能为扫描件或空文档）',
      );
    }
    final limit = remainingBudget < kMaxDocCharsPerAttachment
        ? remainingBudget
        : kMaxDocCharsPerAttachment;
    if (raw.length <= limit) {
      return AttachmentDocText(
        text: raw,
        parserName: parser.name,
        originalLength: raw.length,
        truncated: false,
        failureReason: '',
      );
    }
    if (limit <= 0) {
      // 本轮总量预算已耗尽：不注入，但**说清楚**（含原长，不静默）。
      return AttachmentDocText(
        text: null,
        parserName: parser.name,
        originalLength: raw.length,
        truncated: false,
        failureReason: '超出本轮附件正文总量上限（$kMaxDocCharsPerRound 字），'
            '未注入；原长 ${raw.length} 字',
      );
    }
    return AttachmentDocText(
      text: raw.substring(0, limit),
      parserName: parser.name,
      originalLength: raw.length,
      truncated: true,
      failureReason: '',
    );
  } catch (e) {
    final reason = e is AppError ? '${e.code} ${e.message}' : '$e';
    return AttachmentDocText(
      text: null,
      parserName: '',
      originalLength: 0,
      truncated: false,
      failureReason: '读取失败：$reason',
    );
  }
}

// ---------------------------------------------------------------------------
// 图片附件 → base64 data URL（含体积门控）
// ---------------------------------------------------------------------------

/// 图片附件的读取结果。
class AttachmentImageData {
  const AttachmentImageData({required this.dataUrl, required this.failureReason});

  /// `data:<mime>;base64,<...>`；`null` = 被拒绝 / 读取失败。调用方判 [ok]。
  final String? dataUrl;

  /// 拒绝 / 失败的明确原因（[ok] 时为空串）。
  final String failureReason;

  bool get ok => dataUrl != null;
}

/// 读取一个图片附件为 data URL。
///
/// 体积 > [kMaxImageBytesForVision]（4MB）→ **拒绝注入**并说明原因
/// （不静默）；读文件失败 → 同样返回明确原因。
Future<AttachmentImageData> readImageDataUrl(Attachment attachment) async {
  if (attachment.sizeBytes > kMaxImageBytesForVision) {
    return AttachmentImageData(
      dataUrl: null,
      failureReason: '体积 ${AttachmentPolicy.formatBytes(attachment.sizeBytes)} '
          '超过 4MB 上限，未发送给模型（base64 会再放大约 1/3）',
    );
  }
  try {
    final bytes = await File(attachment.storedPath).readAsBytes();
    final mime = AttachmentPolicy.mimeTypeOf(attachment.fileName) ?? 'image/png';
    return AttachmentImageData(
      dataUrl: 'data:$mime;base64,${base64Encode(bytes)}',
      failureReason: '',
    );
  } catch (e) {
    return AttachmentImageData(dataUrl: null, failureReason: '读取失败：$e');
  }
}
