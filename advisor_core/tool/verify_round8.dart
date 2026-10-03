/// 第 8 轮 · 附件上传 T01 验证（纯 Dart，`dart run`）。
///
/// 运行：`cd advisor_core && dart run tool/verify_round8.dart`
///
/// 覆盖（架构 §5 验证项 1，T01 完成标准）：
/// 1. `AttachmentPolicy.validate`：白名单内 / 外、**边界 20MB ±1B**、空名、负大小、
///    多扩展名伪装（`x.jpg.exe` → `exe` 被拒）、无扩展名；
/// 2. **文件名安全化红队用例表**（逐条精确期望 + 全表不变量断言）：
///    `..` 穿越 / 绝对路径 / 盘符 / Windows 保留名（CON/PRN/AUX/NUL/COM1–9/LPT1–9）/
///    控制字符 / 超长截断 / 空名 / 纯空格 / 尾点 / Unicode 同形与 emoji；
/// 3. **越界路径拒绝**：`isInsideRoot` 二次断言（含 `<root>-evil` 前缀陷阱）；
/// 4. `storedRelPath` **内容寻址稳定性**：同 sha256 恒同路径；sha 非法 → `ValidationError`。
///
/// ⚠️ T02/T03 会继续扩展本文件（`LocalAttachmentStore` 沙箱、`deleteMessage` 编排）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:path/path.dart' as p;
import 'package:advisor_core/testing/in_memory.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（与 verify_round4 / verify_round6 同款）
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

void checkEq(String name, Object? actual, Object? expected) {
  check(name, actual == expected, 'actual=$actual expected=$expected');
}

// ---------------------------------------------------------------------------
// 1. 白名单 / 类型 / MIME / 体积
// ---------------------------------------------------------------------------

void _verifyTypes() {
  section('1. 白名单 / 类型 / MIME / 体积格式化');

  checkEq('白名单总数 = 16（图片 6 + 文档/zip 10）',
      AttachmentPolicy.kAllowedExtensions.length, 16);
  checkEq('kMaxAttachmentBytes = 20MB', AttachmentPolicy.kMaxAttachmentBytes,
      20 * 1024 * 1024);

  for (final ext in [
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'pdf',
    'txt',
    'md',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'zip'
  ]) {
    check('扩展名 .$ext 在白名单内', AttachmentPolicy.isAllowedExtension('a.$ext'));
  }
  for (final ext in [
    'sh',
    'exe',
    'dll',
    'bat',
    'py',
    'js',
    'gz',
    'tar',
    'rar',
    '7z',
    'html'
  ]) {
    check('扩展名 .$ext 不在白名单', !AttachmentPolicy.isAllowedExtension('a.$ext'));
  }

  checkEq(
      '无扩展名 → 不在白名单', AttachmentPolicy.isAllowedExtension('archive'), false);
  checkEq('空文件名 → 不在白名单', AttachmentPolicy.isAllowedExtension(''), false);
  checkEq('只有点 → 不在白名单', AttachmentPolicy.isAllowedExtension('.'), false);

  check('扩展名大小写不敏感（.PNG 放行）', AttachmentPolicy.isAllowedExtension('A.PNG'));
  check('扩展名含空格前后不影响（" .png "）', AttachmentPolicy.isAllowedExtension('a.png '));

  checkEq('kindOf("a.png") = image', AttachmentPolicy.kindOf('a.png'),
      AttachmentKind.image);
  checkEq('kindOf("a.webp") = image', AttachmentPolicy.kindOf('a.webp'),
      AttachmentKind.image);
  checkEq('kindOf("a.pdf") = file', AttachmentPolicy.kindOf('a.pdf'),
      AttachmentKind.file);
  checkEq('kindOf("a.zip") = file', AttachmentPolicy.kindOf('a.zip'),
      AttachmentKind.file);
  checkEq('kindOf 未知扩展名回落 file', AttachmentPolicy.kindOf('a.zzz'),
      AttachmentKind.file);

  checkEq(
      'mimeTypeOf("a.png")', AttachmentPolicy.mimeTypeOf('a.png'), 'image/png');
  checkEq('mimeTypeOf("a.jpg")', AttachmentPolicy.mimeTypeOf('a.jpg'),
      'image/jpeg');
  checkEq('mimeTypeOf("a.jpeg")', AttachmentPolicy.mimeTypeOf('a.jpeg'),
      'image/jpeg');
  checkEq('mimeTypeOf("a.md")', AttachmentPolicy.mimeTypeOf('a.md'),
      'text/markdown');
  checkEq('mimeTypeOf("a.zip")', AttachmentPolicy.mimeTypeOf('a.zip'),
      'application/zip');
  checkEq('mimeTypeOf("a.docx") = null（本期不猜 MIME）',
      AttachmentPolicy.mimeTypeOf('a.docx'), null);

  checkEq('formatBytes(999)', AttachmentPolicy.formatBytes(999), '999 B');
  checkEq('formatBytes(1024)', AttachmentPolicy.formatBytes(1024), '1.0KB');
  checkEq(
      'formatBytes(10000000)', AttachmentPolicy.formatBytes(10000000), '9.5MB');

  checkEq('AttachmentKind.parse("image")', AttachmentKind.parse('image'),
      AttachmentKind.image);
  checkEq('AttachmentKind.parse(null) 回落 file', AttachmentKind.parse(null),
      AttachmentKind.file);
  checkEq('AttachmentKind.image.label', AttachmentKind.image.label, '图片');
}

// ---------------------------------------------------------------------------
// 2. validate（白名单 / 上限 / 空名 / 负大小）
// ---------------------------------------------------------------------------

void _verifyValidate() {
  section('2. AttachmentPolicy.validate（含 20MB 边界）');

  checkEq('合法文件 → null',
      AttachmentPolicy.validate(fileName: '需求说明.pdf', sizeBytes: 1024), null);
  checkEq(
      '恰好 20MB 边界值放行（含等号）',
      AttachmentPolicy.validate(
          fileName: 'a.png', sizeBytes: AttachmentPolicy.kMaxAttachmentBytes),
      null);
  check(
      '20MB + 1B 拒绝（明确原因，不静默）',
      AttachmentPolicy.validate(
              fileName: 'a.png',
              sizeBytes: AttachmentPolicy.kMaxAttachmentBytes + 1) !=
          null);
  check(
      '超限原因含文件名与体面值',
      (AttachmentPolicy.validate(
                  fileName: 'big.png',
                  sizeBytes: AttachmentPolicy.kMaxAttachmentBytes + 1024) ??
              '')
          .contains('big.png'));
  check(
      '超限原因含 "20.0MB"',
      (AttachmentPolicy.validate(
                  fileName: 'big.png',
                  sizeBytes: AttachmentPolicy.kMaxAttachmentBytes + 1024) ??
              '')
          .contains('20.0MB'));

  check('run.sh 被拒（.sh 不在白名单）',
      AttachmentPolicy.validate(fileName: 'run.sh', sizeBytes: 10) != null);
  check('多扩展名伪装 x.jpg.exe 被拒（取末段 exe）',
      AttachmentPolicy.validate(fileName: 'x.jpg.exe', sizeBytes: 10) != null);
  check(
      '压缩包 x.tar.gz 被拒（.gz 不在白名单）',
      AttachmentPolicy.validate(fileName: 'my file.tar.gz', sizeBytes: 10) !=
          null);
  check(
      '无扩展名 archive 被拒（原因说"没有扩展名"）',
      (AttachmentPolicy.validate(fileName: 'archive', sizeBytes: 10) ?? '')
          .contains('没有扩展名'));

  check('空文件名（纯空格）被拒',
      AttachmentPolicy.validate(fileName: '   ', sizeBytes: 10) != null);
  check('负大小被拒',
      AttachmentPolicy.validate(fileName: 'a.png', sizeBytes: -1) != null);

  check('图片白名单放行 bmp',
      AttachmentPolicy.validate(fileName: 'a.bmp', sizeBytes: 1) == null);
  check(
      'zip 进白名单（裁定 #7）且 kindOf = file',
      AttachmentPolicy.validate(fileName: 'a.zip', sizeBytes: 1) == null &&
          AttachmentPolicy.kindOf('a.zip') == AttachmentKind.file);
}

// ---------------------------------------------------------------------------
// 3. 文件名安全化 —— 红队用例表（逐条精确期望）
// ---------------------------------------------------------------------------

