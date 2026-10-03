/// 专家导出服务（应用层 · 规范 §2–§6 / §5）。
///
/// 定位：把通讯录里的专家（市场安装 / 自建 / 导入）**打包成 `.expert`（ZIP）**，
/// 与市场包**逐字同构**——导出的包可直接回流市场（seal → build_index → 上架）。
///
/// 关键口径（规范 §3 / 任务 #27）：
/// - 单专家 → `<slug>-<version>.expert`；
/// - 多专家 → `experts-<YYYYMMDD-HHmm>.zip`（内含 N 个 `.expert` + `bundle.json`）；
/// - `manifest.sha256` 用 **seal 内容口径**（`PackageManifest.computePackageHash`
///   与 `contentHashFromPayload` 同值），逐文件 `files[].sha256` 一起带入；
/// - **明文 API Key 永不导出**，档案里只写 `credentialRefName`；导出前再做一遍
///   敏感串扫描（双保险）。
///
/// 本文件**不修改** `domain/market.dart` / `domain/expert.dart`——manifest 的
/// JSON 序列化在此就地构造（`PackageManifest` 未提供 `toJson`）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as arc;

import '../domain/common.dart';
import '../domain/expert.dart';
import '../domain/expert_bundle.dart';
import '../domain/market.dart';
import 'repositories.dart';

/// 一次导出的产物。
class ExportResult {
  const ExportResult({
    required this.fileName,
    required this.bytes,
    required this.count,
    this.isBundle = false,
  });

  /// 建议文件名（**一律 ASCII**，规范 §5）。
  final String fileName;

  /// 产物字节（单专家 `.expert` / 批量 `.zip`）。
  final List<int> bytes;

  /// 包内专家数。
  final int count;

  /// 是否批量 zip（内含多个 `.expert`）。
  final bool isBundle;
}

/// 导出服务。
class ExpertExportService {
  ExpertExportService(this._repos);

  final Repositories _repos;

  /// 构建导出包。
  ///
  /// - [expertIds]：要导出的专家本地实例 id（顺序即包内顺序）；
  /// - [includeLocal]：是否携带档案层（`profile.json`，模型 / 知识库绑定 / 备注）；
  ///   **默认 false**（纯包层，可直接回流市场）；
  /// - [includeAvatar]：是否携带头像图片（`assets/avatar.png`）；默认 false；
  /// - [onProgress]：逐专家进度回调（供 UI 显示「正在导出…（3/12）」）。
  Future<ExportResult> build({
    required List<String> expertIds,
    bool includeLocal = false,
    bool includeAvatar = false,
    int? nowMs,
    String appVersion = kDefaultExportAppVersion,
    void Function(int done, int total)? onProgress,
  }) async {
    if (expertIds.isEmpty) {
      throw const ValidationError('export.empty', '至少选择一位专家');
    }
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final total = expertIds.length;

    final packages = <_BuiltPackage>[];
    var done = 0;
    for (final id in expertIds) {
      final expert = await _repos.experts.getExpert(id);
      if (expert != null) {
        packages.add(await _buildOne(
          expert,
          includeLocal: includeLocal,
          includeAvatar: includeAvatar,
          now: now,
          appVersion: appVersion,
        ));
      }
      done++;
      onProgress?.call(done, total);
    }

    if (packages.isEmpty) {
      throw const ValidationError('export.notfound', '未找到可导出的专家');
    }

    // 单专家 → 直接返回 `.expert`。
    if (packages.length == 1) {
      final p = packages.first;
      return ExportResult(
        fileName: '${p.slug}-${p.version}.expert',
        bytes: p.bytes,
        count: 1,
      );
    }

    // 多专家 → 一个 zip（N 个 `.expert` + `bundle.json`）。
    final items = <BundleItem>[];
    final outer = arc.Archive();
    for (final p in packages) {
      final name = '${p.slug}-${p.version}.expert';
      outer.addFile(arc.ArchiveFile(name, p.bytes.length, p.bytes));
      items.add(BundleItem(
        slug: p.slug,
        displayName: p.displayName,
        version: p.version,
        fileName: name,
        hasProfile: p.hasProfile,
      ));
    }
    final bundle = BundleManifest(
      specVersion: kExportSpecVersion,
      appVersion: appVersion,
      exportedAt: now,
      items: items,
    );
    final bundleBytes = _encodeJson(bundle.toJson());
    outer.addFile(
        arc.ArchiveFile(kBatchBundleFile, bundleBytes.length, bundleBytes));
    final bytes = arc.ZipEncoder().encode(outer)!;
    return ExportResult(
      fileName: 'experts-${_stamp(now)}.zip',
      bytes: bytes,
      count: packages.length,
      isBundle: true,
    );
  }

