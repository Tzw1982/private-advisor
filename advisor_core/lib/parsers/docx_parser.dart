/// `docx` 解析器：`word/document.xml` → 段落文本（纯 Dart）。
///
/// 提取规则：逐 `w:p`（段落，文档序）拼接 `w:t` 文本；`w:tab`→制表符、`w:br`→换行；
/// `w:pStyle` 以 `Heading` 开头视为标题，写入后续段落的 `headingPath`。
library;

import 'package:xml/xml.dart';

import '../domain/common.dart';
import '../domain/knowledge.dart';
import 'ooxml_zip.dart';

class DocxParser implements DocumentParser {
  const DocxParser();

  @override
  String get name => 'docx';

  @override
  String get version => '1.0.0';

  @override
  Set<String> get supportedExtensions => {'.docx'};

  @override
  Future<ParsedDocument> parse(String filePath) async {
    final zip = await OoxmlZip.open(filePath);
    final xmlStr = zip.readText('word/document.xml');
    if (xmlStr == null) {
      throw const KnowledgeError('kb.docx.missing', 'docx 缺少 word/document.xml');
    }

    XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlStr);
    } catch (e) {
      throw KnowledgeError('kb.docx.xml', 'docx 文档 XML 解析失败：$e', e);
    }

    final blocks = <ParsedBlock>[];
    String? heading;

    for (final p in doc.descendants.whereType<XmlElement>().where((e) => e.name.local == 'p')) {
      final text = _paragraphText(p);
      if (text.trim().isEmpty) continue;
      if (_isHeadingParagraph(p)) {
        heading = text.trim();
      }
      blocks.add(ParsedBlock(
        text: text.trim(),
        headingPath: heading,
        page: 1,
      ));
    }

    return ParsedDocument(blocks: blocks, pageCount: null, parser: name, parserVersion: version);
  }

  /// 拼接一个段落内的文本（`w:t` / `w:tab` / `w:br`）。
  static String _paragraphText(XmlElement p) {
    final buf = StringBuffer();
    for (final node in p.descendants.whereType<XmlElement>()) {
      switch (node.name.local) {
        case 't':
          buf.write(node.innerText);
        case 'tab':
          buf.write('\t');
        case 'br':
          buf.write('\n');
      }
    }
    return buf.toString();
  }

  /// 段落是否为标题（`w:pPr/w:pStyle@w:val` 以 `Heading` 开头）。
  static bool _isHeadingParagraph(XmlElement p) {
    for (final child in p.children.whereType<XmlElement>()) {
      if (child.name.local != 'pPr') continue;
      for (final style in child.children.whereType<XmlElement>()) {
        if (style.name.local != 'pStyle') continue;
        final val = _attrLocal(style, 'val');
        if (val != null && val.toLowerCase().startsWith('heading')) return true;
      }
    }
    return false;
  }

  /// 取任意命名空间前缀下 local 名为 [local] 的属性值。
  static String? _attrLocal(XmlElement e, String local) {
    for (final a in e.attributes) {
      if (a.name.local == local) return a.value;
    }
    return null;
  }
}
