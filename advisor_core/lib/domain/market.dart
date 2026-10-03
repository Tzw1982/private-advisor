/// Market 领域：市场源 / 包 / 版本 / 安装 + 安装安全链（V1.3 §19~§23 / §27~§32）。
///
/// 核心承诺：**先验证，再安装；`.expert` 是纯数据包，不执行任何代码。**
library;

import 'dart:convert';
import 'dart:typed_data';

// 使用前缀导入，避免与本类中的 `sha256` 字段同名遮蔽。
import 'package:crypto/crypto.dart' as crypto;

import 'common.dart';

// ---------------------------------------------------------------------------
// 语义化版本
// ---------------------------------------------------------------------------

/// 语义化版本（支持 `1.2.3` / `1.2.3-beta.1`）。
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch, [this.preRelease = '']);

  final int major;
  final int minor;
  final int patch;
  final String preRelease;

  static final _re = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.\-]+))?$');

  static SemVer? tryParse(String? v) {
    if (v == null) return null;
    final m = _re.firstMatch(v.trim());
    if (m == null) return null;
    return SemVer(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      m.group(4) ?? '',
    );
  }

  static SemVer parse(String v) {
    final r = tryParse(v);
    if (r == null) throw ValidationError('semver.invalid', '非法版本号：$v');
    return r;
  }

  @override
  int compareTo(SemVer o) {
    if (major != o.major) return major.compareTo(o.major);
    if (minor != o.minor) return minor.compareTo(o.minor);
    if (patch != o.patch) return patch.compareTo(o.patch);
    if (preRelease.isEmpty && o.preRelease.isEmpty) return 0;
    if (preRelease.isEmpty) return 1; // 正式版 > 预发布版
    if (o.preRelease.isEmpty) return -1;
    return preRelease.compareTo(o.preRelease);
  }

  bool operator >(SemVer o) => compareTo(o) > 0;
  bool operator <(SemVer o) => compareTo(o) < 0;
  bool operator >=(SemVer o) => compareTo(o) >= 0;
  bool operator <=(SemVer o) => compareTo(o) <= 0;

  @override
  bool operator ==(Object other) =>
      other is SemVer && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  @override
  String toString() => preRelease.isEmpty ? '$major.$minor.$patch' : '$major.$minor.$patch-$preRelease';
}

/// `>=1.3.0` 形式的版本要求。
class AppVersionRequirement {
  const AppVersionRequirement(this.minVersion, {this.raw = ''});

  final SemVer minVersion;
  final String raw;

  static AppVersionRequirement parse(String spec) {
    final s = spec.trim();
    final m = RegExp(r'^>=?\s*([0-9][0-9A-Za-z.\-]*)$').firstMatch(s);
    final v = SemVer.tryParse(m?.group(1) ?? s);
    if (v == null) throw ValidationError('appver.invalid', '非法 appVersion：$spec');
    return AppVersionRequirement(v, raw: s);
  }

  bool satisfiedBy(SemVer appVersion) => appVersion >= minVersion;
}

// ---------------------------------------------------------------------------
// Manifest（契约 04 §2）
// ---------------------------------------------------------------------------

/// 包能力声明。一期**全部必须为 false**。
class PackageCapabilities {
  const PackageCapabilities({
    this.network = false,
    this.filesystem = false,
    this.shell = false,
    this.tools = false,
  });

  final bool network;
  final bool filesystem;
  final bool shell;
  final bool tools;

  bool get isClean => !network && !filesystem && !shell && !tools;

  static const clean = PackageCapabilities();

  factory PackageCapabilities.fromJson(Map<String, dynamic>? j) {
    if (j == null) return clean;
    bool b(String k) => j[k] == true;
    return PackageCapabilities(
      network: b('network'),
      filesystem: b('filesystem'),
      shell: b('shell'),
      tools: b('tools'),
    );
  }

  Map<String, dynamic> toJson() =>
      {'network': network, 'filesystem': filesystem, 'shell': shell, 'tools': tools};
}

