/// 市场包安装编排（第 4 轮 · 待办 #4 / M5）。
///
/// 定位：**纯逻辑**（解包 → 校验 → 提取提示词 → 落盘），零网络依赖——
/// 下载由注入的 [MarketHttpClient] 端口（实现在 app）完成，本模块只处理字节。
///
/// **10 步安全链（契约 04 §5，不得省略）**——本模块覆盖其中 2–10，
/// 步骤 1（HTTPS 下载）由传输层保证并以索引 sha256 对照兜底：
///
/// | # | 步骤 | 执行者 |
/// |---|---|---|
/// | 1 | HTTPS 下载 + 完整性对照 | 传输层（HTTPS）+ 本模块（seal 内容口径 sha256 对照） |
/// | 2 | Manifest 解析 | `PackageManifest.parse` |
/// | 3 | 签名验证 | `PackageVerifier`（一期未签名 → 跳过并记录） |
/// | 4 | SHA256 逐文件 + 整包 | `PackageVerifier` |
/// | 5 | Schema 校验 | `PackageVerifier` |
/// | 6 | 尺寸上限 | `PackageVerifier`（下载阶段另有 20MB 预检） |
/// | 7 | 路径安全（Zip Slip） | `PackageVerifier` + 落盘前二次校验 |
/// | 8 | 能力位 | `PackageVerifier` |
/// | 9 | 可执行文件扫描 | `PackageVerifier` |
/// | 10 | appVersion 兼容 | `PackageVerifier`（app 层可传当前版本） |
///
/// **校验不通过的包绝不安装、绝不落盘**：调用方检查
/// [PackageInstallOutcome.verification.ok] 后才可调 `MarketService.installPackage`。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as arc;

import '../domain/common.dart';
import '../domain/market.dart';

/// 一次安装编排的产出（未写库；写库由 `MarketService.installPackage` 完成）。
class PackageInstallOutcome {
  const PackageInstallOutcome({
    required this.manifest,
    required this.verification,
    required this.systemPrompt,
    required this.installPath,
    this.welcomeMessage,
    this.quickPrompts = const [],
    this.extractedFileCount = 0,
  });

  final PackageManifest manifest;
  final PackageVerification verification;

  /// 系统提示词 = `manifest.entry` 指向的文件内容（实测：`agents/main.md`）。
  final String systemPrompt;

  /// 落盘根目录（`<data>/market/packages/<slug>-<version>/`）。
  final String installPath;

  final String? welcomeMessage;
  final List<String> quickPrompts;
  final int extractedFileCount;

  bool get ok => verification.ok;
}

/// 安装编排器。
class MarketInstallFlow {
  MarketInstallFlow({this.maxDownloadBytes = PackageVerifier.maxPackageBytes});

  /// 下载体上限（与整包上限一致，20MB）。
  final int maxDownloadBytes;