void _verifySanitizeRedTeam() {
  section('3. 文件名安全化 · 红队用例表（逐条精确期望）');

  // (输入, 期望输出, 说明)
  const cases = <(String, String, String)>[
    // —— 路径穿越 ——
    ('../../etc/passwd', '._._etc_passwd', '上级目录穿越：分隔符全换 _，`..` 折叠'),
    (r'..\..\..\win.ini', '._._._win.ini', '反斜杠 + 盘符混排穿越'),
    ('a/b\\c:d.txt', 'a_b_c_d.txt', '斜杠 / 反斜杠 / 冒号全换 _'),
    // —— 绝对路径 / 盘符 ——
    (r'C:\Windows\report.txt', 'C__Windows_report.txt', '盘符与路径分隔符中和'),
    ('/etc/passwd', '_etc_passwd', '前导斜杠中和为 _'),
    // —— Windows 保留名 ——
    ('CON.txt', '_CON.txt', 'CON 保留名 → 加 _ 前缀'),
    ('prn', '_prn', '无扩展名的保留名'),
    ('NUL.dat', '_NUL.dat', 'NUL 保留名'),
    ('COM1.log', '_COM1.log', 'COM1 保留名'),
    ('lpt9.zip', '_lpt9.zip', 'LPT9 保留名'),
    // —— 控制字符 ——
    ('a\u0000b\u0007c.txt', 'abc.txt', 'NUL 与 BEL 被剔除'),
    ('a\r\nb.txt', 'ab.txt', 'CR / LF 被剔除（防文件名注入）'),
    // —— Unicode 同形 / emoji ——
    ('照片 2026-10-01.png', '照片 2026-10-01.png', '中文与空格保留'),
    ('ПРИВЕТ.md', 'ПРИВЕТ.md', 'Cyrillic 同形字符不构成穿越，原样保留'),
    ('📊 数据表.xlsx', '📊 数据表.xlsx', 'emoji 原样保留（不构成穿越）'),
    // —— 超长 / 空名 ——
    ('', 'file', '空名回退 file'),
    ('   ', 'file', '纯空格回退 file'),
    ('...', 'file', '纯点序列回退 file'),
    ('file.', 'file', '尾点被剥除（防隐式扩展名）'),
    // —— 多扩展名 ——
    ('x.jpg.exe', 'x.jpg.exe', '安全化不改展示名；末段 exe 由 validate 拒'),
    ('my file.tar.gz', 'my file.tar.gz', '.gz 不在白名单 → validate 拒'),
  ];

  String show(String s) => s
      .replaceAll('\u0000', r'\0')
      .replaceAll('\u0007', r'\a')
      .replaceAll('\r', r'\r')
      .replaceAll('\n', r'\n');

  for (final (input, expected, why) in cases) {
    final actual = AttachmentPolicy.sanitizeFileName(input);
    checkEq('「${show(input)}」→ 「$expected」（$why）', actual, expected);
  }

  // 超长截断单独断言（200 字符 a + .png → 总长恰 80，扩展名保留）。
  final longName = 'a' * 200;
  final longOut = AttachmentPolicy.sanitizeFileName('$longName.png');
  checkEq('200 字符名截断后总长 = kMaxFileNameChars(80)', longOut.length,
      AttachmentPolicy.kMaxFileNameChars);
  check('超长截断保留 .png 扩展名', longOut.endsWith('.png'));
  check('超长截断保留原文件名主体', longOut.startsWith('aaa'));

  // 扩展名非法 / 超长 → 判定为「无扩展名」（主体安全化后原样保留，validate 会拒）。
  checkEq('扩展名含非法字符（a.p!ng）→ 视为无扩展名，主体保留',
      AttachmentPolicy.sanitizeFileName('a.p!ng'), 'a.p!ng');
  check(
      'a.p!ng 因扩展名非法被 validate 拒绝（"没有扩展名"）',
      (AttachmentPolicy.validate(fileName: 'a.p!ng', sizeBytes: 10) ?? '')
          .contains('没有扩展名'));
  checkEq('扩展名超长（>10）→ 视为无扩展名',
      AttachmentPolicy.sanitizeFileName('a.abcdefghijk'), 'a.abcdefghijk');
}

// ---------------------------------------------------------------------------
// 4. 安全化不变量（对上述全部输出统一复检）
// ---------------------------------------------------------------------------

void _verifySanitizeInvariants() {
  section('4. 安全化不变量（全表复检，防单条期望写偏）');

  final hostile = <String>[
    '../../etc/passwd',
    r'..\..\..\win.ini',
    r'C:\Windows\system32\drivers\etc\hosts',
    'CON.txt',
    'prn',
    'NUL.dat',
    'COM1.log',
    'lpt9.zip',
    'a\u0000b\u0007c.txt',
    'a\r\nb.txt',
    '...',
    'file.',
    '   ',
    '',
    'x.jpg.exe',
    'a/b\\c:d.txt',
    '照片 2026-10-01.png',
    'a' * 200 + '.png',
    'averyveryverylongextension.name',
  ];

  var allOk = true;
  final problems = <String>[];
  for (final raw in hostile) {
    final out = AttachmentPolicy.sanitizeFileName(raw);
    if (out.contains('/') || out.contains('\\')) {
      allOk = false;
      problems.add('[$raw] 仍含路径分隔符 → $out');
    }
    if (out.contains('..')) {
      allOk = false;
      problems.add('[$raw] 仍含 ".." → $out');
    }
    if (out.contains(':')) {
      allOk = false;
      problems.add('[$raw] 仍含冒号（盘符/ADS）→ $out');
    }
    if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(out)) {
      allOk = false;
      problems.add('[$raw] 仍含控制字符 → $out');
    }
    if (out.length > AttachmentPolicy.kMaxFileNameChars) {
      allOk = false;
      problems.add('[$raw] 超长（${out.length}）→ $out');
    }
    final ext = AttachmentPolicy.extensionOf(out);
    final stem =
        ext.isEmpty ? out : out.substring(0, out.length - ext.length - 1);
    final stemKey = stem.replaceAll(RegExp(r'[. ]+$'), '').toUpperCase();
    if (AttachmentPolicy.kWindowsReservedNames.contains(stemKey)) {
      allOk = false;
      problems.add('[$raw] stem 仍是保留名 → $out');
    }
    if (out.trim().isEmpty) {
      allOk = false;
      problems.add('[$raw] 结果为空白');
    }
  }
  check(
      '全表 ${hostile.length} 条输出均不变量合规（无分隔符/无".."/无冒号/无控制字符/不超长/stem 非保留名/非空白）',
      allOk,
      problems.isEmpty ? null : problems.join('；'));

  // 幂等性：再安全化一次结果不变（稳定输出）。
  var idem = true;
  for (final raw in hostile) {
    final once = AttachmentPolicy.sanitizeFileName(raw);
    if (AttachmentPolicy.sanitizeFileName(once) != once) idem = false;
  }
  check('sanitizeFileName 幂等（f(f(x)) == f(x)）', idem);
}

// ---------------------------------------------------------------------------
// 5. 内容寻址 storedRelPath
// ---------------------------------------------------------------------------

void _verifyStoredRelPath() {
  section('5. 内容寻址 storedRelPath（稳定性 / 归一 / 非法拒绝）');

  const sha = 'ab12cd34ef56';
  checkEq('storedRelPath(sha, "png")',
      AttachmentPolicy.storedRelPath(sha, 'png'), 'ab/ab12cd34ef56.png');
  checkEq(
      '**同 sha256 恒得同一路径**（内容寻址去重地基）',
      AttachmentPolicy.storedRelPath(sha.toUpperCase(), '.PNG'),
      'ab/ab12cd34ef56.png');
  checkEq(
      '无扩展名 → 不带点', AttachmentPolicy.storedRelPath(sha, ''), 'ab/ab12cd34ef56');
  checkEq('两级目录前缀 = sha256[0:2]',
      AttachmentPolicy.storedRelPath(sha, 'pdf').split('/').first, 'ab');
  check(
      '含 10 次调用结果全部一致',
      List.filled(10, AttachmentPolicy.storedRelPath(sha, 'png'))
          .every((e) => e == 'ab/ab12cd34ef56.png'));

  // sha 非法 → ValidationError（绝不拼出逃逸路径）。
  for (final bad in ['ab', 'zzzz1234', '', '  ', 'ABCD!!', 'abc_defg']) {
    try {
      AttachmentPolicy.storedRelPath(bad, 'png');
      check('非法 sha「$bad」应被拒绝', false, '未抛异常');
    } on ValidationError catch (e) {
      check('非法 sha「$bad」→ ValidationError(${e.code})',
          e.code == 'attach.sha_invalid');
    }
  }
}

// ---------------------------------------------------------------------------
// 6. 越界路径拒绝（isInsideRoot 二次断言）
// ---------------------------------------------------------------------------

void _verifyPathEscape() {
  section('6. 越界路径拒绝（isInsideRoot 二次断言）');

  const root = 'C:/data/attachments';
  check('根内子路径放行',
      AttachmentPolicy.isInsideRoot('$root/ab/ab12cd34ef56.png', root));
  check('等于根目录放行', AttachmentPolicy.isInsideRoot(root, root));
  check('反斜杠形式同样放行',
      AttachmentPolicy.isInsideRoot(r'C:\data\attachments\ab\x.png', root));
  check('根外路径拒绝', !AttachmentPolicy.isInsideRoot('C:/data/other/x.png', root));
  check('**<root>-evil 前缀陷阱拒绝**（纯 startsWith 会误放行）',
      !AttachmentPolicy.isInsideRoot('C:/data/attachments-evil/x.png', root));
  check(
      '尾部冗余斜杠归一后放行', AttachmentPolicy.isInsideRoot('$root/ab/x.png', '$root/'));
  check('相对路径穿越拒绝',
      !AttachmentPolicy.isInsideRoot('../attachments/x.png', 'attachments'));
  check('空 root 一律拒绝', !AttachmentPolicy.isInsideRoot('anything/at/all', ''));
  check('空 path 与空 root 拒绝', !AttachmentPolicy.isInsideRoot('', ''));
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('════════════════════════════════════════');
  stdout.writeln('第 8 轮 · 附件上传 T01 验证（Attachment 域 + AttachmentPolicy）');
  stdout.writeln('════════════════════════════════════════');

  _verifyTypes();
  _verifyValidate();
  _verifySanitizeRedTeam();
  _verifySanitizeInvariants();
  _verifyStoredRelPath();
  _verifyPathEscape();

  // T03：真实临时目录沙箱 + 两阶段 + 删除编排 + 假 store 决策
  final tmpDir = Directory.systemTemp.createTempSync('pa_attach_verify_');
  try {
    await _verifyLocalStore(tmpDir);
    await _verifyAttachmentService(tmpDir);
    await _verifyDeleteMessage(tmpDir);
    // 第 9 轮：文档阅读（抽文本注入）+ 图片多模态（supports_vision 门控）。
    await _verifyDocumentReadingAndVision(tmpDir);
  } finally {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {
      // 忽略清理失败。
    }
  }
  await _verifyDeleteDecisionWithFakeStore();
  // T51：附件告知注入（单聊 / 群聊 / 失败隔离 / 检索 query 不被污染）。
  await _verifyAttachmentNotice();

  stdout.writeln('\n════════════════════════════════════════');
  stdout.writeln('结果：通过 $_passed ／ 失败 $_failed');
  if (_failed > 0) {
    stdout.writeln('失败明细：');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
    stdout.writeln('════════════════════════════════════════');
    exit(1);
  }
  stdout.writeln('全部通过 ✅');
  stdout.writeln('════════════════════════════════════════');
}