/// 包内文件条目。
class PackageFileEntry {
  const PackageFileEntry({required this.path, required this.sha256});

  final String path;
  final String sha256;

  factory PackageFileEntry.fromJson(Map<String, dynamic> j) => PackageFileEntry(
        path: (j['path'] ?? '') as String,
        sha256: (j['sha256'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {'path': path, 'sha256': sha256};
}

/// 包清单。
class PackageManifest {
  const PackageManifest({
    this.schemaVersion = 1,
    required this.packageId,
    required this.slug,
    required this.version,
    required this.appVersion,
    required this.displayName,
    required this.categoryId,
    required this.entry,
    required this.sha256,
    this.signature,
    this.signerKeyId,
    this.capabilities = PackageCapabilities.clean,
    this.files = const [],
    this.publishedAt,
  });

  final int schemaVersion;
  final String packageId;
  final String slug;
  final SemVer version;
  final AppVersionRequirement appVersion;
  final String displayName;
  final String categoryId;
  final String entry;
  final String sha256;
  final String? signature;
  final String? signerKeyId;
  final PackageCapabilities capabilities;
  final List<PackageFileEntry> files;
  final int? publishedAt;

  bool get isSigned => signature != null && signature!.isNotEmpty;

  factory PackageManifest.fromJson(Map<String, dynamic> j) {
    String req(String k) {
      final v = j[k];
      if (v == null || (v is String && v.trim().isEmpty)) {
        throw SchemaError('manifest 缺少必填字段：$k');
      }
      return v.toString();
    }

    final filesJson = j['files'];
    final files = <PackageFileEntry>[];
    if (filesJson is List) {
      for (final e in filesJson) {
        if (e is Map<String, dynamic>) files.add(PackageFileEntry.fromJson(e));
      }
    }

    return PackageManifest(
      schemaVersion: (j['schemaVersion'] as num?)?.toInt() ?? 1,
      packageId: req('packageId'),
      slug: req('slug'),
      version: SemVer.parse(req('version')),
      appVersion: AppVersionRequirement.parse(req('appVersion')),
      displayName: req('displayName'),
      categoryId: req('categoryId'),
      entry: req('entry'),
      sha256: req('sha256'),
      signature: j['signature'] as String?,
      signerKeyId: j['signerKeyId'] as String?,
      capabilities: PackageCapabilities.fromJson(j['capabilities'] as Map<String, dynamic>?),
      files: files,
      publishedAt: (j['publishedAt'] as num?)?.toInt(),
    );
  }

  static PackageManifest parse(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) {
        throw const SchemaError('manifest 根节点必须是对象');
      }
      return PackageManifest.fromJson(decoded);
    } on AppError {
      rethrow;
    } catch (e) {
      throw SchemaError('manifest 解析失败：$e');
    }
  }

  /// 按契约 04 §4 计算包整体哈希（不含 manifest.json 自身）。
  static String computePackageHash(List<PackageFileEntry> files) {
    final sorted = List<PackageFileEntry>.from(files)
      ..sort((a, b) => a.path.compareTo(b.path));
    final buf = StringBuffer();
    for (final f in sorted) {
      buf.write(f.path);
      buf.write('\u0000');
      buf.write(f.sha256);
      buf.write('\n');
    }
    return crypto.sha256.convert(utf8.encode(buf.toString())).toString();
  }

  /// seal 口径**内容哈希**（与服务端 `market/scripts/package_utils.dart` 的
  /// `computePackageHash` **逐字同口径**，任务 #27 哈希口径统一的对照基准）：
  ///
  /// 1. 对每个 entry 用**实际内容字节**算 sha256（hex 小写）；
  /// 2. 按 `path` 字典序（`compareTo`）升序排序；
  /// 3. 逐项拼接 `path + '\0' + sha256hex + '\n'`（UTF-8 编码）；
  /// 4. 整包哈希 = sha256(拼接字节)，hex 小写。
  ///
  /// **调用方必须排除 `manifest.json`**——seal 封包时即不含 manifest 自身
  /// （`seal.dart` 显式过滤）。索引 `versions[].sha256` 声明的就是本口径；
  /// `.expert`（ZIP 文件字节）的哈希是另一口径，**不可**与本值互比。
  static String contentHashFromPayload(Iterable<PackageEntry> entries) {
    final rows = <({String path, String sha256})>[
      for (final e in entries) (path: e.path, sha256: sha256Hex(e.bytes)),
    ]..sort((a, b) => a.path.compareTo(b.path));
    final buf = StringBuffer();
    for (final f in rows) {
      buf.write(f.path);
      buf.write('\u0000');
      buf.write(f.sha256);
      buf.write('\n');
    }
    return crypto.sha256.convert(utf8.encode(buf.toString())).toString();
  }

  static String sha256Hex(List<int> bytes) =>
      crypto.sha256.convert(bytes).toString();
}

// ---------------------------------------------------------------------------
// 包载荷（解包前的内存视图，便于纯逻辑校验）
// ---------------------------------------------------------------------------

/// 包内一个文件。
class PackageEntry {
  const PackageEntry({required this.path, required this.bytes});
  final String path;
  final Uint8List bytes;

