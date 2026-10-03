/// `xlsx` 解析器：`xl/sharedStrings.xml` + `xl/worksheets/sheetN.xml`（纯 Dart）。
///
/// 每个 `<row>` 输出一个块：单元格按 `r` 引用排序，以 ` | ` 连接；
/// `sheet` 写工作表名，`cellRange` 写该行区域（如 `A1:C1`）；`page` 写工作表序号。
library;

import 'package:xml/xml.dart';

import '../domain/common.dart';
import '../domain/knowledge.dart';
import 'ooxml_zip.dart';

class XlsxParser implements DocumentParser {
  const XlsxParser();

  @override
  String get name => 'xlsx';

  @override
  String get version => '1.0.0';

  @override
  Set<String> get supportedExtensions => {'.xlsx'};

  @override
  Future<ParsedDocument> parse(String filePath) async {
    final zip = await OoxmlZip.open(filePath);

    final shared = _readSharedStrings(zip);
    final sheetNames = _readSheetNames(zip);
    final worksheets = zip.fileNames().where((n) => n.startsWith('xl/worksheets/') && n.endsWith('.xml')).toList()
      ..sort(_byTrailingNumber);

    if (worksheets.isEmpty) {
      throw const KnowledgeError('kb.xlsx.missing', 'xlsx 缺少工作表（xl/worksheets/sheetN.xml）');
    }

    final blocks = <ParsedBlock>[];
    for (var i = 0; i < worksheets.length; i++) {
      final xmlStr = zip.readText(worksheets[i])!;
      XmlDocument doc;
      try {
        doc = XmlDocument.parse(xmlStr);
      } catch (e) {
        throw KnowledgeError('kb.xlsx.xml', '工作表 XML 解析失败：$e', e);
      }
      final sheetName = i < sheetNames.length ? sheetNames[i] : 'Sheet${i + 1}';

      for (final row in doc.descendants.whereType<XmlElement>().where((e) => e.name.local == 'row')) {
        final cells = <({String ref, String text})>[];
        for (final c in row.children.whereType<XmlElement>().where((e) => e.name.local == 'c')) {
          final ref = _attr(c, 'r') ?? '';
          final text = _cellText(c, shared);
          if (text.trim().isEmpty) continue;
          cells.add((ref: ref, text: text.trim()));
        }
        if (cells.isEmpty) continue;
        cells.sort((a, b) => _refColumns(a.ref).compareTo(_refColumns(b.ref)));
        final range = cells.length == 1 ? cells.first.ref : '${cells.first.ref}:${cells.last.ref}';
        blocks.add(ParsedBlock(
          text: cells.map((e) => e.text).join(' | '),
          sheet: sheetName,
          cellRange: range,
          page: i + 1,
        ));
      }
    }

    return ParsedDocument(
      blocks: blocks,
      pageCount: worksheets.length,
      parser: name,
      parserVersion: version,
    );
  }

  List<String> _readSharedStrings(OoxmlZip zip) {
    final xmlStr = zip.readText('xl/sharedStrings.xml');
    if (xmlStr == null) return const [];
    final doc = XmlDocument.parse(xmlStr);
    return doc
        .descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'si')
        .map((e) => e.innerText)
        .toList();
  }

  List<String> _readSheetNames(OoxmlZip zip) {
    final xmlStr = zip.readText('xl/workbook.xml');
    if (xmlStr == null) return const [];
    final doc = XmlDocument.parse(xmlStr);
    return doc
        .descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'sheet')
        .map((e) => _attr(e, 'name') ?? '')
        .toList();
  }

  String _cellText(XmlElement c, List<String> shared) {
    final type = _attr(c, 't');
    // 内联字符串
    for (final isEl in c.children.whereType<XmlElement>()) {
      if (isEl.name.local == 'is') return isEl.innerText;
    }
    String? raw;
    for (final v in c.children.whereType<XmlElement>()) {
      if (v.name.local == 'v') raw = v.innerText;
    }
    if (raw == null) return '';
    if (type == 's') {
      final idx = int.tryParse(raw.trim());
      if (idx != null && idx >= 0 && idx < shared.length) return shared[idx];
      return '';
    }
    return raw;
  }

  static String? _attr(XmlElement e, String local) {
    for (final a in e.attributes) {
      if (a.name.local == local) return a.value;
    }
    return null;
  }

  /// 单元格列号（字母部分 → 数值），用于行内排序。
  static int _refColumns(String ref) {
    var sum = 0;
    for (final r in ref.runes) {
      if (r >= 0x41 && r <= 0x5A) {
        sum = sum * 26 + (r - 0x40);
      } else {
        break;
      }
    }
    return sum;
  }

  static int _byTrailingNumber(String a, String b) {
    final na = int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(a)?.group(1) ?? '') ?? 0;
    final nb = int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(b)?.group(1) ?? '') ?? 0;
    return na.compareTo(nb);
  }
}