// ---------------------------------------------------------------------------
// 7. LocalAttachmentStore 沙箱（真实临时目录）
// ---------------------------------------------------------------------------

/// 读包内源码文本（用于"零扫盘 / 零 listSync"这类**源码级**回归断言）。
String _readSourceText(String relPath) {
  final candidates = <String>[
    relPath,
    '${File(Platform.script.toFilePath()).parent.parent.path}'
        '${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}',
    '${Directory.current.path}'
        '${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}',
  ];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f.readAsStringSync();
  }
  return '';
}

/// 只记录调用、不动物理文件的替身（用于断言编排层行为）。
class _RecordingStore implements AttachmentStore {
  final List<String> deleted = <String>[];
  final Map<String, int> references = <String, int>{};
  final Map<String, bool> existing = <String, bool>{};

  @override
  Future<String> save({
    required String sourcePath,
    required String sha256,
    required String fileName,
  }) async =>
      AttachmentPolicy.storedRelPath(
          sha256, AttachmentPolicy.extensionOf(fileName));

  @override
  Future<int> referenceCount(String storedPath,
          {required String excludeId}) async =>
      references[storedPath] ?? 0;

  @override
  Future<void> deleteIfUnreferenced(String storedPath) async =>
      deleted.add(storedPath);

  @override
  Future<bool> exists(String storedPath) async => existing[storedPath] ?? false;
}

/// 插入必抛的仓储替身（用于验证"落库失败 → 物理文件被清理"）。
class _ThrowingInsertRepo implements AttachmentRepository {
  _ThrowingInsertRepo(this._inner);
  final AttachmentRepository _inner;

  @override
  Future<void> insertAttachment(Attachment a) async =>
      throw const StorageError('storage.attachments.insert', '模拟落库失败');

  @override
  Future<void> insertAttachments(List<Attachment> list) async =>
      throw const StorageError('storage.attachments.insert', '模拟落库失败');

  @override
  Future<List<Attachment>> listAttachmentsByMessage(String messageId) =>
      _inner.listAttachmentsByMessage(messageId);

  @override
  Future<List<Attachment>> listAttachmentsByMessages(List<String> messageIds) =>
      _inner.listAttachmentsByMessages(messageIds);

  @override
  Future<Attachment?> findBySha256(String sha256) =>
      _inner.findBySha256(sha256);

  @override
  Future<int> countByStoredPath(String storedPath, {String? excludeId}) =>
      _inner.countByStoredPath(storedPath, excludeId: excludeId);

  @override
  Future<void> deleteByMessage(String messageId) =>
      _inner.deleteByMessage(messageId);
}

String _writeSource(String dir, String name, String content) {
  final f = File('$dir${Platform.pathSeparator}$name');
  f.writeAsStringSync(content);
  return f.path;
}