  int get size => bytes.length;
}

/// 包载荷。
class PackagePayload {
  const PackagePayload(this.entries);

  final List<PackageEntry> entries;

  PackageEntry? find(String path) {
    for (final e in entries) {
      if (e.path == path) return e;
    }
    return null;
  }

  Iterable<PackageEntry> get dataEntries =>
      entries.where((e) => e.path != 'manifest.json');
}

// ---------------------------------------------------------------------------
// ZIP 路径安全（契约 04 §6）
// ---------------------------------------------------------------------------

/// 路径安全校验（防 Zip Slip / 绝对路径 / 盘符 / 链接）。
abstract final class ZipPathSafety {
  static final _drive = RegExp(r'^[A-Za-z]:');
  static final _forbidden = RegExp(r'[<>:"|?*\x00-\x1F]');

  /// 返回 null 表示安全；否则返回拒绝原因。
  static String? reject(String rawPath) {
    if (rawPath.isEmpty) return '空路径';
    if (rawPath.startsWith('/') || rawPath.startsWith(r'\')) return '绝对路径';
    if (_drive.hasMatch(rawPath)) return '包含盘符';
    if (_forbidden.hasMatch(rawPath)) return '包含非法字符';
    final normalized = rawPath.replaceAll(r'\', '/');
    final segments = normalized.split('/');
    for (final s in segments) {
      if (s == '..') return '包含上级目录 ..';
      if (s.isEmpty) return '包含空路径段';
    }
    if (normalized.contains('//')) return '包含重复分隔符';
    return null;
  }

  /// 校验解包目标仍在 [targetDir] 内。
  static bool staysInside(String targetDir, String entryPath) {
    final base = _normalize(targetDir);
    final full = _normalize('$targetDir/$entryPath');
    return full == base || full.startsWith('$base/');
  }

  static String _normalize(String p) {
    final parts = p.replaceAll(r'\', '/').split('/');
    final out = <String>[];
    for (final s in parts) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(s);
    }
    return out.join('/');
  }
}

// ---------------------------------------------------------------------------
// 安装安全链（V1.3 §22 / §31）
// ---------------------------------------------------------------------------

/// 校验步骤结果。
class VerifyStep {
  const VerifyStep(this.name, this.passed, [this.detail]);
  final String name;
  final bool passed;
  final String? detail;
}

/// 校验总结果。
class PackageVerification {
  const PackageVerification(this.steps);

  final List<VerifyStep> steps;

  bool get ok => steps.every((s) => s.passed);

  VerifyStep? get firstFailure => steps.where((s) => !s.passed).firstOrNull;

  String report() => steps
      .map((s) => '${s.passed ? 'PASS' : 'FAIL'}  ${s.name}${s.detail == null ? '' : '  → ${s.detail}'}')
      .join('\n');
}

/// 签名验证端口（ed25519 等；一期可空）。
abstract interface class SignatureVerifier {
  bool verify({required String payloadHashHex, required String signature, String? keyId});
}

/// 包校验器。
///
/// 步骤 1（HTTPS）与 3（签名）依赖外部环境，由调用方保证 / 注入；
/// 其余步骤在这里纯逻辑执行，便于单测。
abstract final class PackageVerifier {
  /// 单文件上限 5MB，整包上限 20MB（契约 04 §5）。
  static const int maxFileBytes = 5 * 1024 * 1024;
  static const int maxPackageBytes = 20 * 1024 * 1024;

  /// 禁止的可执行扩展名。
  static const Set<String> forbiddenExtensions = {
    '.exe', '.dll', '.bat', '.cmd', '.ps1', '.sh', '.py', '.js',
    '.jar', '.msi', '.scr', '.com', '.vbs', '.so', '.dylib', '.app',
  };

  static PackageVerification verify({
    required PackagePayload payload,
    required PackageManifest manifest,
    SemVer? appVersion,
    SignatureVerifier? signatureVerifier,
    bool requireSignature = false,
  }) {
    final steps = <VerifyStep>[];

    // 2. Manifest Parse —— 能构造出 manifest 即通过
    steps.add(const VerifyStep('2. Manifest Parse', true));

    // 3. Signature Verify
    if (manifest.isSigned) {
      if (signatureVerifier == null) {
        steps.add(VerifyStep('3. Signature Verify', !requireSignature,
            requireSignature ? '缺少验签实现' : '有签名但无验签器，跳过'));
      } else {
        final ok = signatureVerifier.verify(
          payloadHashHex: manifest.sha256,
          signature: manifest.signature!,
          keyId: manifest.signerKeyId,
        );
        steps.add(VerifyStep('3. Signature Verify', ok, ok ? null : '验签失败'));
      }
    } else {
      steps.add(VerifyStep('3. Signature Verify', !requireSignature,
          requireSignature ? '未签名' : '未签名（跳过）'));
    }

    // 4. SHA256 Verify —— 逐文件 + 整体
    final fileResults = <String>[];
    var hashOk = true;
    for (final f in manifest.files) {
      final entry = payload.find(f.path);
      if (entry == null) {
        hashOk = false;
        fileResults.add('缺少文件 ${f.path}');
        continue;
      }
      final actual = PackageManifest.sha256Hex(entry.bytes);
      if (actual != f.sha256) {
        hashOk = false;
        fileResults.add('哈希不符 ${f.path}');
      }
    }
    if (manifest.files.isEmpty) {
      hashOk = false;
      fileResults.add('files[] 为空');
    }
    final actualPkg = PackageManifest.computePackageHash(manifest.files);
    if (actualPkg != manifest.sha256) {
      hashOk = false;
      fileResults.add('整包哈希不符');
    }
    // 载荷中不得有 files[] 未声明的多余文件
    for (final e in payload.dataEntries) {
      if (!manifest.files.any((f) => f.path == e.path)) {
        hashOk = false;
        fileResults.add('未声明文件 ${e.path}');
      }
    }
    steps.add(VerifyStep('4. SHA256 Verify', hashOk, fileResults.isEmpty ? null : fileResults.join('; ')));

    // 5. Schema Validate
    final schemaIssues = _validateSchema(manifest, payload);
    steps.add(VerifyStep('5. Schema Validate', schemaIssues.isEmpty, schemaIssues.join('; ')));

    // 6. Size Validate
    final sizeIssues = <String>[];
    for (final e in payload.entries) {
      if (e.size > maxFileBytes) sizeIssues.add('${e.path} 超过 5MB');
    }
    final total = payload.entries.fold<int>(0, (a, e) => a + e.size);
    if (total > maxPackageBytes) sizeIssues.add('整包超过 20MB');
    steps.add(VerifyStep('6. Size Validate', sizeIssues.isEmpty, sizeIssues.join('; ')));

    // 7. Path Safety Verify
    final pathIssues = <String>[];
    for (final e in payload.entries) {
      final r = ZipPathSafety.reject(e.path);
      if (r != null) pathIssues.add('${e.path}: $r');
      if (!ZipPathSafety.staysInside('packages/', e.path)) {
        pathIssues.add('${e.path}: 逃逸出目标目录');
      }
    }
    steps.add(VerifyStep('7. Path Safety Verify', pathIssues.isEmpty, pathIssues.join('; ')));

    // 8. Capability Verify
    steps.add(VerifyStep(
      '8. Capability Verify',
      manifest.capabilities.isClean,
      manifest.capabilities.isClean ? null : 'capabilities 必须全部为 false',
    ));

    // 9. No-Executable Scan
    final execIssues = <String>[];
    for (final e in payload.entries) {
      final lower = e.path.toLowerCase();
      for (final ext in forbiddenExtensions) {
        if (lower.endsWith(ext)) execIssues.add(e.path);
      }
    }
    steps.add(VerifyStep('9. No-Executable Scan', execIssues.isEmpty, execIssues.join('; ')));

    // 10. 兼容性（appVersion）
    if (appVersion != null) {
      final ok = manifest.appVersion.satisfiedBy(appVersion);
      steps.add(VerifyStep('10. AppVersion Compatible', ok,
          ok ? null : '需要 ${manifest.appVersion.raw}，当前 $appVersion'));
    }

    return PackageVerification(steps);
  }

  static List<String> _validateSchema(PackageManifest m, PackagePayload payload) {
    final issues = <String>[];
    if (m.schemaVersion != 1) issues.add('schemaVersion 必须为 1');
    if (!RegExp(r'^[a-z0-9][a-z0-9\-]*$').hasMatch(m.slug)) issues.add('slug 非法：${m.slug}');
    if (!m.packageId.contains('.')) issues.add('packageId 应为反向域名：${m.packageId}');
    if (m.displayName.trim().isEmpty) issues.add('displayName 为空');
    if (payload.find(m.entry) == null) issues.add('entry 指向的文件不存在：${m.entry}');
    if (payload.find('expert.json') == null) issues.add('缺少 expert.json');
    return issues;
  }
}

// ---------------------------------------------------------------------------
// 市场数据模型（V1.3 §28 / §29）
// ---------------------------------------------------------------------------

/// 市场源。
class MarketSource {
  const MarketSource({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.enabled = true,
    this.lastRefreshAt,
  });

  final String id;
  final String name;

  /// 如 `https://raw.githubusercontent.com/TZW1982/private-advisor-market/main`
  final String baseUrl;
  final bool enabled;
  final int? lastRefreshAt;

  String get catalogUrl => '$baseUrl/catalog/index.json';
}

/// 市场版本。
class MarketVersion {
  const MarketVersion({
    required this.packageId,
    required this.version,
    required this.releaseUrl,
    required this.sha256,
    this.signature,
    this.sizeBytes,
    this.publishedAt,
  });

  final String packageId;
  final SemVer version;
  final String releaseUrl;
  final String sha256;
  final String? signature;
  final int? sizeBytes;
  final int? publishedAt;

  factory MarketVersion.fromJson(String packageId, Map<String, dynamic> j) => MarketVersion(
        packageId: packageId,
        version: SemVer.parse((j['version'] ?? '') as String),
        releaseUrl: (j['releaseUrl'] ?? '') as String,
        sha256: (j['sha256'] ?? '') as String,
        signature: j['signature'] as String?,
        sizeBytes: (j['sizeBytes'] as num?)?.toInt(),
        publishedAt: (j['publishedAt'] as num?)?.toInt(),
      );
}

/// 市场包（索引条目）。
class MarketPackage {
  const MarketPackage({
    required this.packageId,
    required this.slug,
    required this.displayName,
    this.profession,
    this.description,
    required this.categoryId,
    this.tags = const [],
    required this.latestVersion,
    this.versions = const [],
    this.emoji,
    this.color,
  });

  final String packageId;
  final String slug;
  final String displayName;
  final String? profession;
  final String? description;
  final String categoryId;
  final List<String> tags;
  final SemVer latestVersion;
  final List<MarketVersion> versions;

  /// 包自带 emoji（第 7 轮 T06；索引新增字段，additive）。
  ///
  /// 旧索引无此字段 → null（走回退档：首字 + 确定性色）。
  final String? emoji;

  /// 包自带主色（`#RRGGBB`，第 7 轮 T06；索引新增字段，additive）。
  ///
  /// 脏值容忍：非字符串 / 空白 → null（解析交给 app 侧，绝不在此抛异常）。
  final String? color;

  factory MarketPackage.fromJson(Map<String, dynamic> j) {
    final packageId = (j['packageId'] ?? '') as String;
    final versionsJson = j['versions'];
    final versions = <MarketVersion>[];
    if (versionsJson is List) {
      for (final v in versionsJson) {
        if (v is Map<String, dynamic>) versions.add(MarketVersion.fromJson(packageId, v));
      }
    }
    final tags = <String>[];
    if (j['tags'] is List) {
      tags.addAll((j['tags'] as List).map((e) => e.toString()));
    }
    // 仅当「是字符串且 trim 非空」才取；脏值（null / 空串 / 非法类型）→ null，不抛。
    String? nonEmpty(Object? v) =>
        (v is String && v.trim().isNotEmpty) ? v : null;
    return MarketPackage(
      packageId: packageId,
      slug: (j['slug'] ?? '') as String,
      displayName: (j['displayName'] ?? '') as String,
      profession: j['profession'] as String?,
      description: j['description'] as String?,
      categoryId: (j['categoryId'] ?? '') as String,
      tags: tags,
      latestVersion: SemVer.parse((j['latestVersion'] ?? '0.0.0') as String),
      versions: versions,
      emoji: nonEmpty(j['emoji']),
      color: nonEmpty(j['color']),
    );
  }

  MarketVersion? version(String v) {
    for (final e in versions) {
      if (e.version == SemVer.parse(v)) return e;
    }
    return null;
  }

  MarketVersion? get latest {
    if (versions.isEmpty) return null;
    final sorted = List<MarketVersion>.from(versions)..sort((a, b) => b.version.compareTo(a.version));
    return sorted.first;
  }
}

/// 市场搜索：关键词是否命中某个包（名称 / 职业 / 描述 / 标签；大小写不敏感）。
///
/// **单一事实源**：`MarketIndex.search` 与 app 层 `MarketController` 的市场过滤
/// 均调用本函数，确保「搜索关键词 → 过滤结果」只有一处口径（第 #80 轮走查
/// 缺陷 A「搜索框与过滤条件脱节」的配套收敛）。空关键词（含全空白）视为**全部命中**。
bool marketPackageMatchesKeyword(MarketPackage p, String keyword) {
  final k = keyword.trim().toLowerCase();
  if (k.isEmpty) return true;
  if (p.displayName.toLowerCase().contains(k)) return true;
  if ((p.profession ?? '').toLowerCase().contains(k)) return true;
  if ((p.description ?? '').toLowerCase().contains(k)) return true;
  return p.tags.any((t) => t.toLowerCase().contains(k));
}

/// 按关键词过滤市场包（跨分类；保持输入顺序）。
///
/// 基于 [marketPackageMatchesKeyword]；**空关键词 → 原样返回全部**（与
/// `MarketIndex.search` / `MarketController` 同口径）。
List<MarketPackage> filterMarketPackagesByKeyword(
        List<MarketPackage> packages, String keyword) =>
    packages.where((p) => marketPackageMatchesKeyword(p, keyword)).toList();

/// 市场索引。
class MarketIndex {
  const MarketIndex({
    this.schemaVersion = 1,
    required this.generatedAt,
    this.packages = const [],
  });

  final int schemaVersion;
  final int generatedAt;
  final List<MarketPackage> packages;

  factory MarketIndex.fromJson(Map<String, dynamic> j) {
    final list = <MarketPackage>[];
    final pkgs = j['packages'];
    if (pkgs is List) {
      for (final p in pkgs) {
        if (p is Map<String, dynamic>) list.add(MarketPackage.fromJson(p));
      }
    }
    return MarketIndex(
      schemaVersion: (j['schemaVersion'] as num?)?.toInt() ?? 1,
      generatedAt: (j['generatedAt'] as num?)?.toInt() ?? 0,
      packages: list,
    );
  }

  static MarketIndex parse(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) throw const SchemaError('index 根节点必须是对象');
      return MarketIndex.fromJson(decoded);
    } on AppError {
      rethrow;
    } catch (e) {
      throw SchemaError('index 解析失败：$e');
    }
  }

  /// 按分类分组。
  Map<String, List<MarketPackage>> groupByCategory() {
    final out = <String, List<MarketPackage>>{};
    for (final p in packages) {
      out.putIfAbsent(p.categoryId, () => []).add(p);
    }
    for (final v in out.values) {
      v.sort((a, b) => a.displayName.compareTo(b.displayName));
    }
    return out;
  }

  /// 关键词搜索（名称 / 职业 / 标签 / 描述）；口径见 [marketPackageMatchesKeyword]。
  List<MarketPackage> search(String keyword) {
    if (keyword.trim().isEmpty) return packages;
    return packages.where((p) => marketPackageMatchesKeyword(p, keyword)).toList();
  }
}

/// 已安装包。
class InstalledPackage {
  const InstalledPackage({
    required this.installationId,
    required this.packageId,
    required this.version,
    required this.installPath,
    required this.installedAt,
    this.localModified = false,
    required this.source,
  });

