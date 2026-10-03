/// 专家导入服务（应用层 · 规范 §4 / §6 / §7 / §8 / §9）。
///
/// 定位：把 `.expert`（单文件）或批量 `.zip`（内含多个 `.expert` + `bundle.json`）
/// **解析 → 校验 → 落库**为本机专家，与市场安装**共用同一条安全链**。
///
/// 两阶段：
/// 1. [plan]：解包 → 复用市场 `PackageVerifier` 的 2–10 步 → 新增 S1–S4
///    （规范版本 / 敏感串 / slug 合法性 / 冲突预检）→ 产出 [ExpertImportPlan]
///    （**不落库**，供 UI 展示冲突并收集决策）；
/// 2. [apply]：按用户决策落库（S5 引用解析在落库时执行）；**批量跳过继续**
///    （失败隔离到单条、不整批回滚），但**单条原子**（失败走补偿删除 / 覆盖还原）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' as arc;

import '../domain/common.dart';
import '../domain/expert.dart';
import '../domain/expert_bundle.dart';
import '../domain/knowledge.dart';
import '../domain/market.dart';
import '../domain/style.dart';
import 'repositories.dart';

// ---------------------------------------------------------------------------
// 计划阶段模型
// ---------------------------------------------------------------------------

/// 单条导入项的处理状态。
enum ImportItemStatus {
  ready('可导入'),
  conflict('冲突'),
  rejected('已拒绝');

  const ImportItemStatus(this.label);
  final String label;
}

/// 一条待导入项（[ExpertImportService.plan] 产出）。
class ExpertImportItem {
  const ExpertImportItem({
    required this.sourceFile,
    required this.slug,
    required this.displayName,
    required this.version,
    required this.status,
    required this.specVersion,
    required this.compat,
    this.packageId,
    this.categoryId,
    this.reason,
    this.verifyReport,
    this.conflict,
    this.profile,
    this.expertJson,
    this.systemPrompt = '',
    this.packageBytes,
  });

  /// 来源文件项名（批量 zip 内的 `.expert` 文件名；单文件为 `-`）。
  final String sourceFile;
  final String slug;
  final String displayName;
  final String version;
  final String? packageId;
  final String? categoryId;
  final ImportItemStatus status;
  final int specVersion;
  final SpecCompat compat;

  /// 拒绝原因（status = rejected 时有值）。
  final String? reason;

  /// 复用的市场安全链报告文本（失败时便于「查看明细」）。
  final String? verifyReport;

  /// 冲突信息（status = conflict 时有值）。
  final ConflictInfo? conflict;

  /// 已解析的档案层（无 `profile.json` 时为 null）。
  final ExpertProfile? profile;

  /// 已解析的 `expert.json`（可能为 null）。
  final ExpertJson? expertJson;

  /// 系统提示词全文（`agents/main.md`）。
  final String systemPrompt;

  /// 单个 `.expert` 的原始字节（apply 复用，避免重新解包）。
  final Uint8List? packageBytes;

  /// 冲突决策键（稳定：来源文件名 + 展示名）。
  String get key => '$sourceFile::$displayName';

  bool get isRejected => status == ImportItemStatus.rejected;
  bool get isConflict => status == ImportItemStatus.conflict;
  bool get isReady => status == ImportItemStatus.ready;

  /// 是否携带档案层。
  bool get hasProfile => profile != null;
}

/// 一次导入计划（**不落库**）。
class ExpertImportPlan {
  const ExpertImportPlan({required this.items});

  final List<ExpertImportItem> items;

  List<ExpertImportItem> get ready =>
      items.where((i) => i.isReady).toList();
  List<ExpertImportItem> get conflicts =>
      items.where((i) => i.isConflict).toList();
  List<ExpertImportItem> get rejected =>
      items.where((i) => i.isRejected).toList();

  int get total => items.length;
  bool get hasConflicts => conflicts.isNotEmpty;

  static const empty = ExpertImportPlan(items: []);
}

// ---------------------------------------------------------------------------
// 结果模型
// ---------------------------------------------------------------------------

