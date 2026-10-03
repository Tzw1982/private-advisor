/// 路径归一化规约（第 4 轮设计 §2.1，唯一权威定义）。
///
/// **纯字符串函数，无任何文件系统 IO**（不解析符号链接、不访问磁盘）。
/// 三律（跨任务硬约束 #4）：
/// 1. **存储原样**：文档 `file_path` / `display_path` 保持用户侧真实大小写，UI 与
///    打开文件都用原值；
/// 2. **比较用键**：一切路径相等判断都用 [folderKey]（canonicalize 后转小写）；
///    `knowledge_base_folders.folder_path` 列存的就是比较键；
/// 3. **前缀必须带分隔符边界**：`key(doc)` 命中 `folderKey` 的条件是
///    `docKey.startsWith(folderKey + '\')`——防 `E:\Docs` 误匹配 `E:\Docs2`。
///
/// 注意：本模块只做**字符串规约**，不保证路径真实存在。
library;

/// 归一化一个路径（不访问文件系统、不解析符号链接）：
///
/// - 输入含 `/` 时统一替换为 `\`；
/// - 折叠连续分隔符（UNC 头部 `\\` 保留两个）；
/// - 消解 `.` 与 `..` 段（`..` 弹出上一段；盘符根 / UNC share 根不再弹出）；
/// - 去掉尾部分隔符（`C:\` 规约为 `C:`——前缀匹配语义不变）；
/// - 相对路径且提供 [cwd] 时，先拼接 [cwd] 再消解（cwd 自身视为绝对）。
///
/// Windows 大小写**不在**此步处理——小写化只发生在 [folderKey]（存储原样律）。
String canonicalize(String input, {String? cwd}) {
  var p = input.trim();
  if (p.isEmpty) return p;
  p = p.replaceAll('/', r'\');

  // 折叠连续反斜杠，但保留 UNC 头部的两个（`\\server\share`）。
  final isUncInput = p.startsWith(r'\\');
  final folded = StringBuffer();
  for (var i = 0; i < p.length; i++) {
    final ch = p[i];
    final prevIsSep = folded.isNotEmpty && folded.toString().codeUnitAt(folded.length - 1) == 0x5C;
    if (ch == r'\' && prevIsSep && !(isUncInput && folded.length == 1)) {
      continue;
    }
    folded.write(ch);
  }
  p = folded.toString();

  final hasDrive = _hasDriveLetter(p);
  final isUnc = p.startsWith(r'\\');
  // 无盘符、非 UNC、但以分隔符开头 → POSIX / 盘符省略型绝对路径。
  final leadingSepAbsolute = !hasDrive && !isUnc && p.startsWith(r'\');
  final isAbsolute = hasDrive || isUnc || leadingSepAbsolute;

  // 相对路径 → 拼接 cwd 后重新规约（仅一层递归）。
  if (!isAbsolute && cwd != null && cwd.trim().isNotEmpty) {
    final base = canonicalize(cwd);
    p = base.isEmpty ? p : '$base\\$p';
  }

  // 消解 . / ..
  final isUncResult = p.startsWith(r'\\');
  final resultAbsolute = isUncResult || _hasDriveLetter(p) || p.startsWith(r'\');
  final segments = p.split(r'\').where((s) => s.isNotEmpty).toList();
  final stack = <String>[];
  for (final seg in segments) {
    if (seg == '.') continue;
    if (seg == '..') {
      // 根不可再弹出：UNC 保留 server/share 两段；盘符根保留盘符段；POSIX 根保留空。
      final rootFloor = isUncResult ? 2 : (_hasDriveLetter(stack.isEmpty ? '' : stack.first) ? 1 : 0);
      if (stack.length > rootFloor) stack.removeLast();
      continue;
    }
    stack.add(seg);
  }

  var out = stack.join(r'\');
  if (isUncResult && out.isNotEmpty) {
    out = r'\\' + out;
  } else if (resultAbsolute && !isUncResult && !stack.isEmpty && !_hasDriveLetter(stack.first)) {
    out = r'\' + out;
  }
  return out;
}

/// 路径是否带盘符（如 `C:` / `e:`）。
bool _hasDriveLetter(String p) {
  if (p.length < 2) return false;
  final c = p.codeUnitAt(0);
  final isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  return isLetter && p[1] == ':';
}

/// 路径比较键：`canonicalize(...).toLowerCase()`。
///
/// 一切路径相等判断都用本函数（Windows 大小写不敏感）；
/// `knowledge_base_folders.folder_path` 列存储本值，使 UNIQUE 约束在大小写
/// 层面真正生效。
String folderKey(String input, {String? cwd}) =>
    canonicalize(input, cwd: cwd).toLowerCase();

/// 前缀匹配（带分隔符边界）：[docPath] 是否位于 [folderKeyOfFolder] 之下。
///
/// 条件 = `docKey.startsWith(folderKey + '\')`，防 `E:\Docs` 误匹配 `E:\Docs2`。
/// **只允许用于补绑回填（只增不删）与重扫对账键**；任何删除路径严禁使用
/// 路径前缀判定归属（第 4 轮设计 §1.1：归属 = folder_id 登记事实）。
bool isUnderFolder(String docPath, String folderKeyOfFolder, {String? cwd}) {
  final fk = folderKey(folderKeyOfFolder, cwd: cwd);
  if (fk.isEmpty) return false;
  final docKey = folderKey(docPath, cwd: cwd);
  return docKey.startsWith('$fk\\');
}