  final String installationId;
  final String packageId;
  final SemVer version;
  final String installPath;
  final int installedAt;
  final bool localModified;
  final String source;
}

/// 更新判定结果。
enum UpdateDecision {
  upToDate('已是最新'),
  autoUpdate('可自动更新'),
  manualMigrate('已本地修改，需手动迁移');

  const UpdateDecision(this.label);
  final String label;
}

/// 更新策略（V1.3 §32）。
abstract final class UpdatePolicy {
  static UpdateDecision decide({
    required SemVer installed,
    required SemVer available,
    required bool localModified,
  }) {
    if (available <= installed) return UpdateDecision.upToDate;
    return localModified ? UpdateDecision.manualMigrate : UpdateDecision.autoUpdate;
  }
}

// ---------------------------------------------------------------------------
// 市场网络端口（第 4 轮 · 待办 #4）
// ---------------------------------------------------------------------------

/// 市场网络客户端端口。
///
/// **端口在 core、实现在 app**（架构裁定）：core 零网络依赖（不引 `http` /
/// `dart:io` 网络层），由 app 层注入真实实现（跟随重定向 + 通道回退）。
/// 纯逻辑与服务层测试注入假实现（本地 fixture 驱动）。
///
/// 通道实测结论（第 4 轮，沙箱 `curl` 实测）：
/// - `raw.githubusercontent.com`（index.json）可达 ✅；
/// - `github.com/.../releases/download/...` 302 → `release-assets.githubusercontent.com`
///   链路存在，但沙箱内完整下载被重置（❌ 不可靠）；
/// - **`api.github.com` asset API（`Accept: application/octet-stream` + 跟随重定向）
///   完整下载成功** ✅ → 实现层应将其作为下载兜底通道。
abstract interface class MarketHttpClient {
  /// 拉取文本资源（如 `catalog/index.json`）。
  Future<String> fetchText(String url);

  /// 下载二进制资源（如 `.expert` 包）；失败须抛异常，不得静默返回空。
  Future<List<int>> fetchBytes(String url);
}
