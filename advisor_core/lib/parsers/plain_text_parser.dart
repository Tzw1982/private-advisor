/// 纯文本 / Markdown 解析器（第 3 轮从 `testing/in_memory.dart` **迁入**生产代码，
/// 供生产与验证共用；`testing/in_memory.dart` 保留 re-export 以兼容既有 import）。
///
/// 支持 `.txt` / `.md` / `.markdown` / `.csv`：直读 + 按 Markdown 标题切 `headingPath`。
library;

import 'dart:io';

import '../domain/common.dart';
import '../domain/knowledge.dart';

/// 纯文本 / Markdown / CSV 解析器。
class PlainTextParser implements DocumentParser {
  const PlainTextParser();

  @override
  String get name => 'plain-text';

  @override
  String get version => '1.0.0';

  @override
  Set<String> get supportedExtensions => {'.txt', '.md', '.markdown', '.csv'};

  @override
  Future<ParsedDocument> parse(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw KnowledgeError('kb.file_missing', '文件不存在：$filePath');
    }
    final text = await file.readAsString();
    final lines = text.split('\n');

    final blocks = <ParsedBlock>[];
    var heading = '';
    final buf = StringBuffer();

    void flush() {
      final t = buf.toString().trim();
      if (t.isNotEmpty) {
        blocks.add(ParsedBlock(
          text: t,
          headingPath: heading.isEmpty ? null : heading,
          page: 1,
        ));
      }
      buf.clear();
    }

    for (final line in lines) {
      final m = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      if (m != null) {
        flush();
        heading = m.group(2)!.trim();
        continue;
      }
      buf.writeln(line);
    }
    flush();

    return ParsedDocument(blocks: blocks, pageCount: 1, parser: name, parserVersion: version);
  }
}
