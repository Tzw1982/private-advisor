/// 专家导入导出 · 纯逻辑层（模型 + 规则）。
///
/// 面向需求「人才市场专家实现导入和导出功能，并设置好规范」（任务 #69）。
///
/// 设计要点：
/// - 导出格式**复用市场 `.expert`（ZIP）包**——本文件定义其中的档案层
///   （`profile.json`）、自建专家本体（`expert.json`）与批量清单（`bundle.json`）
///   的**纯数据模型**，以及 slug / 冲突 / 敏感串 / 版本兼容等**纯规则**；
/// - 本文件**零基础设施依赖**（不引 IO / ZIP / SQLite），仅依赖同级 domain
///   （[Expert] / `common.dart`），可在纯 Dart 环境 `dart run` 自证；
/// - 打包（ZIP 编码）/ 哈希 / 落库等有副作用的部分在 application 层
///   （`expert_export.dart` / `expert_import.dart`）。
///
/// 铁律（规范 §6）：
/// - **明文 API Key 永不进入导出文件**，档案里只保留引用名；
/// - 导入侧对疑似密钥做正则扫描，**命中即拒**，绝不"脱敏后导入"。
library;

import 'dart:convert';

import 'common.dart';
import 'expert.dart';

// ---------------------------------------------------------------------------
// 版本与常量
// ---------------------------------------------------------------------------

/// 本机支持的导入导出规范版本（写入 / 读取 `profile.json.specVersion`）。
const int kExportSpecVersion = 1;

/// 已知**最高**规范版本；文件 specVersion 高于此值 → **拒绝导入**（规范 §4）。
const int kMaxSupportedSpecVersion = kExportSpecVersion;

/// 缺省应用版本（写入 `profile.json.appVersion` / `bundle.json.appVersion`）。
const String kDefaultExportAppVersion = '1.3.0';

// 包内固定文件名（与市场包逐字同构）。
const String kBundleManifestFile = 'manifest.json';
const String kBundleExpertJsonFile = 'expert.json';
const String kBundleProfileFile = 'profile.json';
const String kBundleReadmeFile = 'README.md';
const String kBundleEntryFile = 'agents/main.md';
const String kBundleAvatarFile = 'assets/avatar.png';

/// 批量导出 zip 内的清单文件名。
const String kBatchBundleFile = 'bundle.json';

/// 自建 / 导入专家缺省包版本（无 `packageVersion` 时）。
const String kDefaultPackageVersion = '1.0.0';

/// 自建 / 导入专家缺省分类（WorkBuddy 15 类之一）。
const String kDefaultCategoryId = '12-IndustryConsultant';

// ---------------------------------------------------------------------------
// 包层：expert.json
// ---------------------------------------------------------------------------

/// `.expert` 包内 `expert.json`（与市场包同构）。
///
/// `emoji` / `color` 对应 schema v9 新增列 `avatarEmoji` / `avatarColor`
/// （第 #66 轮）。
class ExpertJson {
  const ExpertJson({
    required this.displayName,
    this.profession,
    this.description,
    this.tags = const [],
    this.recommendedModel,
    this.emoji,
    this.color,
  });

  final String displayName;
  final String? profession;
  final String? description;
  final List<String> tags;
  final String? recommendedModel;

  /// 头像 emoji（对应 v9 `avatarEmoji`）。
  final String? emoji;

  /// 头像底色（对应 v9 `avatarColor`）。
  final String? color;

  factory ExpertJson.fromJson(Map<String, dynamic> j) => ExpertJson(
        displayName: _nonEmptyStr(j['displayName']) ?? '',
        profession: _nonEmptyStr(j['profession']),
        description: _nonEmptyStr(j['description']),
        tags: _strList(j['tags']),
        recommendedModel: _nonEmptyStr(j['recommendedModel']),
        emoji: _nonEmptyStr(j['emoji']),
        color: _nonEmptyStr(j['color']),
      );

  Map<String, dynamic> toJson() => {
        'displayName': displayName,
        if (profession != null) 'profession': profession,
        if (description != null) 'description': description,
        if (tags.isNotEmpty) 'tags': tags,
        if (recommendedModel != null) 'recommendedModel': recommendedModel,
        if (emoji != null) 'emoji': emoji,
        if (color != null) 'color': color,
      };
}