  /// 打包单个专家为 `.expert` zip 字节。
  Future<_BuiltPackage> _buildOne(
    Expert expert, {
    required bool includeLocal,
    required bool includeAvatar,
    required int now,
    required String appVersion,
  }) async {
    final slug = SlugRule.fromName(expert.name, fallbackId: expert.id);
    final version = expert.packageVersion ?? kDefaultPackageVersion;
    final packageId = expert.packageId ?? 'org.private-advisor.local.$slug';

    final tags = await _repos.experts.getTags(expert.id);
    final state = await _repos.experts.getUserState(expert.id);
    final cfg = await _repos.experts.getRuntimeConfig(expert.id);

    final expertJson = ExpertJson(
      displayName: expert.name,
      profession: expert.profession,
      tags: tags,
      emoji: expert.avatarEmoji,
      color: expert.avatarColor,
    );

    final entries = <PackageEntry>[
      PackageEntry(
          path: kBundleExpertJsonFile, bytes: _encodeJson(expertJson.toJson())),
      PackageEntry(path: kBundleEntryFile, bytes: _utf8(expert.systemPrompt)),
      PackageEntry(path: kBundleReadmeFile, bytes: _utf8(_readmeFor(expert))),
    ];

    var hasProfile = false;
    if (includeLocal) {
      final profile = await _buildProfile(
        expert,
        now: now,
        appVersion: appVersion,
        tags: tags,
        state: state,
        cfg: cfg,
      );
      entries.add(
          PackageEntry(path: kBundleProfileFile, bytes: _encodeJson(profile.toJson())));
      hasProfile = true;
    }

    if (includeAvatar) {
      final avatarBytes = await _readAvatar(expert.avatarPath);
      if (avatarBytes != null) {
        entries.add(PackageEntry(path: kBundleAvatarFile, bytes: avatarBytes));
      }
    }

    // 导出侧双保险：落 zip 前再扫一遍（防未来字段误带明文 Key）。
    _scanOrThrow(entries);

    final files = <PackageFileEntry>[
      for (final e in entries)
        PackageFileEntry(path: e.path, sha256: PackageManifest.sha256Hex(e.bytes)),
    ];
    // seal 内容口径（与 contentHashFromPayload 同值）。
    final pkgHash = PackageManifest.computePackageHash(files);

    final manifestJson = <String, dynamic>{
      'schemaVersion': 1,
      'packageId': packageId,
      'slug': slug,
      'version': version,
      'appVersion': '>=$appVersion',
      'displayName': expert.name,
      'categoryId': expert.categoryId ?? kDefaultCategoryId,
      'entry': kBundleEntryFile,
      'capabilities': {
        'network': false,
        'filesystem': false,
        'shell': false,
        'tools': false,
      },
      'sha256': pkgHash,
      'files': [for (final f in files) f.toJson()],
      'publishedAt': now,
    };
    final manifestBytes = _encodeJson(manifestJson);

    final arch = arc.Archive();
    arch.addFile(arc.ArchiveFile(
        kBundleManifestFile, manifestBytes.length, manifestBytes));
    for (final e in entries) {
      arch.addFile(arc.ArchiveFile(e.path, e.bytes.length, e.bytes));
    }
    final bytes = arc.ZipEncoder().encode(arch)!;
    return _BuiltPackage(
      slug: slug,
      version: version,
      displayName: expert.name,
      hasProfile: hasProfile,
      bytes: bytes,
    );
  }

