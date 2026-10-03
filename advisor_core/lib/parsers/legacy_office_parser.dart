/// 老版 Office（`.doc` / `.xls` / `.ppt`）解析器：依赖注入 [OfficeConverter] 预转换。
///
/// 老二进制复合文档无纯 Dart 解 → 须先经本机 Office（Windows COM）转为
/// `docx` / `xlsx` / `pptx`，再复用同一批 OOXML 解析器（架构设计 §1.2 / §1.3）。
///
/// **无转换器 / 转换器不可用时优雅失败**（抛明确 [KnowledgeError]，不静默、不阻断整批）；
/// 真实 COM 转换路径只能在 Windows 由用户走查（沙箱不可验证）。
library;

import 'dart:io';

import '../domain/common.dart';
import '../domain/knowledge.dart';
import 'docx_parser.dart';
import 'pptx_parser.dart';
import 'xlsx_parser.dart';

class LegacyOfficeParser implements DocumentParser {
  const LegacyOfficeParser({this.converter});

  /// 老格式 → OOXML 转换端口（实现放 `app/`；null = 不可用）。
  final OfficeConverter? converter;

  @override
  String get name => 'legacy-office';

  @override
  String get version => '1.0.0';

  @override
  Set<String> get supportedExtensions => {'.doc', '.xls', '.ppt'};

  @override
  Future<ParsedDocument> parse(String filePath) async {
    final c = converter;
    if (c == null || !c.isAvailable()) {
      throw const KnowledgeError(
        'kb.legacy.no_converter',
        '解析 .doc/.xls/.ppt 需要本机 Office（COM 预转换），当前不可用；'
        '请改用 docx/xlsx/pptx，或在安装 Office 的 Windows 上重试',
      );
    }

    final ext = _extensionOf(filePath);
    final targetDir = Directory.systemTemp.createTempSync('pa_legacy_office_');
    final converted = await c.convertToOoxml(filePath, targetDir.path);
    return _delegateFor(ext).parse(converted);
  }

  static DocumentParser _delegateFor(String ext) {
    switch (ext) {
      case '.doc':
        return const DocxParser();
      case '.xls':
        return const XlsxParser();
      case '.ppt':
        return const PptxParser();
      default:
        throw KnowledgeError('kb.legacy.unsupported', '不支持的老格式：$ext');
    }
  }

  static String _extensionOf(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final idx = name.lastIndexOf('.');
    return idx < 0 ? '' : name.substring(idx).toLowerCase();
  }
}