// ---------------------------------------------------------------------------
// 档案层：profile.json
// ---------------------------------------------------------------------------

/// `profile.json` 的 `expert` 段（专家本体补充）。
class ExpertFieldProfile {
  const ExpertFieldProfile({
    this.welcomeMessage,
    this.quickPrompts = const [],
    this.source,
    this.emoji,
    this.color,
  });

  final String? welcomeMessage;
  final List<String> quickPrompts;

  /// 来源（`market` / `local` / `imported`）。
  final String? source;

  /// emoji / color 镜像（便于低版本读取，规范 §2.2）。
  final String? emoji;
  final String? color;

  factory ExpertFieldProfile.fromJson(Map<String, dynamic> j) =>
      ExpertFieldProfile(
        welcomeMessage: _nonEmptyStr(j['welcomeMessage']),
        quickPrompts: _strList(j['quickPrompts']),
        source: _nonEmptyStr(j['source']),
        emoji: _nonEmptyStr(j['emoji']),
        color: _nonEmptyStr(j['color']),
      );

  Map<String, dynamic> toJson() => {
        if (welcomeMessage != null) 'welcomeMessage': welcomeMessage,
        if (quickPrompts.isNotEmpty) 'quickPrompts': quickPrompts,
        if (source != null) 'source': source,
        if (emoji != null) 'emoji': emoji,
        if (color != null) 'color': color,
      };
}

/// `profile.json` 的 `runtime` 段（[ExpertRuntimeConfig]）。
///
/// ★ [credentialRefName] **只存引用名**，绝不含明文 Key（规范 §6）。
class RuntimeProfile {
  const RuntimeProfile({
    this.modelProfileRef,
    this.credentialRefName,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.groundingPolicy,
    this.enabled = true,
  });

  final String? modelProfileRef;
  final String? credentialRefName;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final String? groundingPolicy;
  final bool enabled;

  factory RuntimeProfile.fromJson(Map<String, dynamic> j) => RuntimeProfile(
        modelProfileRef: _nonEmptyStr(j['modelProfileRef']),
        credentialRefName: _nonEmptyStr(j['credentialRefName']),
        temperature: _numToDouble(j['temperature']),
        topP: _numToDouble(j['topP']),
        maxTokens: _numToInt(j['maxTokens']),
        groundingPolicy: _nonEmptyStr(j['groundingPolicy']),
        enabled: j['enabled'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        if (modelProfileRef != null) 'modelProfileRef': modelProfileRef,
        if (credentialRefName != null) 'credentialRefName': credentialRefName,
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'topP': topP,
        if (maxTokens != null) 'maxTokens': maxTokens,
        if (groundingPolicy != null) 'groundingPolicy': groundingPolicy,
        'enabled': enabled,
      };
}

/// `profile.json` 的 `userState` 段（[ExpertUserState]）。
///
/// **`groupId` 不导出**——本机分组结构跨机无意义（规范 §2.2）。
class UserStateProfile {
  const UserStateProfile({
    this.remark,
    this.customPrompt,
    this.styleId,
    this.pinned = false,
  });

  final String? remark;
  final String? customPrompt;
  final String? styleId;
  final bool pinned;

  factory UserStateProfile.fromJson(Map<String, dynamic> j) => UserStateProfile(
        remark: _nonEmptyStr(j['remark']),
        customPrompt: _nonEmptyStr(j['customPrompt']),
        styleId: _nonEmptyStr(j['styleId']),
        pinned: j['pinned'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        if (remark != null) 'remark': remark,
        if (customPrompt != null) 'customPrompt': customPrompt,
        if (styleId != null) 'styleId': styleId,
        'pinned': pinned,
      };
}

/// `profile.json` 的知识库绑定条目。
///
/// **按知识库名导出，不导 id**（跨机 id 无意义）；导入侧按名匹配（规范 §2.2）。
class KnowledgeBindingProfile {
  const KnowledgeBindingProfile({
    required this.knowledgeBaseName,
    this.priority = 0,
    this.enabled = true,
    this.topK = 5,
    this.similarityThreshold = 0.5,
  });

