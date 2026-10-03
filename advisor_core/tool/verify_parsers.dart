/// 文档解析器第 3 轮验证脚本（纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_core && dart run tool/verify_parsers.dart`
///
/// 覆盖（T03 完成判据）：
/// - 自造**最小 docx / xlsx / pptx**（`archive` 打包）→ 解析出预期文本；
/// - `txt / md / csv` 纯文本直读；
/// - PDF 走「可提 / 不可提」两分支（含非 PDF 与扫描件式无文本）；
/// - `LegacyOfficeParser` 在无转换器时**优雅失败**，有转换器时委派 OOXML。
library;

import 'dart:convert';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:archive/archive.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架
// ---------------------------------------------------------------------------

int _passed = 0;
int _failed = 0;
final List<String> _failures = [];
String _current = '';

void section(String name) {
  _current = name;
  stdout.writeln('\n── $name ─────────────────────────────');
}

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failed++;
    final msg = '[$_current] $name${detail == null ? '' : '  → $detail'}';
    _failures.add(msg);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void checkEq(String name, Object? actual, Object? expected) =>
    check(name, actual == expected, 'actual=$actual expected=$expected');

// ---------------------------------------------------------------------------
// 自造最小 OOXML 样张
// ---------------------------------------------------------------------------

/// 用 `archive` 打包一组 `路径 → 文本` 为 ZIP 文件。
String _writeZip(Directory dir, String fileName, Map<String, String> entries) {
  final archive = Archive();
  entries.forEach((name, content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  final zipBytes = ZipEncoder().encode(archive)!;
  final path = '${dir.path}${Platform.pathSeparator}$fileName';
  File(path).writeAsBytesSync(zipBytes);
  return path;
}

String _docxXml() => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>技术规格</w:t></w:r></w:p>
<w:p><w:r><w:t>整车整备质量 12000 kg</w:t></w:r></w:p>
<w:p><w:r><w:t>最大总质量 18000 kg</w:t><w:tab/><w:t>轴距 4500 mm</w:t></w:r></w:p>
</w:body>
</w:document>''';

String _sstXml() => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<si><t>项目</t></si><si><t>整备质量</t></si><si><t>12000</t></si>
</sst>''';

String _workbookXml() => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheets><sheet name="参数表" sheetId="1" r:id="rId1"/></sheets>
</workbook>''';

String _sheetXml() => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>
<row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>6000</v></c></row>
</sheetData>
</worksheet>''';

String _slideXml() => '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
       xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
<p:cSld><p:spTree><p:sp><p:txBody>
<a:p><a:r><a:t>第一页标题</a:t></a:r></a:p>
<a:p><a:r><a:t>正文要点一</a:t></a:r></a:p>
</p:txBody></p:sp></p:spTree></p:cSld>
</p:sld>''';

/// 自造最小、**未压缩**内容流的 PDF（便于纯 Dart 提取）。
String _minimalPdf() => '%PDF-1.4\n'
    '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'
    '2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'
    '3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>\nendobj\n'
    '4 0 obj\n<< /Length 44 >>\nstream\n'
    'BT /F1 24 Tf 100 700 Td (Hello PDF) Tj ET\n'
    'endstream\nendobj\n'
    'trailer\n<< /Root 1 0 R >>\n%%EOF\n';

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 第 3 轮解析器验证（advisor_core/parsers）');
  stdout.writeln('=' * 60);

  final dir = Directory.systemTemp.createTempSync('pa_round3_parsers_');

  await _verifyPlainText(dir);
  await _verifyDocx(dir);
  await _verifyXlsx(dir);
  await _verifyPptx(dir);
  await _verifyPdf(dir);
  await _verifyLegacy(dir);

  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}

  stdout.writeln('\n${'=' * 60}');
  stdout.writeln('结果：通过 $_passed ／ 失败 $_failed');
  if (_failures.isNotEmpty) {
    stdout.writeln('\n失败明细：');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
    exitCode = 1;
  } else {
    stdout.writeln('全部通过 ✅');
  }
}

// ---------------------------------------------------------------------------

Future<void> _verifyPlainText(Directory dir) async {
  section('1. 纯文本直读（txt / md / csv）');

  final md = File('${dir.path}/doc.md')
    ..writeAsStringSync('# 标题A\n\n正文一。\n\n## 小节B\n\n正文二。');
  final parsed = await const PlainTextParser().parse(md.path);
  check('解析出块', parsed.blocks.isNotEmpty);
  check('标题写入 headingPath', parsed.blocks.any((b) => b.headingPath == '小节B'));
  checkEq('支持扩展名含 .csv', const PlainTextParser().supportedExtensions.contains('.csv'), true);

  final txt = File('${dir.path}/doc.txt')..writeAsStringSync('plain text content');
  final tp = await const PlainTextParser().parse(txt.path);
  check('txt 直读', tp.blocks.map((b) => b.text).join().contains('plain text content'));
}

// ---------------------------------------------------------------------------

Future<void> _verifyDocx(Directory dir) async {
  section('2. docx（ZIP + word/document.xml）');

  final path = _writeZip(dir, 'sample.docx', {
    '[Content_Types].xml': '<Types/>',
    'word/document.xml': _docxXml(),
  });
  final parsed = await const DocxParser().parse(path);
  final all = parsed.blocks.map((b) => b.text).join('|');
  check('解析出标题段', all.contains('技术规格'));
  check('解析出正文段', all.contains('整车整备质量 12000 kg'));
  check('制表符转义', all.contains('最大总质量 18000 kg\t轴距 4500 mm'));
  check('标题作为 headingPath', parsed.blocks.any((b) => b.headingPath == '技术规格'));
  checkEq('解析器名', parsed.parser, 'docx');

  // 缺 document.xml → 明确错误
  final bad = _writeZip(dir, 'bad.docx', {'[Content_Types].xml': '<Types/>'});
  var code = '';
  try {
    await const DocxParser().parse(bad);
  } on KnowledgeError catch (e) {
    code = e.code;
  }
  checkEq('缺 document.xml → kb.docx.missing', code, 'kb.docx.missing');
}

// ---------------------------------------------------------------------------

Future<void> _verifyXlsx(Directory dir) async {
  section('3. xlsx（sharedStrings + worksheet）');

  final path = _writeZip(dir, 'sample.xlsx', {
    'xl/sharedStrings.xml': _sstXml(),
    'xl/workbook.xml': _workbookXml(),
    'xl/worksheets/sheet1.xml': _sheetXml(),
  });
  final parsed = await const XlsxParser().parse(path);
  final row1 = parsed.blocks.firstWhere((b) => b.cellRange == 'A1:C1');
  checkEq('共享字符串行拼接', row1.text, '项目 | 整备质量 | 12000');
  checkEq('工作表名', row1.sheet, '参数表');
  check('数字单元格直取', parsed.blocks.any((b) => b.text.contains('6000')));
  checkEq('工作表数 = 1', parsed.pageCount, 1);
}

// ---------------------------------------------------------------------------

Future<void> _verifyPptx(Directory dir) async {
  section('4. pptx（slides/slideN.xml）');

  final path = _writeZip(dir, 'sample.pptx', {
    'ppt/slides/slide1.xml': _slideXml(),
  });
  final parsed = await const PptxParser().parse(path);
  checkEq('幻灯片数 = 1', parsed.pageCount, 1);
  final text = parsed.blocks.first.text;
  check('提取标题文本', text.contains('第一页标题'));
  check('提取正文文本', text.contains('正文要点一'));
  check('段落以换行分隔', text.contains('\n'));
}

// ---------------------------------------------------------------------------

Future<void> _verifyPdf(Directory dir) async {
  section('5. PDF（尽力而为：可提 / 不可提两分支）');

  final good = File('${dir.path}/good.pdf')..writeAsStringSync(_minimalPdf());
  final parsed = await const PdfTextParser().parse(good.path);
  final text = parsed.blocks.map((b) => b.text).join();
  check('可提分支：提取到文本', text.contains('Hello PDF'), 'text=$text');
  checkEq('可提分支：页数 = 1', parsed.pageCount, 1);

  // 不可提分支 A：非 PDF
  final notPdf = File('${dir.path}/not.pdf')..writeAsStringSync('这其实不是 PDF 文件');
  var codeA = '';
  try {
    await const PdfTextParser().parse(notPdf.path);
  } on KnowledgeError catch (e) {
    codeA = e.code;
  }
  checkEq('非 PDF → kb.pdf.invalid', codeA, 'kb.pdf.invalid');

  // 不可提分支 B：合法头但无文本（模拟扫描件）
  final noText = File('${dir.path}/scanned.pdf')
    ..writeAsStringSync('%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n');
  var codeB = '';
  try {
    await const PdfTextParser().parse(noText.path);
  } on KnowledgeError catch (e) {
    codeB = e.code;
  }
  checkEq('无文本 → kb.pdf.no_text（不静默）', codeB, 'kb.pdf.no_text');
}

// ---------------------------------------------------------------------------

Future<void> _verifyLegacy(Directory dir) async {
  section('6. legacy（doc/xls/ppt：无转换器优雅失败 / 有转换器委派）');

  checkEq('支持扩展名 = 3 类',
      const LegacyOfficeParser().supportedExtensions.length, 3);

  // 无转换器 → 优雅失败
  var code = '';
  try {
    await const LegacyOfficeParser().parse('${dir.path}/old.doc');
  } on KnowledgeError catch (e) {
    code = e.code;
  }
  checkEq('无转换器 → kb.legacy.no_converter', code, 'kb.legacy.no_converter');

  // 转换器不可用 → 同样失败
  var code2 = '';
  try {
    await LegacyOfficeParser(converter: _FakeConverter(available: false))
        .parse('${dir.path}/old.doc');
  } on KnowledgeError catch (e) {
    code2 = e.code;
  }
  checkEq('转换器不可用 → kb.legacy.no_converter', code2, 'kb.legacy.no_converter');

  // 有转换器 → 委派 OOXML 解析（真实 COM 沙箱不可验证，此处验证委派逻辑）
  final docxPath = _writeZip(dir, 'converted.docx', {'word/document.xml': _docxXml()});
  final parsed = await LegacyOfficeParser(converter: _FakeConverter(available: true, target: docxPath))
      .parse('${dir.path}/old.doc');
  check('委派 docx 解析出文本', parsed.blocks.map((b) => b.text).join().contains('技术规格'));
}

/// 假转换器：不调用 COM，仅验证 `LegacyOfficeParser` 的委派逻辑。
class _FakeConverter implements OfficeConverter {
  _FakeConverter({required this.available, this.target});
  final bool available;
  final String? target;

  @override
  bool isAvailable() => available;

  @override
  Future<String> convertToOoxml(String path, String targetDir) async {
    if (target == null) throw const KnowledgeError('kb.legacy.convert', '无转换目标');
    return target!;
  }
}
