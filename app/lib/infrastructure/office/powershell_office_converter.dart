/// 老版 Office（.doc / .xls / .ppt）→ OOXML 预转换实现（Windows 专属）。
///
/// 通过 PowerShell 调用本机 Office COM（Word / Excel / PowerPoint Application）
/// 把老二进制复合文档另存为 `docx` / `xlsx` / `pptx`，再交给 `advisor_core` 的
/// 纯 Dart OOXML 解析器（第 3 轮架构设计 §1.2 / §1.3）。
///
/// **沙箱不可验证**（无 Office / 不能跑外部 GUI 进程）——因此实现刻意**防御性**：
/// - `isAvailable()`：非 Windows 或未检测到 Office 安装目录 → false（UI 侧可提前置灰）；
/// - 转换失败 / 超时 / 未产出文件 → 抛**明确错误码**的 [KnowledgeError]，绝不静默；
/// - 全程不修改源文件（以只读方式打开）。
library;

import 'dart:async';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:path/path.dart' as p;

/// PowerShell + Office COM 预转换器。
class PowerShellOfficeConverter implements OfficeConverter {
  PowerShellOfficeConverter({this.timeout = const Duration(seconds: 90)});

  /// 单次转换超时（Office 冷启动可能较慢）。
  final Duration timeout;

  bool? _cached;

  /// 老格式 → OOXML 目标扩展名。
  static const Map<String, String> _targetExt = {
    '.doc': '.docx',
    '.xls': '.xlsx',
    '.ppt': '.pptx',
  };

  @override
  bool isAvailable() {
    final cached = _cached;
    if (cached != null) return cached;
    if (!Platform.isWindows) return _cached = false;
    return _cached = _officeLikelyInstalled();
  }

  /// 探测本机是否安装 Office（查常见安装目录；失败只意味着「不可用」，不抛错）。
  bool _officeLikelyInstalled() {
    const roots = [
      r'C:\Program Files\Microsoft Office',
      r'C:\Program Files (x86)\Microsoft Office',
      r'C:\Program Files\Microsoft Office 15',
    ];
    for (final root in roots) {
      try {
        if (Directory(root).existsSync()) return true;
      } catch (_) {
        // 无权限读取时忽略，继续探测下一个目录。
      }
    }
    return false;
  }

  @override
  Future<String> convertToOoxml(String path, String targetDir) async {
    if (!Platform.isWindows) {
      throw const KnowledgeError(
        'kb.legacy.no_windows',
        '解析 .doc/.xls/.ppt 需要本机 Office（COM 预转换），当前仅支持 Windows',
      );
    }
    if (!isAvailable()) {
      throw const KnowledgeError(
        'kb.legacy.no_office',
        '未检测到本机 Office，无法解析 .doc/.xls/.ppt；请先转换为 docx/xlsx/pptx',
      );
    }

    final ext = _extOf(path);
    final targetExt = _targetExt[ext];
    if (targetExt == null) {
      throw KnowledgeError(
          'kb.legacy.unsupported', '不支持的老格式：$ext（仅支持 .doc/.xls/.ppt）');
    }

    final outPath =
        p.join(targetDir, '${p.basenameWithoutExtension(path)}$targetExt');
    final script = _scriptFor(ext, path, outPath);

    ProcessResult result;
    try {
      result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script
        ],
      ).timeout(
        timeout,
        onTimeout: () => throw TimeoutException('Office COM 转换超时'),
      );
    } on TimeoutException {
      throw KnowledgeError(
        'kb.legacy.timeout',
        'Office 转换超时（${timeout.inSeconds} 秒）；请关闭占用该文件的窗口后重试',
      );
    } catch (e) {
      throw KnowledgeError(
          'kb.legacy.spawn', '无法启动 PowerShell（Office COM 预转换）：$e');
    }

    if (result.exitCode != 0) {
      throw KnowledgeError(
        'kb.legacy.com',
        'Office COM 转换失败（exit=${result.exitCode}）：${_oneLine(result.stderr.toString())}',
      );
    }

    final reported = result.stdout.toString().trim();
    final out = reported.isEmpty ? outPath : reported;
    if (!File(out).existsSync()) {
      throw KnowledgeError('kb.legacy.no_output', '转换未产出文件：$out');
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // PowerShell 脚本（按类型生成；SaveAs 格式常量为 Office 官方枚举值）
  // -------------------------------------------------------------------------

  /// `wdFormatXMLDocument`=16；`xlOpenXMLWorkbook`=51；`ppSaveAsOpenXMLPresentation`=24。
  static String _scriptFor(String ext, String input, String output) {
    final i = _q(input);
    final o = _q(output);
    switch (ext) {
      case '.doc':
        return '''
\$ErrorActionPreference = 'Stop'
\$app = New-Object -ComObject Word.Application
\$app.Visible = \$false
\$app.DisplayAlerts = 0
try {
  \$doc = \$app.Documents.Open($i, \$false, \$true)
  \$doc.SaveAs2($o, 16)
  \$doc.Close(\$false)
  Write-Output $o
} finally {
  \$app.Quit()
}
''';
      case '.xls':
        return '''
\$ErrorActionPreference = 'Stop'
\$app = New-Object -ComObject Excel.Application
\$app.Visible = \$false
\$app.DisplayAlerts = \$false
try {
  \$wb = \$app.Workbooks.Open($i, 0, \$true)
  \$wb.SaveAs($o, 51)
  \$wb.Close(\$false)
  Write-Output $o
} finally {
  \$app.Quit()
}
''';
      case '.ppt':
        return '''
\$ErrorActionPreference = 'Stop'
\$app = New-Object -ComObject PowerPoint.Application
try {
  \$pres = \$app.Presentations.Open($i, \$true, \$false, \$false)
  \$pres.SaveAs($o, 24)
  \$pres.Close()
  Write-Output $o
} finally {
  \$app.Quit()
}
''';
      default:
        throw KnowledgeError('kb.legacy.unsupported', '不支持的老格式：$ext');
    }
  }

  /// PowerShell 单引号字符串转义（`'` → `''`）。
  static String _q(String s) => "'${s.replaceAll("'", "''")}'";

  static String _extOf(String path) {
    final idx = path.lastIndexOf('.');
    return idx < 0 ? '' : path.substring(idx).toLowerCase();
  }

  static String _oneLine(String s) {
    final t = s.trim().replaceAll('\n', ' ');
    return t.length > 300 ? '${t.substring(0, 300)}…' : t;
  }
}