  final String knowledgeBaseName;
  final int priority;
  final bool enabled;
  final int topK;
  final double similarityThreshold;

  factory KnowledgeBindingProfile.fromJson(Map<String, dynamic> j) =>
      KnowledgeBindingProfile(
        knowledgeBaseName: _nonEmptyStr(j['knowledgeBaseName']) ?? '',
        priority: _numToInt(j['priority']) ?? 0,
        enabled: j['enabled'] as bool? ?? true,
        topK: _numToInt(j['topK']) ?? 5,
        similarityThreshold: _numToDouble(j['similarityThreshold']) ?? 0.5,
      );

  Map<String, dynamic> toJson() => {
        'knowledgeBaseName': knowledgeBaseName,
        'priority': priority,
        'enabled': enabled,
        'topK': topK,
        'similarityThreshold': similarityThreshold,
      };
}

/// 档案层 `profile.json`（本机设置，可选导出；**默认不导**）。
class ExpertProfile {
  const ExpertProfile({
    this.specVersion = kExportSpecVersion,
    this.exportedAt = 0,
    this.appVersion = '',
    this.expert = const ExpertFieldProfile(),
    this.runtime,
    this.userState,
    this.tags = const [],
    this.knowledgeBindings = const [],
  });

  /// 本规范版本（导入导出专用；高版本拒绝、低版本补齐默认值）。
  final int specVersion;
  final int exportedAt;
  final String appVersion;
  final ExpertFieldProfile expert;
  final RuntimeProfile? runtime;
  final UserStateProfile? userState;
  final List<String> tags;
  final List<KnowledgeBindingProfile> knowledgeBindings;

  factory ExpertProfile.fromJson(Map<String, dynamic> j) {
    final e = j['expert'];
    final r = j['runtime'];
    final u = j['userState'];
    final bindings = <KnowledgeBindingProfile>[];
    final raw = j['knowledgeBindings'];
    if (raw is List) {
      for (final it in raw) {
        if (it is Map<String, dynamic>) {
          final b = KnowledgeBindingProfile.fromJson(it);
          if (b.knowledgeBaseName.isNotEmpty) bindings.add(b);
        }
      }
    }
    return ExpertProfile(
      specVersion: _numToInt(j['specVersion']) ?? kExportSpecVersion,
      exportedAt: _numToInt(j['exportedAt']) ?? 0,
      appVersion: (j['appVersion'] as String?) ?? '',
      expert: e is Map<String, dynamic>
          ? ExpertFieldProfile.fromJson(e)
          : const ExpertFieldProfile(),
      runtime: r is Map<String, dynamic> ? RuntimeProfile.fromJson(r) : null,
      userState: u is Map<String, dynamic> ? UserStateProfile.fromJson(u) : null,
      tags: _strList(j['tags']),
      knowledgeBindings: bindings,
    );
  }

  /// 解析 `profile.json` 文本；非对象 / 非法 JSON → [SchemaError]。
  static ExpertProfile parse(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) {
        throw const SchemaError('profile.json 根节点必须是对象');
      }
      return ExpertProfile.fromJson(decoded);
    } on AppError {
      rethrow;
    } catch (e) {
      throw SchemaError('profile.json 解析失败：$e');
    }
  }

  Map<String, dynamic> toJson() => {
        'specVersion': specVersion,
        'exportedAt': exportedAt,
        'appVersion': appVersion,
        'expert': expert.toJson(),
        if (runtime != null) 'runtime': runtime!.toJson(),
        if (userState != null) 'userState': userState!.toJson(),
        if (tags.isNotEmpty) 'tags': tags,
        if (knowledgeBindings.isNotEmpty)
          'knowledgeBindings': [
            for (final b in knowledgeBindings) b.toJson(),
          ],
      };
}

// ---------------------------------------------------------------------------
// 批量清单：bundle.json
// ---------------------------------------------------------------------------

/// 批量 zip 内一条专家条目。
class BundleItem {
  const BundleItem({
    required this.slug,
    required this.displayName,
    required this.version,
    this.fileName = '',
    this.hasProfile = false,
  });

  final String slug;
  final String displayName;
  final String version;

  /// 批量 zip 内对应 `.expert` 文件名（additive：便于定位/展示）。
  final String fileName;