Message _msg(String id, String convId,
    {MessageSenderType sender = MessageSenderType.user,
    String content = '原文'}) {
  final now = 1700000000000;
  return Message(
    id: id,
    conversationId: convId,
    senderType: sender,
    senderId: sender == MessageSenderType.user ? 'u_local' : 'e_x',
    content: content,
    status: MessageStatus.completed,
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> _verifyLocalStore(Directory dir) async {
  section('7. LocalAttachmentStore 沙箱（真实临时目录）');

  final root = Directory('${dir.path}${Platform.pathSeparator}store')
    ..createSync(recursive: true);
  final repos = inMemoryRepositories();
  final store = LocalAttachmentStore(root.path, repos.attachments);
  const sha =
      'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

  final srcA = _writeSource(dir.path, '源图.png', 'PNGBYTES-HELLO');
  final destA =
      await store.save(sourcePath: srcA, sha256: sha, fileName: '源图.png');

  final segs = p.split(destA).map((e) => e.toLowerCase()).toList();
  check(
      'save 落到内容寻址两级目录（<sha[0:2]>/<sha>.<ext>）',
      segs.contains('a1') &&
          p.basenameWithoutExtension(destA).toLowerCase() == sha,
      'segs=$segs');
  check('save 路径在 root 之内', AttachmentPolicy.isInsideRoot(destA, root.path));
  check('save 写出扩展名 .png', destA.endsWith('.png'));
  check('物理文件已存在', File(destA).existsSync());
  check('内容与源文件一致', File(destA).readAsStringSync() == 'PNGBYTES-HELLO');
  check('无 .part 临时残留', !File('$destA.part').existsSync());

  // 同 sha256 二次 save：**不复制**——把源文件改成不同字节，dest 必须保持原样。
  final before = File(destA).lastModifiedSync();
  final beforeLen = File(destA).lengthSync();
  _writeSource(dir.path, '源图.png', 'PNGBYTES-CHANGED-XXXXXXXX');
  final destAgain =
      await store.save(sourcePath: srcA, sha256: sha, fileName: '源图.png');
  check('同 sha256 二次 save 返回同一路径', destAgain == destA);
  check('同 sha256 二次 save **未覆盖**（内容不变）',
      File(destA).readAsStringSync() == 'PNGBYTES-HELLO');
  check('同 sha256 二次 save 未改变长度', File(destA).lengthSync() == beforeLen);
  check('同 sha256 二次 save 未刷新 mtime', File(destA).lastModifiedSync() == before);

  check('exists 命中', await store.exists(destA));
  check('exists 未命中返回 false',
      !(await store.exists('$root${Platform.pathSeparator}nope.png')));

  // 引用计数走 DB（不是 IO）：未插行 → 0；插 1 行 → 1；排除自身 → 0。
  check('referenceCount 初始为 0（无 DB 行）',
      await store.referenceCount(destA, excludeId: 'x') == 0);
  await repos.attachments.insertAttachment(Attachment(
    id: 'x',
    messageId: 'm1',
    kind: AttachmentKind.image,
    fileName: 'a.png',
    storedPath: destA,
    sha256: sha,
    sizeBytes: 12,
    createdAt: 1,
  ));
  check('referenceCount 插行后为 1',
      await store.referenceCount(destA, excludeId: 'y') == 1);
  check('referenceCount 排除自身后为 0',
      await store.referenceCount(destA, excludeId: 'x') == 0);

  await store.deleteIfUnreferenced(destA);
  check('deleteIfUnreferenced 删掉物理文件', !File(destA).existsSync());
  check('deleteIfUnreferenced 对不存在文件不抛异常',
      await _silent(() => store.deleteIfUnreferenced(destA)));

  // 越界删除拒绝（防脏值删到根目录之外）。
  var threw = false;
  try {
    await store.deleteIfUnreferenced(
        '${dir.path}${Platform.pathSeparator}outside.png');
  } on ValidationError catch (e) {
    threw = e.code == 'attach.path_escape';
  }
  check('deleteIfUnreferenced 拒绝根目录之外的路径（attach.path_escape）', threw);

  // 源文件缺失 → save 抛 StorageError（不静默）。
  var threwMiss = false;
  try {
    await store.save(
        sourcePath: '${dir.path}${Platform.pathSeparator}nothere.png',
        sha256:
            'f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2d3c4b5a6f1e2',
        fileName: 'nope.png');
  } on StorageError catch (e) {
    threwMiss = e.code == 'attach.source_missing';
  }
  check('源文件缺失 → StorageError(attach.source_missing)', threwMiss);

  // sha256 非法 → save 抛 ValidationError（绝不拼出逃逸路径）。
  var threwSha = false;
  try {
    await store.save(sourcePath: srcA, sha256: 'zz', fileName: '源图.png');
  } on ValidationError catch (e) {
    threwSha = e.code == 'attach.sha_invalid';
  }
  check('sha256 非法 → ValidationError(attach.sha_invalid)', threwSha);

  // 归属红线：本类零扫盘（QA 可 grep：listSync 零出现）。
  final text = _readSourceText('lib/application/attachment_store.dart');
  check(
      'LocalAttachmentStore 源码零 listSync 调用（绝不扫盘）',
      text.isNotEmpty && !RegExp(r'\.listSync\s*\(').hasMatch(text),
      text.isEmpty ? '未定位到源码文件' : null);
}

// ---------------------------------------------------------------------------
// 8. AttachmentService 两阶段（纯校验 / 内容寻址去重 / 失败隔离）
// ---------------------------------------------------------------------------

Future<void> _verifyAttachmentService(Directory dir) async {
  section('8. AttachmentService 两阶段（纯校验 / 去重 / 失败隔离）');

  final root = Directory('${dir.path}${Platform.pathSeparator}svc')
    ..createSync(recursive: true);
  final repos = inMemoryRepositories();
  final store = LocalAttachmentStore(root.path, repos.attachments);
  final svc = AttachmentService(repos, store);

  // ---- 阶段① draft：纯校验，不落盘不落库 ----
  final ok = AttachmentService.draft(
      sourcePath: '${dir.path}${Platform.pathSeparator}x.png',
      fileName: '示意图.png',
      sizeBytes: 1024);
  check(
      'draft 通过 → status = ready', ok.status == PendingAttachmentStatus.ready);
  check('draft 通过 → error 为 null', ok.error == null);
  check('draft 产出 kind = image', ok.kind == AttachmentKind.image);
  check('draft 产出安全化文件名', ok.fileName == '示意图.png');

  final tooBig = AttachmentService.draft(
      sourcePath: '${dir.path}${Platform.pathSeparator}big.png',
      fileName: 'big.png',
      sizeBytes: AttachmentPolicy.kMaxAttachmentBytes + 1);
  check('draft 超限 → status = rejected',
      tooBig.status == PendingAttachmentStatus.rejected);
  check('draft 超限 → 带明确原因（不静默）',
      tooBig.error != null && tooBig.error!.contains('超过'));
  check('draft 阶段不落盘（root 仍空）', root.listSync().whereType<File>().isEmpty);
  check('draft 阶段不落库',
      (await repos.attachments.listAttachmentsByMessages(['x'])).isEmpty);

  final badType = AttachmentService.draft(
      sourcePath: 'a.sh', fileName: 'run.sh', sizeBytes: 10);
  check('draft 类型不符 → rejected + 原因含类型',
      badType.status == PendingAttachmentStatus.rejected);

  final sanitized = AttachmentService.draft(
      sourcePath: 'a.pdf', fileName: '../../etc/passwd', sizeBytes: 10);
  check('draft 对非法类型/无扩展名 → rejected',
      sanitized.status == PendingAttachmentStatus.rejected);

  // ---- 阶段② send：成功 + 落库 + 落盘 ----
  await repos.conversations.upsertConversation(Conversation(
    id: 'conv_svc',
    type: ConversationType.single,
    createdAt: 1,
    updatedAt: 1,
  ));
  await repos.messages.insertMessage(_msg('msg_svc', 'conv_svc'));

  final srcA = _writeSource(dir.path, 'a.png', 'SAME-CONTENT');
  final pA = AttachmentService.draft(
      sourcePath: srcA, fileName: 'a.png', sizeBytes: 12);
  final rA = await svc.send(messageId: 'msg_svc', pending: pA);
  check('send 成功', rA.ok && rA.attachment != null);
  check('send 落库', (await svc.forMessage('msg_svc')).length == 1);
  check('send 落盘', File(rA.attachment!.storedPath).existsSync());
  check('send 记录 sizeBytes 为实际字节', rA.attachment!.sizeBytes == 12);
  check('send 记录 mimeType', rA.attachment!.mimeType == 'image/png');

  // ---- 内容寻址去重：另一条消息传同内容 → 同一 storedPath，物理文件只 1 份 ----
  await repos.messages.insertMessage(_msg('msg_svc2', 'conv_svc'));
  final srcB = _writeSource(dir.path, 'a_副本.png', 'SAME-CONTENT');
  final rB = await svc.send(
      messageId: 'msg_svc2',
      pending: AttachmentService.draft(
          sourcePath: srcB, fileName: 'a_副本.png', sizeBytes: 12));
  check('同内容第二次 send 成功', rB.ok);
  check('同内容复用**同一 storedPath**（不复制两份）',
      rB.attachment!.storedPath == rA.attachment!.storedPath);
  check('同内容 sha256 相同', rA.attachment!.sha256 == rB.attachment!.sha256);
  final physicalCount = root
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => !f.path.endsWith('.part'))
      .length;
  checkEq('物理文件仍只有 1 份（内容寻址去重）', physicalCount, 1);

  // ---- 失败隔离：源文件缺失 → 返回 failed，**消息照发** ----
  final missing = AttachmentService.draft(
      sourcePath: '${dir.path}${Platform.pathSeparator}gone.pdf',
      fileName: 'gone.pdf',
      sizeBytes: 10);
  final rMiss = await svc.send(messageId: 'msg_svc', pending: missing);
  check('源文件缺失 → send 返回 failed（不抛异常）',
      !rMiss.ok && rMiss.pending.status == PendingAttachmentStatus.failed);
  check('源文件缺失 → 带明确原因', rMiss.error != null && rMiss.error!.contains('找不到'));
  check('失败隔离：消息仍在（未因附件失败被删）',
      (await repos.messages.getMessage('msg_svc')) != null);
  check('失败隔离：已成功的附件仍在', (await svc.forMessage('msg_svc')).length == 1);
  check('失败隔离：未插入附件行', !rMiss.ok && rMiss.attachment == null);

  // rejected 的 pending 直接 send → 不碰 IO、不落库。
  final beforeCount = (await svc.forMessage('msg_svc')).length;
  final rRej = await svc.send(messageId: 'msg_svc', pending: tooBig);
  check('rejected pending → send 直接 failed（不抛异常）', !rRej.ok);
  check('rejected pending → 不新增附件行',
      (await svc.forMessage('msg_svc')).length == beforeCount);

  // ---- 落库失败 → 物理文件被立即清理（避免孤儿） ----
  final root2 = Directory('${dir.path}${Platform.pathSeparator}svc2')
    ..createSync(recursive: true);
  final repos2 = inMemoryRepositories();
  final store2 = LocalAttachmentStore(root2.path, repos2.attachments);
  final svcThrow = AttachmentService(
      _reposWith(repos2, attachments: _ThrowingInsertRepo(repos2.attachments)),
      store2);
  final srcC = _writeSource(dir.path, 'c.pdf', 'PDF-CONTENT');
  final rThrow = await svcThrow.send(
      messageId: 'msg_svc2',
      pending: AttachmentService.draft(
          sourcePath: srcC, fileName: 'c.pdf', sizeBytes: 11));
  check('落库失败 → send 返回 failed',
      !rThrow.ok && rThrow.error!.contains('保存附件记录失败'));
  check('落库失败 → 物理文件被清理（无孤儿）',
      root2.listSync(recursive: true).whereType<File>().isEmpty);
}

// ---------------------------------------------------------------------------
// 9. ConversationService.deleteMessage（铁律 + 双清 + 引用计数）
// ---------------------------------------------------------------------------

Future<void> _verifyDeleteMessage(Directory dir) async {
  section('9. ConversationService.deleteMessage（铁律 / 双清 / 引用计数）');

  final root = Directory('${dir.path}${Platform.pathSeparator}del')
    ..createSync(recursive: true);
  final repos = inMemoryRepositories();
  final store = LocalAttachmentStore(root.path, repos.attachments);
  final conv = ConversationService(repos, attachmentStore: store);
  final svc = AttachmentService(repos, store);

  await repos.conversations.upsertConversation(Conversation(
    id: 'conv_del',
    type: ConversationType.single,
    createdAt: 1,
    updatedAt: 1,
  ));
  await repos.messages.insertMessage(_msg('u1', 'conv_del'));
  await repos.messages.insertMessage(_msg('e1', 'conv_del',
      sender: MessageSenderType.expert, content: '专家回复'));

  final src = _writeSource(dir.path, '图.png', 'DEL-CONTENT');
  final r1 = await svc.send(
      messageId: 'u1',
      pending: AttachmentService.draft(
          sourcePath: src, fileName: '图.png', sizeBytes: 11));
  final r2 = await svc.send(
      messageId: 'e1',
      pending: AttachmentService.draft(
          sourcePath: src, fileName: '图2.png', sizeBytes: 11));
  check(
      '前置：u1 / e1 各有 1 个附件',
      (await svc.forMessage('u1')).length == 1 &&
          (await svc.forMessage('e1')).length == 1);
  final sharedPath = r1.attachment!.storedPath;
  check('前置：两消息共享同一 storedPath', r2.attachment!.storedPath == sharedPath);
  check('前置：引用计数 = 2',
      await repos.attachments.countByStoredPath(sharedPath) == 2);

  // ---- 铁律：专家消息一律不可删（fail-closed） ----
  var threwExpert = false;
  try {
    await conv.deleteMessage('conv_del', 'e1');
  } on ValidationError catch (e) {
    threwExpert = e.code == 'message.not_deletable';
  }
  check('**铁律**：删专家消息被拒（message.not_deletable）', threwExpert);
  check('铁律生效：专家消息仍在', (await repos.messages.getMessage('e1')) != null);
  check('铁律生效：专家附件行未动', (await svc.forMessage('e1')).length == 1);
  check('铁律生效：物理文件未被误删', File(sharedPath).existsSync());

  // ---- 删用户消息：双清 + 物理文件因仍被引用而**保留** ----
  final res = await conv.deleteMessage('conv_del', 'u1');
  check('删用户消息成功', res.messageId == 'u1');
  check('消息行已删', (await repos.messages.getMessage('u1')) == null);
  check('附件行已删（显式删生效）', (await svc.forMessage('u1')).isEmpty);
  check('物理文件**保留**（e1 仍引用，计数 1）', File(sharedPath).existsSync());
  check('purgedFiles 为空（无物理清理）', res.purgedFiles.isEmpty);

  // ---- 删最后一条引用 → 物理文件被清理 ----
  await repos.messages.insertMessage(_msg('u2', 'conv_del'));
  final src3 = _writeSource(dir.path, '唯一.pdf', 'ONLY-CONTENT');
  final r3 = await svc.send(
      messageId: 'u2',
      pending: AttachmentService.draft(
          sourcePath: src3, fileName: '唯一.pdf', sizeBytes: 11));
  final only3 = r3.attachment!.storedPath;
  check('前置：唯一.pdf 只被 u2 引用',
      await repos.attachments.countByStoredPath(only3) == 1);
  final res3 = await conv.deleteMessage('conv_del', 'u2');
  check('删后物理文件被清理（引用计数归零）', !File(only3).existsSync());
  check('purgedFiles 记录了被删路径', res3.purgedFiles.contains(only3));

  // ---- 同一条消息内重复同内容 → 只删一次物理文件 ----
  await repos.messages.insertMessage(_msg('u3', 'conv_del'));
  final src4 = _writeSource(dir.path, '双份.png', 'TWICE');
  await svc.send(
      messageId: 'u3',
      pending: AttachmentService.draft(
          sourcePath: src4, fileName: 'A.png', sizeBytes: 5));
  await svc.send(
      messageId: 'u3',
      pending: AttachmentService.draft(
          sourcePath: src4, fileName: 'B.png', sizeBytes: 5));
  final both = await svc.forMessage('u3');
  check('前置：同一消息 2 条附件、同一 storedPath',
      both.length == 2 && both.first.storedPath == both.last.storedPath);
  final res4 = await conv.deleteMessage('conv_del', 'u3');
  check('同内容多行：附件行全删', (await svc.forMessage('u3')).isEmpty);
  check('同内容多行：物理文件只删一次且已删', !File(both.first.storedPath).existsSync());
  check('同内容多行：purgedFiles 去重后仅 1 条', res4.purgedFiles.length == 1);

  // ---- 其它 fail-closed 分支 ----
  var threwMissing = false;
  try {
    await conv.deleteMessage('conv_del', 'nope');
  } on ValidationError catch (e) {
    threwMissing = e.code == 'message.notfound';
  }
  check('删不存在消息 → ValidationError(message.notfound)', threwMissing);

  await repos.conversations.upsertConversation(Conversation(
    id: 'conv_other',
    type: ConversationType.single,
    createdAt: 1,
    updatedAt: 1,
  ));
  await repos.messages.insertMessage(_msg('u_other', 'conv_other'));
  var threwCross = false;
  try {
    await conv.deleteMessage('conv_del', 'u_other');
  } on ValidationError catch (e) {
    threwCross = e.code == 'message.notfound';
  }
  check('跨会话删 → ValidationError（防越权）', threwCross);
  check('跨会话删失败后消息仍在', (await repos.messages.getMessage('u_other')) != null);

  // ---- 批量预载 ----
  await repos.messages.insertMessage(_msg('u4', 'conv_del'));
  final src5 = _writeSource(dir.path, '预载.zip', 'ZIPB');
  await svc.send(
      messageId: 'u4',
      pending: AttachmentService.draft(
          sourcePath: src5, fileName: '预载.zip', sizeBytes: 4));
  await repos.messages.insertMessage(_msg('u5', 'conv_del', content: '纯文字'));
  final map = await conv.listMessagesWithAttachments('conv_del');
  final withAttach = map.entries.where((e) => e.value.isNotEmpty).length;
  checkEq('listMessagesWithAttachments 批量预载（e1 + u4 共 2 条带附件）', withAttach, 2);
  check('listMessagesWithAttachments 一次查全（总条数 = 消息行数）', map.length >= 3);
  check('listMessagesWithAttachments 无附件的消息映射空列表',
      map.values.any((v) => v.isEmpty));
  check('批量预载返回的附件按 createdAt 归属正确消息',
      map.entries.any((e) => e.key.id == 'e1' && e.value.length == 1));

  // ---- 未注入 store → 只清 DB 行（不动物理文件） ----
  final repos3 = inMemoryRepositories();
  final conv3 = ConversationService(repos3);
  await repos3.conversations.upsertConversation(Conversation(
    id: 'conv_n',
    type: ConversationType.single,
    createdAt: 1,
    updatedAt: 1,
  ));
  await repos3.messages.insertMessage(_msg('un', 'conv_n'));
  final rn = await conv3.deleteMessage('conv_n', 'un');
  check('未注入 store：deleteMessage 仍完成（只清 DB 行）', rn.removedAttachments == 0);
  check('未注入 store：purgedFiles 为空', rn.purgedFiles.isEmpty);
}

Future<bool> _silent(Future<void> Function() fn) async {
  try {
    await fn();
    return true;
  } catch (_) {
    return false;
  }
}

/// 替换聚合中的某一个仓储（便于注入"会抛错的替身"）。
Repositories _reposWith(Repositories base,
        {AttachmentRepository? attachments}) =>
    Repositories(
      experts: base.experts,
      groups: base.groups,
      conversations: base.conversations,
      messages: base.messages,
      generations: base.generations,
      knowledge: base.knowledge,
      providers: base.providers,
      credentials: base.credentials,
      secrets: base.secrets,
      market: base.market,
      settings: base.settings,
      jobs: base.jobs,
      attachments: attachments ?? base.attachments,
    );

// ---------------------------------------------------------------------------
// 10. deleteMessage 的"引用计数决策"（假 store，只断言决策不碰真实 FS）
// ---------------------------------------------------------------------------

Future<void> _verifyDeleteDecisionWithFakeStore() async {
  section('10. deleteMessage 引用计数决策（假 store，断言决策）');

  final repos = inMemoryRepositories();
  final fake = _RecordingStore();
  fake.references['/stale/kept.png'] = 1; // 仍被引用
  fake.references['/stale/gone.png'] = 0; // 无人引用
  final conv = ConversationService(repos, attachmentStore: fake);

  await repos.conversations.upsertConversation(Conversation(
    id: 'conv_f',
    type: ConversationType.single,
    createdAt: 1,
    updatedAt: 1,
  ));
  await repos.messages.insertMessage(_msg('uf', 'conv_f'));
  for (final (id, path) in [
    ('fa', '/stale/kept.png'),
    ('fb', '/stale/gone.png')
  ]) {
    await repos.attachments.insertAttachment(Attachment(
      id: id,
      messageId: 'uf',
      kind: AttachmentKind.file,
      fileName: '$id.png',
      storedPath: path,
      sha256:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      sizeBytes: 1,
      createdAt: 1,
    ));
  }

  final res = await conv.deleteMessage('conv_f', 'uf');
  checkEq('只清理"引用计数归零"的那 1 个（kept 不动）', res.purgedFiles.length, 1);
  check('被清理的正是 gone.png', res.purgedFiles.contains('/stale/gone.png'));
  check('仍被引用的 kept.png 未进清理列表', !res.purgedFiles.contains('/stale/kept.png'));
  check('假 store 的 deleted 只收到 gone.png',
      fake.deleted.length == 1 && fake.deleted.single == '/stale/gone.png');
  check('removedAttachments = 2', res.removedAttachments == 2);
}

// ---------------------------------------------------------------------------
// 11. 附件告知注入（第 8 轮 T51：让专家"知道"用户发了附件）
// ---------------------------------------------------------------------------

/// 记录全部请求的脚本化 LLM（供断言"实际传给模型的 userTask"）。
///
/// 群聊多位发言者的回复**逐次不同**（带序号），避开 [DuplicateDetector]
/// 相似度阈值，确保 accepted ≥ 2 → 总结者必然被触发。
class _AttLlm implements LlmProvider {
  _AttLlm({this.providerId = 'pp_att'});

  @override
  final String providerId;

  final List<ChatRequest> calls = [];

  int _replySeq = 0;

  /// 发言内容池：逐条**强异质**（不同主题词），确保各位发言者的 bigram 集合
  /// 几乎不重叠，躲开 [DuplicateDetector] 相似度阈值（同主题只换序号会被判重复）。
  static const List<String> _remarks = [
    '需关注资质要求与工期条款',
    '风险集中在付款条件与违约责任',
    '建议补充评标办法与评分细则',
    '注意保证金与履约保证条款',
  ];

  @override
  Future<List<ModelDescriptor>> listModels() async =>
      const [ModelDescriptor(modelId: 'deepseek-chat')];

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    calls.add(request);
    return const ChatResponse(
        content: 'ok', promptTokens: 1, completionTokens: 1);
  }

  @override
  Stream<StreamEvent> stream(ChatRequest request) async* {
    calls.add(request);
    _replySeq++;
    // 总结调用的 system 含「只输出 JSON」（Summarizer.buildPrompt 首条）。
    final isSummary = request.messages.first.content.contains('只输出 JSON');
    yield TokenDelta(isSummary
        ? '{"consensus":["附件内容待用户粘贴后补充"],"recommendations":["请用户粘贴关键内容"]}'
        : '已收到附件，${_remarks[_replySeq % _remarks.length]}。');
    yield const UsageEvent(3, 3);
    yield const StreamDone();
  }

  @override
  Future<ProviderHealth> healthCheck() async =>
      const ProviderHealth(health: Health.healthy, latencyMs: 1);

  @override
  AppError mapError(Object raw) =>
      raw is AppError ? raw : ProviderServerError('$raw');
}