/// 单条导入结果类别。
enum ImportOutcome {
  added('新增'),
  overwritten('覆盖'),
  skipped('跳过'),
  failed('失败');

  const ImportOutcome(this.label);
  final String label;
}

/// 单条导入结果。
class ExpertImportResult {
  const ExpertImportResult({
    required this.displayName,
    required this.outcome,
    this.expertId,
    this.reason,
    this.notes = const [],
  });

  final String displayName;
  final ImportOutcome outcome;
  final String? expertId;
  final String? reason;

  /// 引用回落提示（如「模型『deepseek-chat』在本机不存在，已使用默认模型」）。
  final List<String> notes;
}

/// 汇总报告（规范 §9：成功 / 跳过 / 失败逐条可见）。
class ExpertImportReport {
  const ExpertImportReport({required this.results});

  final List<ExpertImportResult> results;

  int _count(ImportOutcome o) =>
      results.where((r) => r.outcome == o).length;

  int get added => _count(ImportOutcome.added);
  int get overwritten => _count(ImportOutcome.overwritten);
  int get skipped => _count(ImportOutcome.skipped);
  int get failed => _count(ImportOutcome.failed);

  /// 成功 = 新增 + 覆盖。
  int get success => added + overwritten;

  List<ExpertImportResult> get failures =>
      results.where((r) => r.outcome == ImportOutcome.failed).toList();

  /// 摘要文案（规范 §10）。
  String summary() => '导入完成：新增 $added 位，跳过 $skipped 位，失败 $failed 位';
}

// ---------------------------------------------------------------------------
// 导入服务
// ---------------------------------------------------------------------------

/// 导入服务。
class ExpertImportService {
  ExpertImportService(this._repos);

  final Repositories _repos;

  /// 本机应用版本（用于复用市场步骤 10 的兼容性判定）。
  static const String currentAppVersion = kDefaultExportAppVersion;

  /// 解析字节 → 导入计划（**不落库**）。
  ///
  /// [bytes] 可以是单个 `.expert`，也可以是批量 `experts-*.zip`。
  Future<ExpertImportPlan> plan(List<int> bytes) async {
    final raws = _splitPackages(bytes);
    final existing = await _repos.experts.listExperts();
    final items = <ExpertImportItem>[];
    for (final raw in raws) {
      try {
        items.add(_verifyOne(raw, existing));
      } catch (e) {
        // 失败隔离：单个包解析异常不阻断整批。
        items.add(_reject(raw, '解析异常：$e'));
      }
    }
    return ExpertImportPlan(items: items);
  }