  /// 该条目是否携带档案层（`profile.json`）。
  final bool hasProfile;

  factory BundleItem.fromJson(Map<String, dynamic> j) => BundleItem(
        slug: (j['slug'] as String?) ?? '',
        displayName: (j['displayName'] as String?) ?? '',
        version: (j['version'] as String?) ?? '',
        fileName: (j['fileName'] as String?) ?? '',
        hasProfile: j['hasProfile'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'slug': slug,
        'displayName': displayName,
        'version': version,
        'fileName': fileName,
        'hasProfile': hasProfile,
      };
}

/// 批量导出 zip 的清单 `bundle.json`。
class BundleManifest {
  const BundleManifest({
    this.specVersion = kExportSpecVersion,
    this.appVersion = '',
    this.exportedAt = 0,
    this.items = const [],
  });

  final int specVersion;
  final String appVersion;
  final int exportedAt;
  final List<BundleItem> items;

  int get count => items.length;

  factory BundleManifest.fromJson(Map<String, dynamic> j) {
    final items = <BundleItem>[];
    final raw = j['items'];
    if (raw is List) {
      for (final it in raw) {
        if (it is Map<String, dynamic>) items.add(BundleItem.fromJson(it));
      }
    }
    return BundleManifest(
      specVersion: _numToInt(j['specVersion']) ?? kExportSpecVersion,
      appVersion: (j['appVersion'] as String?) ?? '',
      exportedAt: _numToInt(j['exportedAt']) ?? 0,
      items: items,
    );
  }

  /// 解析 `bundle.json` 文本；非对象 / 非法 JSON → [SchemaError]。
  static BundleManifest parse(String jsonText) {
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) {
        throw const SchemaError('bundle.json 根节点必须是对象');
      }
      return BundleManifest.fromJson(decoded);
    } on AppError {
      rethrow;
    } catch (e) {
      throw SchemaError('bundle.json 解析失败：$e');
    }
  }

  Map<String, dynamic> toJson() => {
        'specVersion': specVersion,
        'appVersion': appVersion,
        'exportedAt': exportedAt,
        'count': items.length,
        'items': [for (final it in items) it.toJson()],
      };
}

// ---------------------------------------------------------------------------
// slug 规则（规范 §5）
// ---------------------------------------------------------------------------

/// slug 生成 / 合法性（与市场步骤 5 的 `^[a-z0-9][a-z0-9\-]*$` 同口径）。
abstract final class SlugRule {
  static final RegExp _re = RegExp(r'^[a-z0-9][a-z0-9\-]*$');

  /// 是否合法 slug（与市场 Schema Validate 同口径）。
  static bool isValid(String slug) => _re.hasMatch(slug);

  /// 由专家名生成 slug（规范 §5）：
  ///
  /// - 保留 ASCII 字母数字，空白 / 常见分隔符归一为 `-`，其余（含 CJK）丢弃；
  /// - 结果为空（纯中文名等）→ 降级为 `expert-<id 后 8 位>`。
  ///
  /// > 与规范「id 前 8 位」的偏差（**已文档化**）：`Ids.next` 的 id 形如
  /// > `e_<毫秒时间>-<随机>`，**前 8 位是时间前缀**——同毫秒创建的多位专家会共用
  /// > 前缀，导致 slug 碰撞、进而引发误判冲突。改取**尾部 8 位**（随机后缀，熵高）
  /// > 既保持"由 id 派生的稳定兜底标识"语义，又消除碰撞。
  static String fromName(String name, {String? fallbackId}) {
    final ascii = _sanitize(name);
    if (ascii.isNotEmpty) return _clip(ascii);
    final id = (fallbackId ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final suffix = id.length >= 8
        ? id.substring(id.length - 8).toLowerCase()
        : id.toLowerCase().padRight(8, '0');
    return 'expert-$suffix';
  }

  static String _sanitize(String name) {
    final lower = name.trim().toLowerCase();
    final buf = StringBuffer();
    for (final r in lower.runes) {
      final ch = String.fromCharCode(r);
      if (_alnum.hasMatch(ch)) {
        buf.write(ch);
      } else if (_separator.hasMatch(ch)) {
        buf.write('-');
      }
      // 其它（含 CJK / 标点）丢弃。
    }
    return buf
        .toString()
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
  }

  static String _clip(String s) => s.length > 64
      ? s.substring(0, 64).replaceAll(RegExp(r'-+$'), '')
      : s;

  static final RegExp _alnum = RegExp(r'[a-z0-9]');
  static final RegExp _separator = RegExp(r'[\s\-_./\\]');
}

// ---------------------------------------------------------------------------
// 敏感串扫描（规范 §6 · 护栏）
// ---------------------------------------------------------------------------

/// 一次敏感串命中。
class SecretHit {
  const SecretHit({required this.patternName, required this.sample});