/// 附件查询必抛的仓储替身（验证失败隔离：不中断运行、回退原文本）。
class _ThrowingListRepo implements AttachmentRepository {
  _ThrowingListRepo(this._inner);

  final AttachmentRepository _inner;

  @override
  Future<List<Attachment>> listAttachmentsByMessage(String messageId) async =>
      throw const StorageError('storage.attachments.list', '模拟附件查询失败');

  @override
  Future<List<Attachment>> listAttachmentsByMessages(
          List<String> messageIds) async =>
      throw const StorageError('storage.attachments.list', '模拟附件查询失败');

  @override
  Future<void> insertAttachment(Attachment a) async =>
      _inner.insertAttachment(a);

  @override
  Future<void> insertAttachments(List<Attachment> list) async =>
      _inner.insertAttachments(list);

  @override
  Future<Attachment?> findBySha256(String sha256) =>
      _inner.findBySha256(sha256);

  @override
  Future<int> countByStoredPath(String storedPath, {String? excludeId}) =>
      _inner.countByStoredPath(storedPath, excludeId: excludeId);

  @override
  Future<void> deleteByMessage(String messageId) =>
      _inner.deleteByMessage(messageId);
}

Attachment _att(String id, String messageId, String fileName,
        AttachmentKind kind, int sizeBytes) =>
    Attachment(
      id: id,
      messageId: messageId,
      kind: kind,
      fileName: fileName,
      storedPath: '/store/$id.bin',
      sha256:
          'ab12cd34ef567890ab12cd34ef567890ab12cd34ef567890ab12cd34ef567890',
      sizeBytes: sizeBytes,
      createdAt: 1,
    );

