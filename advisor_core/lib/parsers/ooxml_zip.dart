/// OOXML（docx / xlsx / pptx）通用读取工具：`archive`（ZIP）+ `xml`（XML），**纯 Dart**。
///
/// OOXML 本质是「ZIP 容器 + 一批 XML」（第 3 轮架构设计 §1.2）：用纯 Dart 能力离线解析，
/// **可沙箱验证**且跨平台。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import '../domain/common.dart';

/// OOXML 容器的只读视图。
class OoxmlZip {
  OoxmlZip._(this._archive);

  final Archive _archive;

  /// 从字节打开（自造样张 / 内存）。
  static OoxmlZip openBytes(List<int> bytes) {
    try {
      return OoxmlZip._(ZipDecoder().decodeBytes(bytes, verify: false));
    } catch (e) {
      throw KnowledgeError('kb.ooxml.zip', '无法解析 OOXML（ZIP）内容：$e', e);
    }
  }

  /// 从文件打开。
  static Future<OoxmlZip> open(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw KnowledgeError('kb.file_missing', '文件不存在：$path');
    }
    final bytes = await file.readAsBytes();
    return openBytes(bytes);
  }

  /// 全部文件型条目（排除目录项）。
  Iterable<ArchiveFile> get files => _archive.files.where((f) => f.isFile);

  /// 条目是否存在（文件型）。
  bool has(String name) => entry(name) != null;

  /// 取文件型条目。
  ArchiveFile? entry(String name) {
    for (final f in _archive.files) {
      if (f.isFile && f.name == name) return f;
    }
    return null;
  }

  /// 读取条目文本（UTF-8，容错解码）；不存在返回 null。
  String? readText(String name) {
    final e = entry(name);
    if (e == null) return null;
    return utf8.decode(e.content, allowMalformed: true);
  }

  /// 文件名列表。
  List<String> fileNames() => files.map((f) => f.name).toList();
}