  /// 命中类别名（如「sk 密钥」）。
  final String patternName;

  /// 命中片段（**已掩码**；不落全文，避免二次泄漏）。
  final String sample;

  @override
  String toString() => '$patternName（$sample）';
}

/// 疑似密钥正则扫描（导入侧强制、导出侧双保险）。
abstract final class SecretLeakScan {
  /// 已知高置信度模式 + 长随机串。
  ///
  /// > 注意：调用方**必须排除 `manifest.json`**（其 `sha256` / `files[].sha256`
  /// > 是 64 位 hex，会命中"长随机串"），只扫描专家文本内容。
  ///
  /// > 赋值式两类（`环境变量密钥` / `赋值式密钥`）已收窄为**必须构成真正的赋值**
  /// > （键后紧接 `=` / `:` 且值为长度达标的实值），以免把英文散文里的普通词
  /// > （如 `the secret: keep it private`）误判为密钥、导致合法专家被拒收 / 导出被中止。
  static final Map<String, RegExp> patterns = {
    'sk 密钥': RegExp(r'sk-[A-Za-z0-9_\-]{16,}'),
    'Bearer 令牌': RegExp(r'Bearer\s+[A-Za-z0-9._\-]{16,}'),
    '已知密钥前缀': RegExp(r'(?:ghp_|gho_|ghs_|xai-|AKIA|AIza)[A-Za-z0-9_\-]{12,}'),
    '长随机串': RegExp(r'[A-Za-z0-9+/]{40,}={0,2}'),
    // 环境变量赋值：**行首**（允许前导空白）大写键 + `=` / `:` + 非空值
    //（≥8 个非空白字符）。大小写敏感（真 `.env` 约定全大写），`multiLine`
    // 锚定行首——避免把英文散文里的普通词当成赋值（如 "the password is ..."）。
    '环境变量密钥': RegExp(
        r'^[\t ]*[A-Z][A-Z0-9_]{2,}[\t ]*[:=][\t ]*\S{8,}',
        multiLine: true),
    // 小写键赋值：`api_key=` / `password=` / `token:` 等**真正构成赋值**的形态。
    // `=` 形态允许键值两侧空白；`:` 形态要求值**紧跟其后**（无空白），且值
    // ≥8 且不含空格（`\S{8,}`）——据此排除 `secret: keep it private` 这类
    // 英文散文（其后带空格）。Dart 不支持 `(?i)` 内联标志，改用
    // `caseSensitive: false`。
    '赋值式密钥': RegExp(
        r'(?:api[_-]?key|apikey|secret|passwd|password|access[_-]?token|auth[_-]?token)'
        r'(?:[\t ]*=[\t ]*\S{8,}|:\S{8,})',
        caseSensitive: false),
  };

  /// 扫描文本，返回命中列表（空 = 干净）。
  static List<SecretHit> scan(String text) {
    if (text.isEmpty) return const [];
    final hits = <SecretHit>[];
    for (final entry in patterns.entries) {
      final m = entry.value.firstMatch(text);
      if (m != null) {
        hits.add(SecretHit(
          patternName: entry.key,
          sample: _mask(m.group(0) ?? ''),
        ));
      }
    }
    return hits;
  }

  /// 是否疑似包含密钥。
  static bool contains(String text) => scan(text).isNotEmpty;

  static String _mask(String s) {
    if (s.length <= 8) return '***';
    return '${s.substring(0, 4)}***${s.substring(s.length - 2)}';
  }
}

// ---------------------------------------------------------------------------
// 版本兼容（规范 §4）
// ---------------------------------------------------------------------------

/// 规范版本兼容判定结果。
enum SpecCompat {
  equal('同版本'),
  older('旧版本（已补齐默认值）'),
  newer('高版本（拒绝导入）');