/// 单聊 / 群聊共用的可跑装置（注入 [_AttLlm] 记录每次请求）。
class _AttRig {
  _AttRig({
    required this.repos,
    required this.conversations,
    required this.gen,
    required this.group,
    required this.llm,
    required this.expertId,
    required this.convId,
  });

  final Repositories repos;
  final ConversationService conversations;
  final GenerationService gen;
  final GroupService group;
  final _AttLlm llm;
  final String expertId;
  final String convId;

  /// 真跑单聊（async* 惰性，必须消费才执行）。返回全部更新（第 9 轮 §12⑥
  /// 需要从中挑 RunFailedUpdate 断言错误码）。
  Future<List<GenerationUpdate>> runSingle(
          String userMessageId, String userText) =>
      gen
          .runSingleChat(
              conversationId: convId,
              userMessageId: userMessageId,
              userText: userText)
          .toList();

  /// 真跑群聊（同上，必须消费）。
  Future<void> runGroup(String userMessageId, String userText) => group
      .runGroupChat(
          conversationId: convId,
          userMessageId: userMessageId,
          userText: userText)
      .toList();
}

Future<_AttRig> _buildAttRig(
    {AttachmentRepository? attachments, bool group = false, bool vision = false}) async {
  final base = inMemoryRepositories();
  final repos =
      attachments == null ? base : _reposWith(base, attachments: attachments);
  final now = DateTime.now().millisecondsSinceEpoch;

  await repos.providers.upsertProvider(const ProviderProfile(
      id: 'pp_att',
      providerId: 'deepseek',
      displayName: 'ATT',
      baseUrl: 'https://att.local'));
  // vision=true（第 9 轮 §12⑦⑧）：同 id 换一枚 supportsVision=true 的档案，
  // 让专家生效模型解析到它（默认档案 supportsVision=false，供 §12⑥ 用）。
  await repos.providers.upsertModel(vision
      ? const ModelProfile(
          id: 'mp_deepseek_chat',
          providerProfileId: 'pp_att',
          modelId: 'deepseek-chat',
          supportsVision: true,
        )
      : ModelProfile.deepseekChat(providerProfileId: 'pp_att'));
  await repos.credentials.upsert(CredentialProfile(
      id: 'cr_att',
      providerProfileId: 'pp_att',
      name: 'k',
      secretRef: 'ref_att',
      createdAt: now,
      updatedAt: now));
  await repos.secrets.write('ref_att', 'sk-att');
  await repos.settings
      .set(SettingKeys.defaultModelProfileId, 'mp_deepseek_chat');
  await repos.settings.set(SettingKeys.defaultCredentialProfileId, 'cr_att');

  final experts = ExpertService(repos);
  final conversations = ConversationService(repos);
  final knowledge = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(targetTokens: 120),
    vectorStore: InMemoryVectorStore(repos.knowledge),
  );
  final llm = _AttLlm();
  final gen = GenerationService(
    repos,
    experts: experts,
    conversations: conversations,
    knowledge: knowledge,
    llmFactory: (_) => llm,
  );
  final gs = GroupService(
    repos,
    experts: experts,
    conversations: conversations,
    knowledge: knowledge,
    llmFactory: (_) => llm,
  );

  if (group) {
    final a = await experts.createLocal(name: '组长', systemPrompt: '你是本群负责人。');
    final b = await experts.createLocal(name: '法律顾问', systemPrompt: '你是法律顾问。');
    final conv = await conversations.createGroup(
      title: '评标群',
      expertIds: [a.id, b.id],
      leaderExpertId: a.id,
    );
    return _AttRig(
        repos: repos,
        conversations: conversations,
        gen: gen,
        group: gs,
        llm: llm,
        expertId: a.id,
        convId: conv.id);
  }
  final expert =
      await experts.createLocal(name: '招标顾问', systemPrompt: '你是招标顾问。');
  final conv = await conversations.createSingle(expert.id);
  return _AttRig(
      repos: repos,
      conversations: conversations,
      gen: gen,
      group: gs,
      llm: llm,
      expertId: expert.id,
      convId: conv.id);
}

/// ContextManager.build 的最后一条即 userTask（`ChatMessage(ChatRole.user, userTask)`）。
String _lastUserTask(ChatRequest request) => request.messages.last.content;

Future<void> _verifyAttachmentNotice() async {
  section('11. 附件告知注入（专家"知道"用户发了附件，T51）');

  const userText = '请帮我看看这个招标文件';
  // 体积取值按「AttachmentPolicy.formatBytes 实际输出」反推，不写死错值：
  //   1258291 B /1024/1024 ≈ 1.1999998 → '1.2MB'
  //   3565158 B /1024/1024 ≈ 3.3999996 → '3.4MB'
  const imgBytes = 1258291;
  const pdfBytes = 3565158;
  checkEq('体积格式化确认（1258291B → 1.2MB）', AttachmentPolicy.formatBytes(imgBytes),
      '1.2MB');
  checkEq('体积格式化确认（3565158B → 3.4MB）', AttachmentPolicy.formatBytes(pdfBytes),
      '3.4MB');

  // ---- ① 无附件 → userTask 逐字等于原文本（防回归关键断言）----
  final rig1 = await _buildAttRig();
  final u1 = await rig1.conversations.appendUserMessage(rig1.convId, userText);
  await rig1.runSingle(u1.id, userText);
  checkEq('① 无附件：LLM 恰被调用 1 次', rig1.llm.calls.length, 1);
  checkEq('① 无附件：末条消息 role = user', rig1.llm.calls.single.messages.last.role,
      ChatRole.user);
  checkEq('① 无附件：传给模型的 userTask **逐字等于**原文本',
      _lastUserTask(rig1.llm.calls.single), userText);

  // ---- ② 1 个图片附件 → 含告知段 / 文件名 / 类型中文 / 体积 ----
  final rig2 = await _buildAttRig();
  final u2 = await rig2.conversations.appendUserMessage(rig2.convId, userText);
  await rig2.repos.attachments.insertAttachment(
      _att('att_img', u2.id, 'a.png', AttachmentKind.image, imgBytes));
  await rig2.runSingle(u2.id, userText);
  final task2 = _lastUserTask(rig2.llm.calls.single);
  check('② 含「【用户附件】」标记', task2.contains('【用户附件】'));
  check('② 含文件名 a.png', task2.contains('a.png'));
  check('② 含图片类型中文「图片」', task2.contains('图片'));
  check('② 含体积 1.2MB（formatBytes 实际输出）',
      task2.contains(AttachmentPolicy.formatBytes(imgBytes)));
  check('② 含计数 N=1', task2.contains('附带 1 个文件'));
  check('② 含引导句（请用户粘贴文字）', task2.contains('请以文字告知用户你已收到附件'));
  check('② 以原文本开头（追加而非替换）', task2.startsWith(userText));
  check('② 告知段前恰有两个换行', task2.contains('$userText\n\n【用户附件】'));

  // ---- ③ 2 个附件（一图一文）→ N=2、两行都在 ----
  final rig3 = await _buildAttRig();
  final u3 = await rig3.conversations.appendUserMessage(rig3.convId, userText);
  await rig3.repos.attachments.insertAttachment(
      _att('att_img3', u3.id, 'a.png', AttachmentKind.image, imgBytes));
  await rig3.repos.attachments.insertAttachment(
      _att('att_pdf3', u3.id, 'b.pdf', AttachmentKind.file, pdfBytes));
  await rig3.runSingle(u3.id, userText);
  final task3 = _lastUserTask(rig3.llm.calls.single);
  check('③ 计数 N=2 正确', task3.contains('附带 2 个文件'));
  check('③ 图片行在（- a.png（图片，1.2MB））', task3.contains('- a.png（图片，1.2MB）'));
  check('③ 文件行在（- b.pdf（文件，3.4MB））', task3.contains('- b.pdf（文件，3.4MB）'));
  check('③ 图片行在文件行之前（按入库顺序）',
      task3.indexOf('- a.png') < task3.indexOf('- b.pdf'));

  // ---- ④ 附件仓储抛错 → 运行不中断、userTask 回退为原文本 ----
  final rig4 = await _buildAttRig(
      attachments: _ThrowingListRepo(inMemoryRepositories().attachments));
  final u4 = await rig4.conversations.appendUserMessage(rig4.convId, userText);
  await rig4.runSingle(u4.id, userText);
  check('④ 附件查询抛错：LLM 仍被调用（运行未中断）', rig4.llm.calls.length == 1);
  checkEq('④ 附件查询抛错：userTask 回退为原文本', _lastUserTask(rig4.llm.calls.single),
      userText);

  // ---- ⑤ 群聊：每位发言者与总结者都注入（用户文本触发"全员发言"指令）----
  const groupText = '大家看看这个招标文件的风险';
  final rig5 = await _buildAttRig(group: true);
  final u5 = await rig5.conversations.appendUserMessage(rig5.convId, groupText);
  await rig5.repos.attachments.insertAttachment(
      _att('att_g', u5.id, '招标文件.pdf', AttachmentKind.file, pdfBytes));
  await rig5.runGroup(u5.id, groupText);

  final memberCalls5 = rig5.llm.calls
      .where((c) => !c.messages.first.content.contains('只输出 JSON'))
      .toList();
  final summaryCalls5 = rig5.llm.calls
      .where((c) => c.messages.first.content.contains('只输出 JSON'))
      .toList();
  check('⑤ 前置：至少 2 位发言者（确保总结者被触发）', memberCalls5.length >= 2);
  check('⑤ 前置：发生了总结调用', summaryCalls5.isNotEmpty);
  check('⑤ 每位发言者的 userTask 都含告知段',
      memberCalls5.every((c) => _lastUserTask(c).contains('【用户附件】')));
  check('⑤ 每位发言者的 userTask 都含附件文件名',
      memberCalls5.every((c) => _lastUserTask(c).contains('招标文件.pdf')));
  check('⑤ 每位发言者的 userTask 都以原文本开头',
      memberCalls5.every((c) => _lastUserTask(c).startsWith(groupText)));
  check('⑤ 总结者的 userTask 也含告知段',
      summaryCalls5.every((c) => _lastUserTask(c).contains('【用户附件】')));
  check('⑤ 总结者的 userTask 也含附件文件名',
      summaryCalls5.every((c) => _lastUserTask(c).contains('招标文件.pdf')));
  check('⑤ 总结者 userTask 中的原任务文本逐字在',
      summaryCalls5.every((c) => _lastUserTask(c).contains('用户任务：$groupText')));

  // ---- ⑥ 群聊无附件 → 全体 userTask 逐字等于原文本（防回归）----
  final rig6 = await _buildAttRig(group: true);
  final u6 = await rig6.conversations.appendUserMessage(rig6.convId, groupText);
  await rig6.runGroup(u6.id, groupText);

  final memberCalls6 = rig6.llm.calls
      .where((c) => !c.messages.first.content.contains('只输出 JSON'))
      .toList();
  final summaryCalls6 = rig6.llm.calls
      .where((c) => c.messages.first.content.contains('只输出 JSON'))
      .toList();
  check('⑥ 前置：群聊无附件也发生了总结调用', summaryCalls6.isNotEmpty);
  check(
      '⑥ 群聊无附件：每位发言者的 userTask 逐字等于原文本',
      memberCalls6.isNotEmpty &&
          memberCalls6.every((c) => _lastUserTask(c) == groupText));
  check('⑥ 群聊无附件：总结者的 userTask 逐字包含原任务文本',
      summaryCalls6.every((c) => _lastUserTask(c).contains('用户任务：$groupText')));

  // ---- ⑦ 源码级回归：检索 query 仍用原始 userText（附件名不得混入检索式）----
  final src = _readSourceText('lib/application/services.dart');
  final querySites =
      RegExp(r'knowledge\.retrieveForExpert\([^)]*query:\s*userText\)')
          .allMatches(src)
          .length;
  checkEq('⑦ 检索 query 仍为原始 userText（单聊+群聊共 2 处，附件名不混入）', querySites, 2);
  check('⑦ 告知段文案在 services.dart 中集中构造一次（无第二处硬编码）', src.contains('【用户附件】'));
}