  /// 按用户决策落库。
  ///
  /// [decisions]：`item.key → ConflictStrategy`（仅对冲突项生效；缺省 = 新建副本）。
  Future<ExpertImportReport> apply(
    ExpertImportPlan plan, {
    Map<String, ConflictStrategy> decisions = const {},
    int? nowMs,
    void Function(int done, int total)? onProgress,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final total = plan.items.length;
    final results = <ExpertImportResult>[];
    var done = 0;
    for (final item in plan.items) {
      results.add(await _applyItem(item, decisions, now));
      done++;
      onProgress?.call(done, total);
    }
    return ExpertImportReport(results: results);
  }

  // -------------------------------------------------------------------------
  // 解包 / 分片
  // -------------------------------------------------------------------------

  /// 顶层解包：单 `.expert`（含 manifest.json）或批量 zip（含多个 `.expert`）。
  List<_RawPackage> _splitPackages(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (data.isEmpty) {
      throw const UnsafePackageError('import.empty：导入内容为空');
    }
    final arc.Archive outer;
    try {
      outer = arc.ZipDecoder().decodeBytes(data);
    } catch (e) {
      throw UnsafePackageError('import.zip：不是合法的 .expert / .zip 包：$e');
    }

    // 顶层有 manifest.json → 单专家 `.expert`。
    final hasManifest =
        outer.files.any((f) => f.isFile && f.name == kBundleManifestFile);
    if (hasManifest) {
      return [_RawPackage(fileName: '-', bytes: data)];
    }

    // 否则视为批量：收集 `.expert` 条目。
    final out = <_RawPackage>[];
    for (final f in outer.files) {
      if (!f.isFile) continue;
      if (f.name.toLowerCase().endsWith('.expert')) {
        out.add(_RawPackage(fileName: f.name, bytes: _bytesOf(f)));
      }
    }
    if (out.isEmpty) {
      throw const UnsafePackageError('import.empty：包内未找到 .expert 专家文件');
    }
    return out;
  }

  /// 解析单个 `.expert` → 导入项（校验 + 冲突预检）。
  ExpertImportItem _verifyOne(_RawPackage raw, List<Expert> existing) {
    // 解包
    final arc.Archive arch;
    try {
      arch = arc.ZipDecoder().decodeBytes(raw.bytes);
    } catch (e) {
      return _reject(raw, '不是合法的 .expert 包：$e');
    }
    final entries = <PackageEntry>[];
    for (final f in arch.files) {
      if (f.isFile) {
        entries.add(PackageEntry(path: f.name, bytes: _bytesOf(f)));
      }
    }
    final payload = PackagePayload(entries);

    // 步骤 2：manifest 解析
    final manifestEntry = payload.find(kBundleManifestFile);
    if (manifestEntry == null) return _reject(raw, '包内缺少 manifest.json');
    final PackageManifest manifest;
    try {
      manifest = PackageManifest.parse(utf8.decode(manifestEntry.bytes));
    } on AppError catch (e) {
      return _reject(raw, 'manifest 解析失败：${e.message}');
    }

    // 步骤 3–10：复用市场安全链。
    final verification = PackageVerifier.verify(
      payload: payload,
      manifest: manifest,
      appVersion: SemVer.tryParse(currentAppVersion),
    );
    if (!verification.ok) {
      final f = verification.firstFailure;
      final detail = '${f?.name ?? ''} ${f?.detail ?? ''}'.trim();
      return _reject(raw, '安全校验未通过：$detail', report: verification.report());
    }

    // S1：规范版本
    ExpertProfile? profile;
    final profileEntry = payload.find(kBundleProfileFile);
    if (profileEntry != null) {
      try {
        profile = ExpertProfile.parse(utf8.decode(profileEntry.bytes));
      } catch (e) {
        return _reject(raw, 'profile.json 解析失败：$e');
      }
    }
    final specVersion = profile?.specVersion ?? kExportSpecVersion;
    final compat = VersionCompat.decide(specVersion);
    if (compat == SpecCompat.newer) {
      return _reject(
        raw,
        '该文件由更新版本导出（规范 v$specVersion），请升级应用后再导入',
      );
    }

    // S2：敏感串扫描（排除 manifest.json 的哈希 / 二进制头像）
    for (final e in entries) {
      if (e.path == kBundleManifestFile || e.path == kBundleAvatarFile) {
        continue;
      }
      final String text;
      try {
        text = utf8.decode(e.bytes);
      } catch (_) {
        continue;
      }
      if (SecretLeakScan.contains(text)) {
        return _reject(raw, '文件疑似包含密钥信息，已拒绝导入');
      }
    }

    // S3：slug / 名称合法性
    if (!SlugRule.isValid(manifest.slug)) {
      return _reject(raw, 'slug 非法：${manifest.slug}');
    }
    final displayName = manifest.displayName.trim();
    if (displayName.isEmpty) {
      return _reject(raw, '专家名称为空');
    }

    // expert.json（可选）+ 入口提示词
    ExpertJson? expertJson;
    final ejEntry = payload.find(kBundleExpertJsonFile);
    if (ejEntry != null) {
      try {
        final d = jsonDecode(utf8.decode(ejEntry.bytes));
        if (d is Map<String, dynamic>) expertJson = ExpertJson.fromJson(d);
      } catch (_) {
        // expert.json 非必需字段缺失 / 脏值：忽略，不阻断（manifest 已含必要信息）。
      }
    }
    final promptEntry = payload.find(manifest.entry);
    final systemPrompt =
        promptEntry == null ? '' : utf8.decode(promptEntry.bytes);

    // S4：冲突预检
    final conflict = ConflictResolver.detect(
      packageId: manifest.packageId,
      version: manifest.version.toString(),
      slug: manifest.slug,
      displayName: displayName,
      existing: existing,
    );

    return ExpertImportItem(
      sourceFile: raw.fileName,
      slug: manifest.slug,
      displayName: displayName,
      version: manifest.version.toString(),
      packageId: manifest.packageId,
      categoryId: manifest.categoryId,
      status:
          conflict == null ? ImportItemStatus.ready : ImportItemStatus.conflict,
      specVersion: specVersion,
      compat: compat,
      conflict: conflict,
      profile: profile,
      expertJson: expertJson,
      systemPrompt: systemPrompt,
      packageBytes: raw.bytes,
    );
  }

  // -------------------------------------------------------------------------
  // 落库
  // -------------------------------------------------------------------------

  Future<ExpertImportResult> _applyItem(
    ExpertImportItem item,
    Map<String, ConflictStrategy> decisions,
    int now,
  ) async {
    if (item.isRejected) {
      return ExpertImportResult(
        displayName: item.displayName,
        outcome: ImportOutcome.failed,
        reason: item.reason ?? '已拒绝',
      );
    }
    final strategy = item.isConflict
        ? (decisions[item.key] ?? ConflictStrategy.newCopy)
        : ConflictStrategy.newCopy;
    if (strategy == ConflictStrategy.skip) {
      return ExpertImportResult(
        displayName: item.displayName,
        outcome: ImportOutcome.skipped,
        reason: '已跳过（用户选择）',
      );
    }
    try {
      return await _write(item, strategy: strategy, now: now);
    } on AppError catch (e) {
      return ExpertImportResult(
        displayName: item.displayName,
        outcome: ImportOutcome.failed,
        reason: e.message,
      );
    } catch (e) {
      return ExpertImportResult(
        displayName: item.displayName,
        outcome: ImportOutcome.failed,
        reason: '$e',
      );
    }
  }

  /// 写入一条专家（原子：失败补偿删除 / 覆盖还原）。
  Future<ExpertImportResult> _write(
    ExpertImportItem item, {
    required ConflictStrategy strategy,
    required int now,
  }) async {
    final notes = <String>[];
    final profile = item.profile;
    final hasProfile = profile != null;
    final isOverwrite =
        strategy == ConflictStrategy.overwrite && item.conflict != null;
    final isCopy = !isOverwrite;
    // 冲突 + 新建副本：按规范 §8 丢弃知识库绑定（避免与既有专家争用同一库）。
    // 全新导入（无冲突）按 §2.2 / §7-S5 正常解析并携带绑定。
    final isConflictCopy = item.conflict != null && !isOverwrite;
    final carryBindings = hasProfile && !isConflictCopy;
    final overwriteId = item.conflict?.matchedExpertId;

    // 副本命名：与既有名不冲突的「（导入 N）」。
    final existingNames = <String>{
      for (final e in await _repos.experts.listExperts()) e.name,
    };
    final targetId = isOverwrite ? overwriteId! : Ids.next('e');
    // 名称：全新导入保持原名；**冲突副本**才加「（导入 N）」后缀。
    final name = isConflictCopy
        ? ConflictResolver.copyName(item.displayName, existingNames)
        : item.displayName;

    // S5：引用解析
    final modelRef =
        await _resolveModelRef(profile?.runtime?.modelProfileRef, notes);
    final credRef =
        await _resolveCredentialRef(profile?.runtime?.credentialRefName, notes);
    final styleId = _resolveStyle(profile?.userState?.styleId, notes);

    // 知识库绑定（S5 按名解析；冲突副本不携带）。
    final bindingTargets = <({String kbId, KnowledgeBindingProfile spec})>[];
    if (carryBindings) {
      for (final b in profile.knowledgeBindings) {
        final kb = await _findKbByName(b.knowledgeBaseName);
        if (kb == null) {
          notes.add('知识库『${b.knowledgeBaseName}』未找到，已跳过该绑定');
          continue;
        }
        bindingTargets.add((kbId: kb.id, spec: b));
      }
    }

    // 覆盖：保留既有 id / createdAt / source；副本：全新。
    var createdAt = now;
    var source = ExpertSource.imported;
    Expert? oldExpert;
    ExpertRuntimeConfig? oldCfg;
    ExpertUserState? oldState;
    List<String> oldTags = const [];
    List<ExpertKnowledgeBinding> oldBindings = const [];
    if (isOverwrite) {
      oldExpert = await _repos.experts.getExpert(targetId);
      oldCfg = await _repos.experts.getRuntimeConfig(targetId);
      oldState = await _repos.experts.getUserState(targetId);
      oldTags = await _repos.experts.getTags(targetId);
      oldBindings = await _repos.experts.listKnowledgeBindings(targetId);
      createdAt = oldExpert?.createdAt ?? now;
      source = oldExpert?.source ?? ExpertSource.imported;
    }

    final expert = Expert(
      id: targetId,
      name: name,
      profession: item.expertJson?.profession,
      avatarEmoji: item.expertJson?.emoji,
      avatarColor: item.expertJson?.color,
      systemPrompt: item.systemPrompt,
      welcomeMessage: profile?.expert.welcomeMessage,
      quickPrompts: profile?.expert.quickPrompts ?? const [],
      packageId: item.packageId,
      packageVersion: item.version.isEmpty ? null : item.version,
      categoryId: item.categoryId,
      source: source,
      createdAt: createdAt,
      updatedAt: now,
    );

    try {
      await _repos.experts.upsertExpert(expert);

      // 运行配置 / 用户状态：副本恒写（默认档）；覆盖仅在携带 profile 时写。
      if (isCopy || hasProfile) {
        await _repos.experts.upsertRuntimeConfig(ExpertRuntimeConfig(
          expertId: targetId,
          modelProfileId: modelRef,
          credentialProfileId: credRef,
          temperature: profile?.runtime?.temperature,
          topP: profile?.runtime?.topP,
          maxTokens: profile?.runtime?.maxTokens,
          groundingPolicy:
              GroundingPolicy.parse(profile?.runtime?.groundingPolicy),
          enabled: profile?.runtime?.enabled ?? true,
        ));
        await _repos.experts.upsertUserState(ExpertUserState(
          expertId: targetId,
          remark: profile?.userState?.remark,
          customPrompt: profile?.userState?.customPrompt,
          styleId: styleId,
          pinned: profile?.userState?.pinned ?? false,
        ));
      }

      // 标签：优先 profile，其次 expert.json。
      final tagList = (profile != null && profile.tags.isNotEmpty)
          ? profile.tags
          : (item.expertJson?.tags ?? const <String>[]);
      if (tagList.isNotEmpty) {
        await _repos.experts.setTags(targetId, tagList);
      }

      // 知识库绑定（覆盖：先清旧再写新；全新导入：直接写）。
      if (carryBindings) {
        for (final b in oldBindings) {
          await _repos.experts
              .removeKnowledgeBinding(targetId, b.knowledgeBaseId);
        }
        for (final t in bindingTargets) {
          await _repos.experts.upsertKnowledgeBinding(ExpertKnowledgeBinding(
            expertId: targetId,
            knowledgeBaseId: t.kbId,
            priority: t.spec.priority,
            enabled: t.spec.enabled,
            topK: t.spec.topK,
            similarityThreshold: t.spec.similarityThreshold,
          ));
        }
      }

      if (item.compat == SpecCompat.older) {
        notes.add('已按旧版规范（v${item.specVersion}）导入，缺失字段已补齐默认值');
      }
      return ExpertImportResult(
        displayName: name,
        outcome:
            isOverwrite ? ImportOutcome.overwritten : ImportOutcome.added,
        expertId: targetId,
        notes: notes,
      );
    } catch (e) {
      // 单条原子：失败补偿（副本删除 / 覆盖还原）。
      await _compensate(
        isOverwrite: isOverwrite,
        id: targetId,
        oldExpert: oldExpert,
        oldCfg: oldCfg,
        oldState: oldState,
        oldTags: oldTags,
        oldBindings: oldBindings,
      );
      rethrow;
    }
  }

  /// 补偿：
  /// - 副本 → 整条删除（依赖 FK 级联清 runtime/userState/tags/bindings）；
  /// - 覆盖 → 还原快照（尽力而为）。
  Future<void> _compensate({
    required bool isOverwrite,
    required String id,
    Expert? oldExpert,
    ExpertRuntimeConfig? oldCfg,
    ExpertUserState? oldState,
    List<String> oldTags = const [],
    List<ExpertKnowledgeBinding> oldBindings = const [],
  }) async {
    try {
      if (!isOverwrite) {
        await _repos.experts.deleteExpert(id);
        return;
      }
      if (oldExpert != null) await _repos.experts.upsertExpert(oldExpert);
      if (oldCfg != null) await _repos.experts.upsertRuntimeConfig(oldCfg);
      if (oldState != null) await _repos.experts.upsertUserState(oldState);
      for (final b in await _repos.experts.listKnowledgeBindings(id)) {
        await _repos.experts.removeKnowledgeBinding(id, b.knowledgeBaseId);
      }
      for (final b in oldBindings) {
        await _repos.experts.upsertKnowledgeBinding(b);
      }
      if (oldTags.isNotEmpty) {
        await _repos.experts.setTags(id, oldTags);
      }
    } catch (_) {
      // 补偿自身失败：不再上抛，避免掩盖原始错误（上层已记录该条失败）。
    }
  }

  // -------------------------------------------------------------------------
  // S5 引用解析
  // -------------------------------------------------------------------------

  Future<String?> _resolveModelRef(String? ref, List<String> notes) async {
    final r = (ref ?? '').trim();
    if (r.isEmpty) return null;
    final byId = await _repos.providers.getModel(r);
    if (byId != null) return byId.id;
    // 引用名也可能写的是裸模型名（如 `deepseek-chat`）。
    for (final m in await _repos.providers.listModels()) {
      if (m.modelId == r) return m.id;
    }
    notes.add('模型『$r』在本机不存在，已使用默认模型');
    return null;
  }

  Future<String?> _resolveCredentialRef(
      String? name, List<String> notes) async {
    final n = (name ?? '').trim();
    if (n.isEmpty) return null;
    for (final c in await _repos.credentials.list()) {
      if (c.name.trim() == n) return c.id;
    }
    notes.add('凭据『$n』在本机不存在，已使用默认凭据');
    return null;
  }

  String? _resolveStyle(String? styleId, List<String> notes) {
    final s = (styleId ?? '').trim();
    if (s.isEmpty) return null;
    final parsed = ExpertStyle.parse(s);
    if (parsed == null) {
      notes.add('风格『$s』不在本机预设内，已置空');
      return null;
    }
    return parsed.name;
  }

  Future<KnowledgeBase?> _findKbByName(String name) async {
    final n = name.trim();
    if (n.isEmpty) return null;
    for (final kb in await _repos.knowledge.listBases()) {
      if (kb.name.trim() == n) return kb;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // 工具
  // -------------------------------------------------------------------------

  ExpertImportItem _reject(_RawPackage raw, String reason, {String? report}) =>
      ExpertImportItem(
        sourceFile: raw.fileName,
        slug: '',
        displayName: raw.fileName,
        version: '',
        status: ImportItemStatus.rejected,
        specVersion: kExportSpecVersion,
        compat: SpecCompat.equal,
        reason: reason,
        verifyReport: report,
        packageBytes: raw.bytes,
      );
}

/// 顶层解包得到的一个原始包（未校验）。
class _RawPackage {
  const _RawPackage({required this.fileName, required this.bytes});
  final String fileName;
  final Uint8List bytes;
}

/// 取 archive 文件内容字节。
Uint8List _bytesOf(arc.ArchiveFile f) {
  final c = f.content;
  if (c is Uint8List) return c;
  return Uint8List.fromList(List<int>.from(c as List<int>));
}
