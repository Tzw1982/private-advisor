/// `pptx` 解析器：逐张 `ppt/slides/slideN.xml` 提取 `<a:t>` 文本（纯 Dart）。
library;

import 'package:xml/xml.dart';

import '../domain/common.dart';
import '../domain/knowledge.dart';
import 'ooxml_zip.dart';

class PptxParser implements DocumentParser {
  const PptxParser();

  @override
  String get name => 'pptx';

  @override
  String get version => '1.0.0';

  @override
  Set<String> get supportedExtensions => {'.pptx'};

  @override
  Future<ParsedDocument> parse(String filePath) async {
    final zip = await OoxmlZip.open(filePath);
    final slides = zip
        .fileNames()
        .where((n) => n.startsWith('ppt/slides/slide') && n.endsWith('.xml'))
        .toList()
      ..sort(_byTrailingNumber);

    if (slides.isEmpty) {
      throw const KnowledgeError('kb.pptx.missing', 'pptx 缺少幻灯片（ppt/slides/slideN.xml）');
    }

    final blocks = <ParsedBlock>[];
    for (var i = 0; i < slides.length; i++) {
      final xmlStr = zip.readText(slides[i])!;
      XmlDocument doc;
      try {
        doc = XmlDocument.parse(xmlStr);
      } catch (e) {
        throw KnowledgeError('kb.pptx.xml', '幻灯片 XML 解析失败：$e', e);
      }
      // 逐段落（a:p）拼接 a:t 文本；段落间换行。
      final paras = <String>[];
      for (final p in doc.descendants.whereType<XmlElement>().where((e) => e.name.local == 'p')) {
        final runs = p
            .descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 't')
            .map((e) => e.innerText)
            .join();
        if (runs.trim().isNotEmpty) paras.add(runs.trim());
      }
      final text = paras.join('\n');
      if (text.trim().isEmpty) continue;
      blocks.add(ParsedBlock(text: text.trim(), page: i + 1));
    }

    return ParsedDocument(
      blocks: blocks,
      pageCount: slides.length,
      parser: name,
      parserVersion: version,
    );
  }

  static int _byTrailingNumber(String a, String b) {
    final na = int.tryParse(RegExp(r'slide(\d+)\.xml$').firstMatch(a)?.group(1) ?? '') ?? 0;
    final nb = int.tryParse(RegExp(r'slide(\d+)\.xml$').firstMatch(b)?.group(1) ?? '') ?? 0;
    return na.compareTo(nb);
  }
}