// ---------------------------------------------------------------------------
// 12. 文档阅读（解析器抽文本注入）+ 图片多模态（supports_vision 门控）
//     第 9 轮：只增不改既有断言（§11 全部保留，见上）。
// ---------------------------------------------------------------------------

/// 1x1 PNG 载荷——真实图片附件用。
///
/// ⚠️ advisor_core 侧只读字节转 base64、**不解码**，故这里不断言其可解码性；
/// **DeepSeek 端点是否真的接受图片 parts，只有实机发一次才知道**（pending）。
///
/// 自包含构造（zlib stored block + CRC32/adler32 现场算），避免手抄 base64
/// 踩 padding 坑；产物是语法合法的 1x1 RGBA 透明 PNG。
final List<int> _kPngBytes = _buildTinyPng();

/// 构造最小合法 PNG（1x1 RGBA 透明）。
List<int> _buildTinyPng() {
  int adler32(List<int> data) {
    var a = 1;
    var b = 0;
    for (final byte in data) {
      a = (a + byte) % 65521;
      b = (b + a) % 65521;
    }
    return (b << 16) | a;
  }

  int crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        final mask = -(crc & 1);
        crc = (crc >> 1) ^ (0xEDB88320 & mask);
      }
    }
    return ~crc & 0xFFFFFFFF;
  }

  List<int> chunk(String type, List<int> data) {
    final typed = <int>[...type.codeUnits, ...data];
    final crc = crc32(typed);
    return <int>[
      (data.length >> 24) & 0xFF,
      (data.length >> 16) & 0xFF,
      (data.length >> 8) & 0xFF,
      data.length & 0xFF,
      ...typed,
      (crc >> 24) & 0xFF,
      (crc >> 16) & 0xFF,
      (crc >> 8) & 0xFF,
      crc & 0xFF,
    ];
  }

  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  const ihdr = [
    0, 0, 0, 1, // width = 1
    0, 0, 0, 1, // height = 1
    8, 6, 0, 0, 0, // 8bit / RGBA / deflate / adaptive / 无交错
  ];
  // zlib stored block：filter(0) + RGBA(0,0,0,0)，外加 zlib 头与 adler32。
  final raw = const [0, 0, 0, 0, 0];
  final adler = adler32(raw);
  final idat = <int>[
    0x78, 0x01, // zlib 头（无字典）
    0x01, // BFINAL=1, BTYPE=00（stored）
    0x05, 0x00, // LEN = 5
    0xFA, 0xFF, // NLEN = ~5
    ...raw,
    (adler >> 24) & 0xFF,
    (adler >> 16) & 0xFF,
    (adler >> 8) & 0xFF,
    adler & 0xFF,
  ];
  return <int>[
    ...signature,
    ...chunk('IHDR', ihdr),
    ...chunk('IDAT', idat),
    ...chunk('IEND', const []),
  ];
}

/// 写真实临时文件（第 9 轮：附件指向真路径，解析器真读盘）。
Future<String> _writeRealFile(
    Directory dir, String name, List<int> bytes) async {
  final f = File(p.join(dir.path, name));
  await f.writeAsBytes(bytes);
  return f.path;
}

/// 真实路径版附件（storedPath 指向磁盘真文件；sha256 任意合法 64 位十六进制）。
Attachment _attReal(String id, String messageId, String fileName,
    AttachmentKind kind, String storedPath, int sizeBytes) {
  return Attachment(
    id: id,
    messageId: messageId,
    kind: kind,
    fileName: fileName,
    storedPath: storedPath,
    sha256:
        'ab12cd34ef567890ab12cd34ef567890ab12cd34ef567890ab12cd34ef567890',
    sizeBytes: sizeBytes,
    createdAt: 1,
  );
}

/// 量出注入区正文总字数：各段「——《…》正文（…）——\n」之后到段尾的内容之和
/// （段间分隔空行不计），用于断言单文档 ≤6000 / 单轮合计 ≤12000。
int _injectedBodiesLength(String task) {
  final end = task.indexOf('\n\n以上即附件正文');
  if (end < 0) return 0;
  var zone = task.substring(0, end);
  final first = zone.indexOf('——《');
  if (first < 0) return 0;
  zone = zone.substring(first);
  final bodies =
      zone.split(RegExp(r'——《[^》]+》正文（.*?）——\n'));
  var total = 0;
  for (final b in bodies) {
    total += b.trimRight().length;
  }
  return total;
}