  const SpecCompat(this.label);
  final String label;
}

/// 规范版本兼容判定。
abstract final class VersionCompat {
  /// 文件版本 vs 本机支持版本（默认 [kMaxSupportedSpecVersion]）。
  static SpecCompat decide(int fileSpecVersion,
      {int supported = kMaxSupportedSpecVersion}) {
    if (fileSpecVersion > supported) return SpecCompat.newer;
    if (fileSpecVersion < supported) return SpecCompat.older;
    return SpecCompat.equal;
  }
}

// ---------------------------------------------------------------------------
// 冲突处理（规范 §8）
// ---------------------------------------------------------------------------

/// 冲突处理策略。
enum ConflictStrategy {
  newCopy('新建副本（推荐）'),
  overwrite('覆盖'),
  skip('跳过');

  const ConflictStrategy(this.label);
  final String label;

  static ConflictStrategy parse(String? v) => ConflictStrategy.values
      .firstWhere((e) => e.name == v, orElse: () => ConflictStrategy.newCopy);
}

/// 冲突类型。
enum ConflictKind {
  packageIdVersion('同包同版本'),
  slug('同标识'),
  displayName('同名');

  const ConflictKind(this.label);
  final String label;
}

/// 一条冲突信息。
class ConflictInfo {
  const ConflictInfo({
    required this.kind,
    required this.matchedExpertId,
    required this.matchedName,
  });

  final ConflictKind kind;
  final String matchedExpertId;
  final String matchedName;

  String describe() => '与既有专家「$matchedName」冲突（${kind.label}）';
}

/// 冲突判定 + 副本命名规则（规范 §8）。
abstract final class ConflictResolver {
  /// 判定顺序：`packageId+version` 全等 → `slug` 相同 → `displayName` 相同。
  static ConflictInfo? detect({
    required String? packageId,
    required String? version,
    required String slug,
    required String displayName,
    required List<Expert> existing,
  }) {
    final pid = (packageId ?? '').trim();
    if (pid.isNotEmpty) {
      for (final e in existing) {
        if (e.packageId == pid &&
            (version == null || e.packageVersion == version)) {
          return ConflictInfo(
            kind: ConflictKind.packageIdVersion,
            matchedExpertId: e.id,
            matchedName: e.name,
          );
        }
      }
    }

    if (slug.isNotEmpty) {
      for (final e in existing) {
        if (slugOf(e) == slug) {
          return ConflictInfo(
            kind: ConflictKind.slug,
            matchedExpertId: e.id,
            matchedName: e.name,
          );
        }
      }
    }

    final name = displayName.trim();
    if (name.isNotEmpty) {
      for (final e in existing) {
        if (e.name.trim() == name) {
          return ConflictInfo(
            kind: ConflictKind.displayName,
            matchedExpertId: e.id,
            matchedName: e.name,
          );
        }
      }
    }
    return null;
  }

  /// 既有专家的 slug 推定：市场包取 `packageId` 末段，否则由名称生成。
  static String slugOf(Expert e) {
    final pid = (e.packageId ?? '').trim();
    if (pid.isNotEmpty && pid.contains('.')) {
      final last = pid.split('.').last.toLowerCase();
      if (SlugRule.isValid(last)) return last;
    }
    return SlugRule.fromName(e.name, fallbackId: e.id);
  }

  /// 生成「（导入 N）」不冲突的副本名；从 2 开始递增（上限 999）。
  static String copyName(String baseName, Set<String> existingNames) {
    final base = baseName.trim().isEmpty ? '未命名专家' : baseName.trim();
    for (var n = 2; n < 1000; n++) {
      final candidate = '$base（导入 $n）';
      if (!existingNames.contains(candidate)) return candidate;
    }
    return '$base（导入副本）';
  }
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

String? _nonEmptyStr(Object? v) {
  if (v is String) {
    final t = v.trim();
    if (t.isNotEmpty) return t;
  }
  return null;
}

List<String> _strList(Object? v) {
  if (v is List) {
    return v
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
  return const [];
}

double? _numToDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

int? _numToInt(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