  /// 组装档案层（`profile.json`）。
  Future<ExpertProfile> _buildProfile(
    Expert expert, {
    required int now,
    required String appVersion,
    required List<String> tags,
    ExpertUserState? state,
    ExpertRuntimeConfig? cfg,
  }) async {
    // 凭据：**只导引用名**，绝不导明文（规范 §6）。
    String? credName;
    final credId = cfg?.credentialProfileId;
    if (credId != null && credId.isNotEmpty) {
      final cp = await _repos.credentials.get(credId);
      credName = cp?.name;
    }

    // 知识库绑定：**按名导出**（查不到库名则跳过该绑定）。
    final bindings = <KnowledgeBindingProfile>[];
    for (final b in await _repos.experts.listKnowledgeBindings(expert.id)) {
      final kb = await _repos.knowledge.getBase(b.knowledgeBaseId);
      final kbName = (kb?.name ?? '').trim();
      if (kbName.isEmpty) continue;
      bindings.add(KnowledgeBindingProfile(
        knowledgeBaseName: kbName,
        priority: b.priority,
        enabled: b.enabled,
        topK: b.topK,
        similarityThreshold: b.similarityThreshold,
      ));
    }

    return ExpertProfile(
      specVersion: kExportSpecVersion,
      exportedAt: now,
      appVersion: appVersion,
      expert: ExpertFieldProfile(
        welcomeMessage: expert.welcomeMessage,
        quickPrompts: expert.quickPrompts,
        source: expert.source.name,
        emoji: expert.avatarEmoji,
        color: expert.avatarColor,
      ),
      runtime: RuntimeProfile(
        modelProfileRef: cfg?.modelProfileId,
        credentialRefName: credName,
        temperature: cfg?.temperature,
        topP: cfg?.topP,
        maxTokens: cfg?.maxTokens,
        groundingPolicy: cfg?.groundingPolicy.name,
        enabled: cfg?.enabled ?? true,
      ),
      userState: UserStateProfile(
        remark: state?.remark,
        customPrompt: state?.customPrompt,
        styleId: state?.styleId,
        pinned: state?.pinned ?? false,
      ),
      tags: tags,
      knowledgeBindings: bindings,
    );
  }

  /// 落 zip 前的敏感串扫描（跳过二进制头像）。
  void _scanOrThrow(List<PackageEntry> entries) {
    for (final e in entries) {
      if (e.path == kBundleAvatarFile) continue;
      final String text;
      try {
        text = utf8.decode(e.bytes);
      } catch (_) {
        continue;
      }
      final hits = SecretLeakScan.scan(text);
      if (hits.isNotEmpty) {
        throw ValidationError(
          'export.secret',
          '导出内容疑似包含密钥信息（${hits.first.patternName}），已中止导出',
        );
      }
    }
  }

  /// 读取头像字节（绝对路径；不存在 / 读取失败 → null，不阻断导出）。
  Future<Uint8List?> _readAvatar(String? path) async {
    final p = (path ?? '').trim();
    if (p.isEmpty) return null;
    try {
      final f = File(p);
      if (!await f.exists()) return null;
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 生成最小 README（自建专家无 README 文件时仍给出一个完整包）。
  String _readmeFor(Expert e) {
    final b = StringBuffer('# ${e.name}\n');
    final prof = (e.profession ?? '').trim();
    if (prof.isNotEmpty) b.write('\n$prof\n');
    b.write('\n> 本包由「私人顾问团」导出，可直接导入或回流市场。\n');
    return b.toString();
  }
}

/// 已构建的单专家包（内部）。
class _BuiltPackage {
  const _BuiltPackage({
    required this.slug,
    required this.version,
    required this.displayName,
    required this.hasProfile,
    required this.bytes,
  });

  final String slug;
  final String version;
  final String displayName;
  final bool hasProfile;
  final List<int> bytes;
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List _encodeJson(Object? value) => _utf8(jsonEncode(value));

/// `YYYYMMDD-HHmm`（导出时刻本地时间，分钟精度）。
String _stamp(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}';
}
