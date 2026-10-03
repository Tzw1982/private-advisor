/// 批量导入编排（第 3 轮 · PRD §6.3 / 架构设计 §1.4、§3.7）。
///
/// 定位：**纯逻辑**（扫描 / 过滤 / 分类 / 进度聚合），可在临时目录内 `dart run` 全量验证。
/// 真正的「解析 → 分块 → 落库 → 建索引」由调用方注入的 [ImportFileResult] 回调完成
/// （生产接 `KnowledgeService.importDocument`），从而与本模块解耦。
///
/// 规则（写死）：
/// - 递归扫描；跳过隐藏 / 临时文件（`.` 开头、`~$` 前缀、`Thumbs.db`、`desktop.ini`、`*.tmp`）；
/// - 按扩展名分类 `supported` / `unsupported`（记 failed）；单文件 **50MB** 上限（超限记 failed）；
/// - **失败隔离**：单文件异常 → failed + 原因，整批不中断；
/// - **每批 50 个文件 yield**（保 UI 响应）；
/// - 进度经 `Stream<ImportProgress>` 推送。
library;

import 'dart:io';

/// 单文件导入上限（50MB）。
const int kMaxImportBytes = 50 * 1024 * 1024;

/// 每批处理文件数（批间 `yield`）。
const int kImportBatchSize = 50;

/// 扫描到的文件。
class ScannedFile {
  const ScannedFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.extension,
  });

  final String path;
  final String name;
  final int sizeBytes;

  /// 小写扩展名（含点，如 `.docx`）；无扩展名为空串。
  final String extension;

  @override
  String toString() => 'ScannedFile($name, ${sizeBytes}B, $extension)';
}

/// 被计划阶段拒绝的文件（不支持的格式 / 超过大小上限）。
class RejectedFile {
  const RejectedFile({required this.file, required this.reason});
  final ScannedFile file;
  final String reason;
}

/// 导入计划。
class ImportPlan {
  const ImportPlan({
    required this.supported,
    required this.unsupported,
    required this.oversize,
  });

  final List<ScannedFile> supported;
  final List<RejectedFile> unsupported;
  final List<RejectedFile> oversize;

  int get total => supported.length + unsupported.length + oversize.length;

  /// 计划阶段即被拒的文件数（记为 failed）。
  int get rejectedCount => unsupported.length + oversize.length;

  static const empty = ImportPlan(supported: [], unsupported: [], oversize: []);
}

/// 单文件导入结果状态。
enum ImportFileStatus {
  success('成功'),
  skipped('跳过'),
  failed('失败');

  const ImportFileStatus(this.label);
  final String label;
}

/// 单文件导入结果（由调用方回调返回）。
class ImportFileResult {
  const ImportFileResult({
    required this.status,
    this.chunkCount = 0,
    this.reason,
  });

  final ImportFileStatus status;
  final int chunkCount;
  final String? reason;

  static ImportFileResult success({int chunkCount = 0}) =>
      ImportFileResult(status: ImportFileStatus.success, chunkCount: chunkCount);

  static ImportFileResult skipped([String? reason]) =>
      ImportFileResult(status: ImportFileStatus.skipped, reason: reason);

  static ImportFileResult failed(String reason) =>
      ImportFileResult(status: ImportFileStatus.failed, reason: reason);
}

/// 进度明细项。
class ImportFileEntry {
  const ImportFileEntry({
    required this.file,
    required this.status,
    this.reason,
    this.chunkCount = 0,
  });

  final ScannedFile file;
  final ImportFileStatus status;
  final String? reason;
  final int chunkCount;
}

/// 进度快照。
class ImportProgress {
  const ImportProgress({
    required this.total,
    required this.processed,
    required this.success,
    required this.skipped,
    required this.failed,
    required this.perFile,
    this.done = false,
  });

  final int total;

  /// 已处理文件数（含计划阶段被拒的）。
  final int processed;
  final int success;
  final int skipped;
  final int failed;
  final List<ImportFileEntry> perFile;
  final bool done;

  double get percent => total == 0 ? (done ? 1 : 0) : (processed / total).clamp(0, 1).toDouble();
}

// ---------------------------------------------------------------------------
// 扫描器
// ---------------------------------------------------------------------------

/// 目录扫描器（递归 + 过滤隐藏 / 临时文件）。
abstract final class DirectoryScanner {
  /// 是否应跳过的文件名。
  static bool isIgnored(String name) {
    if (name.isEmpty) return true;
    if (name.startsWith('.')) return true; // 隐藏文件 / `..`
    if (name.startsWith('~\$')) return true; // Office 临时锁文件
    final lower = name.toLowerCase();
    if (lower == 'thumbs.db' || lower == 'desktop.ini') return true;
    if (lower.endsWith('.tmp')) return true;
    return false;
  }

  /// 递归扫描多个文件夹，返回候选文件（未分类）。
  static List<ScannedFile> scan(List<String> folders, {bool recursive = true}) {
    final out = <ScannedFile>[];
    for (final f in folders) {
      final dir = Directory(f);
      if (!dir.existsSync()) continue;
      _scanDir(dir, recursive, out);
    }
    return out;
  }