Future<void> _verifyDocumentReadingAndVision(Directory tmpDir) async {
  section('12. 文档阅读（抽文本注入）+ 图片多模态（supports_vision 门控）');

  const userText = '请根据附件内容给出结论';

  // ---- ① 文档附件（真实 .txt，过 PlainTextParser）→ userTask 含解析出的正文 ----
  final rig1 = await _buildAttRig();
  final u1 = await rig1.conversations.appendUserMessage(rig1.convId, userText);
  final docPath = await _writeRealFile(
      tmpDir,
      '标书要点.txt',
      utf8.encode('招标控制价：4820 万元\n工期：365 日历天\n质量保证金：合同价格的 3%'));
  await rig1.repos.attachments.insertAttachment(_attReal(
      'att_doc1', u1.id, '标书要点.txt', AttachmentKind.file, docPath, 96));
  await rig1.runSingle(u1.id, userText);
  final task1 = _lastUserTask(rig1.llm.calls.single);
  check('① userTask 含解析出的正文片段（招标控制价：4820 万元）',
      task1.contains('招标控制价：4820 万元'));
  check('① 含「【附件正文】」注入标记', task1.contains('【附件正文】'));
  check('① 含解析器名 plain-text', task1.contains('plain-text'));
  check('① 仍以原文本开头（追加而非替换）', task1.startsWith(userText));
  check('① 未超限 → 注入文本无「已截断」标记', !task1.contains('已截断'));

  // ---- ② 单文档超上限 → 注入文本含「已截断」与原长标记（上限随常量演变，不写死数字）----
  final rig2 = await _buildAttRig();
  final u2 = await rig2.conversations.appendUserMessage(rig2.convId, userText);
  // 夹具按"上限 + 1 万"构造，保证无论上限调到多少都仍能触发截断分支。
  final overLen = kMaxDocCharsPerAttachment + 10000;
  final bigPath = await _writeRealFile(
      tmpDir, '超长.txt', utf8.encode('甲' * overLen));
  await rig2.repos.attachments.insertAttachment(_attReal(
      'att_doc2', u2.id, '超长.txt', AttachmentKind.file, bigPath, overLen));
  await rig2.runSingle(u2.id, userText);
  final task2 = _lastUserTask(rig2.llm.calls.single);
  check('② 单文档超上限 → 含「（已截断，原长 $overLen 字）」',
      task2.contains('（已截断，原长 $overLen 字）'));
  checkEq('② 单文档注入正文恰为单篇上限', _injectedBodiesLength(task2),
      kMaxDocCharsPerAttachment);

  // ---- ②-b 单轮合计上限：首篇占满单篇上限、次篇吃掉余量、第三篇被总量上限拦下 ----
  // （上限随常量演变，夹具按"上限 ± kMaxDocCharsPerRound 的余量"推算，不写死数字）
  final rig2b = await _buildAttRig();
  final u2b = await rig2b.conversations.appendUserMessage(rig2b.convId, userText);
  final remaining = kMaxDocCharsPerRound - kMaxDocCharsPerAttachment;
  final overB = kMaxDocCharsPerAttachment + 10000;
  final midB = remaining + 5000;
  final bigBPath =
      await _writeRealFile(tmpDir, '超长B.txt', utf8.encode('乙' * overB));
  await rig2b.repos.attachments.insertAttachment(_attReal(
      'att_doc2b1', u2b.id, '超长B.txt', AttachmentKind.file, bigBPath, overB));
  final midBPath =
      await _writeRealFile(tmpDir, '中等B.txt', utf8.encode('丙' * midB));
  await rig2b.repos.attachments.insertAttachment(_attReal(
      'att_doc2b2', u2b.id, '中等B.txt', AttachmentKind.file, midBPath, midB));
  final smallBPath = await _writeRealFile(tmpDir, '补充.txt',
      utf8.encode('补充条款：付款方式见合同第 12 条'));
  await rig2b.repos.attachments.insertAttachment(_attReal(
      'att_doc2b3', u2b.id, '补充.txt', AttachmentKind.file, smallBPath, 60));
  await rig2b.runSingle(u2b.id, userText);
  final task2b = _lastUserTask(rig2b.llm.calls.single);
  checkEq('②-b 前两篇各被截断（已截断标记 2 处）',
      '已截断'.allMatches(task2b).length, 2);
  check('②-b 首篇标注原长 $overB 字', task2b.contains('（已截断，原长 $overB 字）'));
  check('②-b 次篇标注原长 $midB 字', task2b.contains('（已截断，原长 $midB 字）'));
  checkEq('②-b 注入正文恰为单轮总量上限', _injectedBodiesLength(task2b),
      kMaxDocCharsPerRound);
  check('②-b 第三篇因总量上限未注入但说明原因（不静默）',
      task2b.contains('超出本轮附件正文总量上限') && task2b.contains('补充.txt'));
  check('②-b 第三篇正文未进入注入区', !task2b.contains('付款方式见合同第 12 条'));

  // ---- ③ 解析失败 → 回落告知段且含失败原因（不静默）----
  final rig3 = await _buildAttRig();
  final u3 = await rig3.conversations.appendUserMessage(rig3.convId, userText);
  // 3a：指向不存在路径的 .txt（解析器在、文件缺失）。
  await rig3.repos.attachments.insertAttachment(_attReal(
      'att_ghost',
      u3.id,
      'ghost.txt',
      AttachmentKind.file,
      p.join(tmpDir.path, 'ghost.txt'),
      10));
  // 3b：没有解析器的扩展名。
  await rig3.repos.attachments.insertAttachment(_attReal(
      'att_zzz',
      u3.id,
      'data.zzz',
      AttachmentKind.file,
      p.join(tmpDir.path, 'data.zzz'),
      10));
  await rig3.runSingle(u3.id, userText);
  final task3 = _lastUserTask(rig3.llm.calls.single);
  check('③ 回落告知段（含【用户附件】）', task3.contains('【用户附件】'));
  check('③ 文件缺失 → 含「读取失败」与错误码 kb.file_missing',
      task3.contains('读取失败') &&
          task3.contains('kb.file_missing') &&
          task3.contains('文件不存在'));
  check('③ 无解析器扩展名 → 明确说明无法读取正文',
      task3.contains('无法读取正文') && task3.contains('data.zzz'));
  check('③ 未抽到任何正文 → 无【附件正文】注入区', !task3.contains('【附件正文】'));
  check('③ 仍以原文本开头', task3.startsWith(userText));
  check('③ 保留引导句（请用户粘贴文字）',
      task3.contains('请以文字告知用户你已收到附件'));

  // ---- ④ 无附件 → userTask 逐字等于原文本（§11 ① 同口径，防回归）----
  final rig4 = await _buildAttRig();
  final u4 = await rig4.conversations.appendUserMessage(rig4.convId, userText);
  await rig4.runSingle(u4.id, userText);
  checkEq('④ 无附件：userTask 逐字等于原文本',
      _lastUserTask(rig4.llm.calls.single), userText);
  check('④ 无附件：末条消息 imageUrls 为空',
      rig4.llm.calls.single.messages.last.imageUrls.isEmpty);
  check('④ 无附件：payload content 仍为字符串',
      openAiContentFor(rig4.llm.calls.single.messages.last) is String);

  // ---- ⑤ imageUrls 为空 → provider payload 的 content 仍是字符串 ----
  check('⑤ 空图片列表 → content 为字符串',
      openAiContentFor(const ChatMessage(ChatRole.user, '纯文字')) is String);
  checkEq('⑤ 字符串内容逐字等于原文',
      openAiContentFor(const ChatMessage(ChatRole.user, '纯文字')), '纯文字');

  // ---- ⑥ 有图 + supports_vision=false → 抛 provider.vision_unsupported ----
  final rig6 = await _buildAttRig(); // 默认 supportsVision=false
  final u6 = await rig6.conversations.appendUserMessage(rig6.convId, userText);
  final pngPath = await _writeRealFile(tmpDir, 'a.png', _kPngBytes);
  await rig6.repos.attachments.insertAttachment(_attReal(
      'att_img6', u6.id, 'a.png', AttachmentKind.image, pngPath, _kPngBytes.length));
  final updates6 = await rig6.runSingle(u6.id, userText);
  final failed6 = updates6.whereType<RunFailedUpdate>().toList();
  checkEq('⑥ 恰 1 次 RunFailedUpdate', failed6.length, 1);
  checkEq('⑥ 错误码 = provider.vision_unsupported',
      failed6.single.error.code, 'provider.vision_unsupported');
  check('⑥ 错误消息点名模型与开启路径',
      failed6.single.error.message.contains('deepseek-chat') &&
          failed6.single.error.message.contains('支持视觉'));
  check('⑥ 未调用 LLM（不静默丢图、不白烧 token）', rig6.llm.calls.isEmpty);
  var gateThrew = false;
  try {
    assertVisionSupported(
      supportsVision: false,
      modelId: 'deepseek-chat',
      messages: [
        ChatMessage(ChatRole.user, 'x',
            imageUrls: ['data:image/png;base64,AA=='])
      ],
    );
  } on VisionUnsupportedError catch (e) {
    gateThrew = e.code == 'provider.vision_unsupported';
  }
  check('⑥ 门控函数直抛 VisionUnsupportedError(provider.vision_unsupported)',
      gateThrew);
  var gatePassed = true;
  try {
    assertVisionSupported(
      supportsVision: true,
      modelId: 'deepseek-chat',
      messages: [
        ChatMessage(ChatRole.user, 'x',
            imageUrls: ['data:image/png;base64,AA=='])
      ],
    );
  } catch (_) {
    gatePassed = false;
  }
  check('⑥ 带图 + supports_vision=true → 门控放行（不抛）', gatePassed);

  // ---- ⑦ 有图 + supports_vision=true → content 为 parts 数组且顺序 text→image ----
  final rig7 = await _buildAttRig(vision: true);
  final u7 = await rig7.conversations.appendUserMessage(rig7.convId, userText);
  await rig7.repos.attachments.insertAttachment(_attReal(
      'att_img7', u7.id, 'a.png', AttachmentKind.image, pngPath, _kPngBytes.length));
  await rig7.runSingle(u7.id, userText);
  checkEq('⑦ LLM 恰被调用 1 次（门控放行）', rig7.llm.calls.length, 1);
  final last7 = rig7.llm.calls.single.messages.last;
  checkEq('⑦ 末条消息 role = user', last7.role, ChatRole.user);
  checkEq('⑦ imageUrls 恰 1 个', last7.imageUrls.length, 1);
  check('⑦ data URL 前缀 data:image/png;base64,',
      last7.imageUrls.single.startsWith('data:image/png;base64,'));
  final content7 = openAiContentFor(last7);
  check('⑦ content 为 parts 数组', content7 is List);
  final parts7 = (content7 as List).cast<Map<String, Object?>>();
  checkEq('⑦ parts 数量 = 2（text + 1 图）', parts7.length, 2);
  checkEq('⑦ parts[0].type = text', parts7[0]['type'], 'text');
  checkEq('⑦ parts[0].text = 消息原文（逐字）', parts7[0]['text'], last7.content);
  checkEq('⑦ parts[1].type = image_url', parts7[1]['type'], 'image_url');
  final imgPart7 = parts7[1]['image_url'] as Map<String, Object?>;
  checkEq('⑦ parts[1].image_url.url = 同一 data URL',
      imgPart7['url'], last7.imageUrls.single);

  // ---- ⑧ 图片 > 4MB → 拒绝注入（不进入 imageUrls），告知段注明原因 ----
  final rig8 = await _buildAttRig(vision: true);
  final u8 = await rig8.conversations.appendUserMessage(rig8.convId, userText);
  final hugeBytes = List<int>.filled(kMaxImageBytesForVision + 1024, 65);
  final hugePath = await _writeRealFile(tmpDir, 'huge.png', hugeBytes);
  await rig8.repos.attachments.insertAttachment(_attReal(
      'att_img8', u8.id, 'huge.png', AttachmentKind.image, hugePath, hugeBytes.length));
  await rig8.runSingle(u8.id, userText);
  checkEq('⑧ LLM 仍被调用 1 次（其余流程不中断）', rig8.llm.calls.length, 1);
  final last8 = rig8.llm.calls.single.messages.last;
  check('⑧ 超限图片未进入 imageUrls', last8.imageUrls.isEmpty);
  final task8 = _lastUserTask(rig8.llm.calls.single);
  check('⑧ 告知段注明超限原因（超过 4MB / 未发送）',
      task8.contains('超过 4MB') && task8.contains('未发送'));
  check('⑧ 超限图片未产生【附件正文】注入区', !task8.contains('【附件正文】'));
}