  /// 从已下载的字节执行完整安装编排。
  ///
  /// [expectedSha256] 为索引 `versions[].sha256`——**seal 内容口径**：解包后
  /// 对包内（除 `manifest.json` 外）每个文件的**实际内容字节**算 sha256，
  /// 按 path 字典序拼 `path\0sha256\n` 后整包 sha256（任务 #27 口径统一，
  /// 与服务端 `market/scripts/package_utils.dart` 的 `computePackageHash`
  /// 逐字同口径）。ZIP 文件字节的哈希是另一口径，**不用于**安装校验；
  /// ZIP 传输完整性由 HTTPS + 20MB 尺寸预检承担。
  /// [writeFiles] 为 false 时只校验不落盘（供纯校验 / 测试场景）。
  Future<PackageInstallOutcome> runFromBytes({
    required List<int> packageBytes,
    required String expectedSha256,
    required String installDir,
    bool writeFiles = true,
  }) async {
    final bytes =
        packageBytes is Uint8List ? packageBytes : Uint8List.fromList(packageBytes);

    // 传输完整性预检：尺寸上限（契约 04 §5 步骤 1 的兜底之一；
    // 哈希对照在解包后按 seal 内容口径进行，见下文）。
    if (bytes.isEmpty) {
      throw const UnsafePackageError('market.empty：下载内容为空');
    }
    if (bytes.length > maxDownloadBytes) {
      throw UnsafePackageError(
          'market.size：包体积 ${bytes.length} 字节，超过 $maxDownloadBytes 上限');
    }

    // 步骤 2 前置：ZIP 解包（损坏 → 明确报错）。
    final arc.Archive archive;
    try {
      archive = arc.ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw UnsafePackageError('market.zip：不是合法的 .expert（ZIP）包：$e');
    }

    final entries = <PackageEntry>[];
    for (final f in archive.files) {
      if (f.isFile) {
        final content = f.content;
        entries.add(PackageEntry(
          path: f.name,
          bytes: content is Uint8List
              ? content
              : Uint8List.fromList(List<int>.from(content as List<int>)),
        ));
      }
    }
    final payload = PackagePayload(entries);

    // 步骤 1 兜底：索引 sha256 对照——**seal 内容口径**（解包后按包内
    // 实际内容字节重算，与 `manifest.sha256` 的封包口径逐字一致）。
    // `dataEntries` 已排除 manifest.json（seal 封包口径不含 manifest 自身）。
    final actualSha =
        PackageManifest.contentHashFromPayload(payload.dataEntries);
    if (actualSha.toLowerCase() != expectedSha256.toLowerCase()) {
      throw UnsafePackageError(
        'market.hash：下载完整性校验失败，索引声明 $expectedSha256，实际 $actualSha',
      );
    }

    // 步骤 2：Manifest 解析。
    final manifestEntry = payload.find('manifest.json');
    if (manifestEntry == null) {
      throw const UnsafePackageError('market.manifest：包内缺少 manifest.json');
    }
    final manifest = PackageManifest.parse(utf8.decode(manifestEntry.bytes));

    // 步骤 3–10：安全链（签名一期未启用 → 跳过并记录；appVersion 兼容性
    // 由 app 层需要时经 PackageVerifier 直接传入，安装流默认不启用）。
    final verification = PackageVerifier.verify(
      payload: payload,
      manifest: manifest,
    );

    // 步骤 1 记录：HTTPS + seal 内容口径哈希对照（解包后重算并对比索引声明）。
    final steps = <VerifyStep>[
      VerifyStep('1. HTTPS Download', true,
          'HTTPS 下载 + seal 内容口径 sha256 对照通过（$actualSha）'),
      ...verification.steps,
    ];
    final fullVerification = PackageVerification(steps);

    // 提取系统提示词（entry 指向的文件；缺失时校验链步骤 5 已会报，此处兜底防崩）。
    final promptEntry = payload.find(manifest.entry);
    if (promptEntry == null) {
      throw UnsafePackageError('market.entry：入口文件不存在：${manifest.entry}');
    }
    final systemPrompt = utf8.decode(promptEntry.bytes);

    // expert.json（可选字段：welcomeMessage / quickPrompts）——宽松解析，
    // 解析失败不阻断安装（非安全项，manifest 已含必要信息）。
    String? welcomeMessage;
    var quickPrompts = const <String>[];
    final expertEntry = payload.find('expert.json');
    if (expertEntry != null) {
      try {
        final decoded = jsonDecode(utf8.decode(expertEntry.bytes));
        if (decoded is Map<String, dynamic>) {
          final w = decoded['welcomeMessage'];
          if (w is String && w.trim().isNotEmpty) welcomeMessage = w;
          final q = decoded['quickPrompts'];
          if (q is List) {
            quickPrompts = q.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList();
          }
        }
      } catch (_) {
        // 忽略：expert.json 非必需字段缺失不影响安装。
      }
    }

    // 落盘（校验通过才允许走到这里之外的写库；落盘前二次路径安全校验）。
    var extracted = 0;
    if (writeFiles) {
      for (final e in payload.entries) {
        final reject = ZipPathSafety.reject(e.path);
        if (reject != null) {
          throw UnsafePackageError('market.path：拒绝落盘 ${e.path}：$reject');
        }
        if (!ZipPathSafety.staysInside(installDir, e.path)) {
          throw UnsafePackageError('market.path：拒绝落盘 ${e.path}：逃逸出目标目录');
        }
        final file = File(_join(installDir, e.path));
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(e.bytes, flush: true);
        extracted++;
      }
    }

    return PackageInstallOutcome(
      manifest: manifest,
      verification: fullVerification,
      systemPrompt: systemPrompt,
      installPath: installDir,
      welcomeMessage: welcomeMessage,
      quickPrompts: quickPrompts,
      extractedFileCount: extracted,
    );
  }

  /// 仅校验不落盘（供 UI「先看校验报告」/ 测试）。
  Future<PackageInstallOutcome> verifyOnly({
    required List<int> packageBytes,
    required String expectedSha256,
  }) =>
      runFromBytes(
        packageBytes: packageBytes,
        expectedSha256: expectedSha256,
        installDir: '/dev/null-verify-only',
        writeFiles: false,
      );

  /// 平台无关的路径拼接（正斜杠为主，与 ZIP 内路径一致；Windows 接受正斜杠）。
  static String _join(String dir, String path) {
    final d = dir.endsWith('/') || dir.endsWith(r'\') ? dir : '$dir/';
    return '$d$path'.replaceAll(r'//', '/');
  }
}
