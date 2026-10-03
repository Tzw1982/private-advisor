/// `PDF` 文本解析器（纯 Dart，**尽力而为**）。
///
/// 能力边界（第 3 轮架构设计 §1.2 / 裁定 #1，**明确不静默**）：
/// - 解压内容流（`FlateDecode`，zlib）+ 提取 `BT … ET` 文本算子中的字面串 `( … )`；
/// - 对**扫描件 / 非标准编码 / 复杂版式**可能提不到文本 → **抛明确错误**（含原因），
///   由上层记该文件 `failed`，不阻断整批；OCR / 外部工具列 P1。
library;

import 'dart:convert';
import 'dart:io';

import '../domain/common.dart';
import '../domain/knowledge.dart';

class PdfTextParser implements DocumentParser {
  const PdfTextParser();

  @override
  String get name => 'pdf-text';

  @override
  String get version => '1.0.0';

  @override
  Set<String> get supportedExtensions => {'.pdf'};

  @override
  Future<ParsedDocument> parse(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw KnowledgeError('kb.file_missing', '文件不存在：$filePath');
    }
    final bytes = await file.readAsBytes();

    // 头部校验：非 PDF → 明确失败。
    if (bytes.length < 5 || latin1.decode(bytes.sublist(0, 5)) != '%PDF-') {
      throw const KnowledgeError('kb.pdf.invalid', '不是有效的 PDF（缺少 %PDF 头）');
    }

    final raw = latin1.decode(bytes);
    final decoded = StringBuffer();

    // 内容流：`stream` … `endstream`（用后行断言排除 `endstream` 里的 `stream`）。
    final streamRe = RegExp(r'(?<!end)stream[\r\n]+');
    for (final m in streamRe.allMatches(raw)) {
      final bodyStart = m.end;
      final endIdx = raw.indexOf('endstream', bodyStart);
      if (endIdx < 0) continue;
      final dictStart = raw.lastIndexOf('<<', m.start);
      final dict = dictStart >= 0 ? raw.substring(dictStart, m.start) : '';
      final bodyBytes = latin1.encode(raw.substring(bodyStart, endIdx));
      final text = _decodeStream(bodyBytes, flate: dict.contains('FlateDecode'));
      if (text != null) decoded.write(text);
      decoded.write('\n');
    }

    final blocks = _extractTextBlocks(decoded.toString());
    if (blocks.isEmpty) {
      // 用户可见文案（走查反馈）：给「原因 + 预期」，不是干巴巴的错误码。
      // 错误码保持 'kb.pdf.no_text' 不变（verify_parsers 断言的是 code）。
      throw const KnowledgeError(
        'kb.pdf.no_text',
        '该 PDF 未提取到文字——它可能是扫描件（图片型 PDF）。'
        '文字层提取暂不支持扫描件，OCR 能力在产品规划中',
      );
    }

    final pageCount = RegExp(r'/Type\s*/Page(?![s])').allMatches(raw).length;
    return ParsedDocument(
      blocks: blocks,
      pageCount: pageCount == 0 ? null : pageCount,
      parser: name,
      parserVersion: version,
    );
  }

  /// 解压内容流：`FlateDecode` → zlib；失败或未压缩 → 原样尝试。
  static String? _decodeStream(List<int> data, {required bool flate}) {
    if (flate) {
      try {
        final out = ZLibDecoder().convert(data);
        return latin1.decode(List<int>.from(out));
      } catch (_) {
        return null; // 解压失败：跳过该流（可能为图片等非文本流）。
      }
    }
    return latin1.decode(data);
  }

  /// 从（已解压的）内容文本中提取 `BT … ET` 内的字面串。
  static List<ParsedBlock> _extractTextBlocks(String content) {
    final blocks = <ParsedBlock>[];
    final bt = RegExp(r'BT([\s\S]*?)ET');
    final str = RegExp(r'\((?:\\.|[^\\()])*\)');
    for (final m in bt.allMatches(content)) {
      final body = m.group(1) ?? '';
      final parts = <String>[];
      for (final s in str.allMatches(body)) {
        parts.add(_unescapePdfString(s.group(0)!));
      }
      final text = parts.join().replaceAll(RegExp(r'[ \t]+'), ' ').trim();
      if (text.isNotEmpty) {
        blocks.add(ParsedBlock(text: text, page: 1));
      }
    }
    return blocks;
  }

  /// 去掉包裹括号并处理 PDF 字面串转义。
  static String _unescapePdfString(String token) {
    final inner = token.substring(1, token.length - 1);
    final buf = StringBuffer();
    for (var i = 0; i < inner.length; i++) {
      final ch = inner[i];
      if (ch != r'\') {
        buf.write(ch);
        continue;
      }
      i++;
      if (i >= inner.length) break;
      final esc = inner[i];
      switch (esc) {
        case 'n':
          buf.write('\n');
        case 'r':
          buf.write('\r');
        case 't':
          buf.write('\t');
        case 'b':
          buf.write('\b');
        case 'f':
          buf.write('\f');
        case '(':
          buf.write('(');
        case ')':
          buf.write(')');
        case r'\':
          buf.write(r'\');
        default:
          // 八进制 \ddd
          if (esc.codeUnitAt(0) >= 0x30 && esc.codeUnitAt(0) <= 0x37) {
            var oct = esc;
            while (oct.length < 3 && i + 1 < inner.length && _isOctal(inner[i + 1])) {
              i++;
              oct += inner[i];
            }
            buf.writeCharCode(int.parse(oct, radix: 8));
          } else {
            buf.write(esc);
          }
      }
    }
    return buf.toString();
  }

  static bool _isOctal(String c) {
    final u = c.codeUnitAt(0);
    return u >= 0x30 && u <= 0x37;
  }
}