  static void _scanDir(Directory dir, bool recursive, List<ScannedFile> out) {
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return; // 无权限等：跳过该目录，不阻断整批。
    }
    for (final e in entries) {
      final name = _baseName(e.path);
      if (isIgnored(name)) continue;
      if (e is Directory) {
        if (recursive) _scanDir(e, recursive, out);
      } else if (e is File) {
        int size;
        try {
          size = e.statSync().size;
        } catch (_) {
          size = 0;
        }
        out.add(ScannedFile(
          path: e.path,
          name: name,
          sizeBytes: size,
          extension: extensionOf(name),
        ));
      }
    }
  }

  /// 取扩展名（小写、含点）；无扩展名返回空串。
  static String extensionOf(String name) {
    final idx = name.lastIndexOf('.');
    if (idx <= 0 || idx == name.length - 1) return '';
    return name.substring(idx).toLowerCase();
  }

  static String _baseName(String path) {
    final i1 = path.lastIndexOf('/');
    final i2 = path.lastIndexOf('\\');
    final i = i1 > i2 ? i1 : i2;
    return i < 0 ? path : path.substring(i + 1);
  }
}

// ---------------------------------------------------------------------------
// 计划器
// ---------------------------------------------------------------------------

/// 导入计划器（分类 + 大小上限）。
abstract final class ImportPlanner {
  /// 由文件夹列表生成计划。
  static ImportPlan plan(
    List<String> folders, {
    required Set<String> supportedExtensions,
    bool recursive = true,
    int maxBytes = kMaxImportBytes,
  }) =>
      planFiles(
        DirectoryScanner.scan(folders, recursive: recursive),
        supportedExtensions: supportedExtensions,
        maxBytes: maxBytes,
      );

  /// 由已扫描文件生成计划。
  static ImportPlan planFiles(
    List<ScannedFile> files, {
    required Set<String> supportedExtensions,
    int maxBytes = kMaxImportBytes,
  }) {
    final supported = <ScannedFile>[];
    final unsupported = <RejectedFile>[];
    final oversize = <RejectedFile>[];
    for (final f in files) {
      if (f.sizeBytes > maxBytes) {
        oversize.add(RejectedFile(file: f, reason: '超过 50MB 上限（${f.sizeBytes} 字节）'));
        continue;
      }
      if (supportedExtensions.contains(f.extension)) {
        supported.add(f);
      } else {
        unsupported.add(RejectedFile(
          file: f,
          reason: '不支持的格式：${f.extension.isEmpty ? '（无扩展名）' : f.extension}',
        ));
      }
    }
    return ImportPlan(supported: supported, unsupported: unsupported, oversize: oversize);
  }
}

// ---------------------------------------------------------------------------
// 执行器
// ---------------------------------------------------------------------------

/// 批量导入执行器（同步顺序批处理 + `Stream` 进度）。
class BatchImporter {
  BatchImporter({this.batchSize = kImportBatchSize});

  /// 每批文件数（批间 `yield`）。
  final int batchSize;

  /// 执行导入。[importFile] 为单文件导入回调（生产 = `KnowledgeService.importDocument`）。
  Stream<ImportProgress> run({
    required ImportPlan plan,
    required Future<ImportFileResult> Function(ScannedFile file) importFile,
  }) async* {
    final entries = <ImportFileEntry>[
      ...plan.oversize.map((r) => ImportFileEntry(
            file: r.file,
            status: ImportFileStatus.failed,
            reason: r.reason,
          )),
      ...plan.unsupported.map((r) => ImportFileEntry(
            file: r.file,
            status: ImportFileStatus.failed,
            reason: r.reason,
          )),
    ];

    var processed = entries.length;
    var success = 0;
    var skipped = 0;
    var failed = entries.length;

    ImportProgress snapshot({bool done = false}) => ImportProgress(
          total: plan.total,
          processed: processed,
          success: success,
          skipped: skipped,
          failed: failed,
          perFile: List.unmodifiable(entries),
          done: done,
        );

    yield snapshot();

    final supported = plan.supported;
    for (var i = 0; i < supported.length; i++) {
      final f = supported[i];
      ImportFileResult res;
      try {
        res = await importFile(f);
      } catch (e) {
        res = ImportFileResult.failed('$e');
      }
      switch (res.status) {
        case ImportFileStatus.success:
          success++;
        case ImportFileStatus.skipped:
          skipped++;
        case ImportFileStatus.failed:
          failed++;
      }
      entries.add(ImportFileEntry(
        file: f,
        status: res.status,
        reason: res.reason,
        chunkCount: res.chunkCount,
      ));
      processed++;

      final isBatchEnd = (i + 1) % batchSize == 0;
      if (isBatchEnd && i + 1 < supported.length) {
        yield snapshot();
        await Future<void>.delayed(Duration.zero);
      }
    }

    yield snapshot(done: true);
  }
}
