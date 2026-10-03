/// 应用服务层（Application Services）。
///
/// UI **不直接操作数据库**，只调用这些服务（V1.3 §28）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/common.dart';
import '../domain/conversation.dart';
import '../domain/attachment.dart';
import '../domain/expert.dart';
import '../domain/expert_group.dart';
import '../domain/generation.dart';
import '../domain/group_directive.dart';
import '../domain/group_policy.dart';
import '../domain/knowledge.dart';
import '../domain/market.dart';
import '../domain/orchestration.dart';
import '../domain/provider.dart';
import '../domain/reasoning.dart';
import '../domain/relevance.dart';
import '../domain/strategies.dart';
import '../domain/style.dart';
import 'attachment_context.dart';
import 'attachment_store.dart' show AttachmentStore, LocalAttachmentStore;
import 'repositories.dart';
import 'vision.dart';

// ---------------------------------------------------------------------------
// 面向 UI 的生成更新事件
// ---------------------------------------------------------------------------

/// 生成过程中的 UI 更新。
sealed class GenerationUpdate {
  const GenerationUpdate();
}

/// 运行开始。
class RunStartedUpdate extends GenerationUpdate {
  const RunStartedUpdate(this.run);
  final GenerationRun run;
}

/// 某专家状态变化（思考中 / 准备发言 / 正在输入）。
class StepStatusUpdate extends GenerationUpdate {
  const StepStatusUpdate(
      {required this.expertId, required this.activity, this.note});
  final String expertId;
  final Activity activity;
  final String? note;
}

/// 流式增量。
class DeltaUpdate extends GenerationUpdate {
  const DeltaUpdate(
      {required this.expertId, required this.messageId, required this.text});
  final String expertId;
  final String messageId;
  final String text;
}

/// 某专家完成（含被跳过的情形）。
class StepFinishedUpdate extends GenerationUpdate {
  const StepFinishedUpdate({
    required this.expertId,
    required this.messageId,
    required this.content,
    this.citations = const [],
    this.skipped = false,
    this.skipReason,
  });

  final String expertId;
  final String messageId;
  final String content;
  final List<Citation> citations;
  final bool skipped;
  final String? skipReason;
}

/// 总结产出。
class SummaryUpdate extends GenerationUpdate {
  const SummaryUpdate({required this.messageId, required this.summary});
  final String messageId;
  final SummaryResult summary;
}

/// 运行结束。
class RunFinishedUpdate extends GenerationUpdate {
  const RunFinishedUpdate(this.run);
  final GenerationRun run;
}

/// 运行失败。
class RunFailedUpdate extends GenerationUpdate {
  const RunFailedUpdate(this.run, this.error);
  final GenerationRun run;
  final AppError error;
}

/// 总结者失败（第 7 轮 6-B）。
///
/// 与"成员失败"**语义独立**：成员可能全部成功，但本轮**未产出会议纪要**。
/// 群聊总结 `catch` 中 `yield`；UI 必须显式处理（穷尽 switch 强制不漏），
/// 渲染为消息流末尾的提示条，**不得静默、不得渲染成空白气泡**。
class SummaryFailedUpdate extends GenerationUpdate {
  const SummaryFailedUpdate({required this.expertId, required this.error});

  /// 失败的总结者（`cfg.summarizerExpertId ?? 首位 accepted 成员`）。
  final String expertId;
  final AppError error;
}

// ---------------------------------------------------------------------------
// ProviderService
// ---------------------------------------------------------------------------

/// Provider / Model 管理。
class ProviderService {
  ProviderService(this._repos);
  final Repositories _repos;

  /// DeepSeek 官方直连（默认内置）。
  static const deepseekProviderId = 'pp_deepseek';
  static const deepseekBaseUrl = 'https://api.deepseek.com/v1';

  /// 注册内置 Provider 与模型档案（幂等）。
  ///
  /// 内置模型经 [_syncBuiltinModel] 同步，两类字段分开处理：
  /// - 模板权威字段（`contextWindow` / `modelId` / `supportsStreaming`
  ///   / `supportsJson`）每次覆盖 → 存量过期值下次启动自纠正（reasoner 的
  ///   `context_window` 由 65536 纠正为 1M，走查反馈「显示不对」）；
  /// - 用户覆盖字段（`supportsVision` / `supportsTools`）**保留** → 视觉
  ///   开关不因重启失效（走查反馈「图片多模态时好时坏」）。
  Future<void> registerBuiltins() async {
    await _repos.providers.upsertProvider(const ProviderProfile(
      id: deepseekProviderId,
      providerId: 'deepseek',
      displayName: 'DeepSeek 官方直连',
      baseUrl: deepseekBaseUrl,
    ));
    // 内置模型同步：模板权威字段覆盖 + 用户覆盖字段保留。
    await _syncBuiltinModel(ModelProfile.deepseekChat());
    await _syncBuiltinModel(ModelProfile.deepseekReasoner());

    await _repos.providers.upsertProvider(const ProviderProfile(
      id: 'pp_ollama',
      providerId: 'ollama',
      displayName: 'Ollama（本地）',
      baseUrl: 'http://127.0.0.1:11434/v1',
    ));

    if (await _repos.settings.get(SettingKeys.defaultModelProfileId) == null) {
      await _repos.settings
          .set(SettingKeys.defaultModelProfileId, 'mp_deepseek_chat');
    }
    if (await _repos.settings.get(SettingKeys.activeProviderProfileId) ==
        null) {
      await _repos.settings
          .set(SettingKeys.activeProviderProfileId, deepseekProviderId);
    }
  }

  /// 同步一个内置模型档案：**模板权威字段覆盖 + 用户覆盖字段保留**。
  ///
  /// 两类字段的取舍（走查反馈：「视觉开关一重启就失效」+「reasoner 上下文
  /// 显示不对」必须同时满足，不能退化成"仅在不存在时插入"——那样存量库的
  /// 65536 永远纠正不了）：
  /// - **模板权威字段** `modelId` / `contextWindow` / `supportsStreaming`
  ///   / `supportsJson`：每次启动无条件覆盖——随版本升级跟着模板走
  ///   （存量 reasoner 的 65536 由此纠正为 1M）；
  /// - **用户覆盖字段** `supportsVision` / `supportsTools`：**保留用户值**——
  ///   这两项用户在「设置 → 模型视觉能力」里可改，启动不得重置
  ///   （否则图片多模态会时好时坏）。
  Future<void> _syncBuiltinModel(ModelProfile template) async {
    final existing = await _repos.providers.getModel(template.id);
    if (existing == null) {
      // 首次安装：按模板原样落库。
      await _repos.providers.upsertModel(template);
      return;
    }
    await _repos.providers.upsertModel(existing.copyWith(
      modelId: template.modelId,
      contextWindow: template.contextWindow,
      supportsStreaming: template.supportsStreaming,
      supportsJson: template.supportsJson,
    ));
  }

  Future<List<ProviderProfile>> listProviders() =>
      _repos.providers.listProviders();

  Future<List<ModelProfile>> listModels({String? providerProfileId}) =>
      _repos.providers.listModels(providerProfileId: providerProfileId);

  Future<String?> get defaultModelProfileId =>
      _repos.settings.get(SettingKeys.defaultModelProfileId);

  Future<void> setDefaultModel(String modelProfileId) =>
      _repos.settings.set(SettingKeys.defaultModelProfileId, modelProfileId);
}

// ---------------------------------------------------------------------------
// CredentialService
// ---------------------------------------------------------------------------

/// 凭据管理。明文只进 [SecretStore]，SQLite 只存 `secretRef`。
class CredentialService {
  CredentialService(this._repos);
  final Repositories _repos;

  static const defaultCredentialId = 'cred_default';

  /// 保存（或更新）默认凭据。返回值只含 ref，**不含明文**。
  Future<CredentialProfile> saveDefault({
    required String apiKey,
    required String providerProfileId,
    String name = '默认凭据',
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const ValidationError('cred.empty', 'API Key 不能为空');
    }
    final existing = await _repos.credentials.get(defaultCredentialId);
    final ref = existing?.secretRef ??
        CredentialProfile.secretRefFor(defaultCredentialId);
    await _repos.secrets.write(ref, apiKey.trim());

    final now = DateTime.now().millisecondsSinceEpoch;
    final profile = CredentialProfile(
      id: defaultCredentialId,
      providerProfileId: providerProfileId,
      name: name,
      secretRef: ref,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await _repos.credentials.upsert(profile);
    await _repos.settings
        .set(SettingKeys.defaultCredentialProfileId, profile.id);
    return profile;
  }

  /// 读取明文（仅生成时调用，**不得**写日志）。
  Future<String?> resolveSecret(String credentialProfileId) async {
    final profile = await _repos.credentials.get(credentialProfileId);
    if (profile == null) return null;
    return _repos.secrets.read(profile.secretRef);
  }

  /// 按 provider 维度保存（或更新）凭据（用户走查反馈 #15-B）。
  ///
  /// 凭据 id 取 `cred_<providerProfileId>`，与默认单例 [defaultCredentialId]
  /// **并存**——每个自定义 provider 各自持钥；`cred_default` 保存路径
  /// （[saveDefault]）零行为回归。
  Future<CredentialProfile> saveForProvider({
    required String providerProfileId,
    required String apiKey,
    String? name,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const ValidationError('cred.empty', 'API Key 不能为空');
    }
    final id = 'cred_$providerProfileId';
    final existing = await _repos.credentials.get(id);
    final ref = existing?.secretRef ?? CredentialProfile.secretRefFor(id);
    await _repos.secrets.write(ref, apiKey.trim());

    final now = DateTime.now().millisecondsSinceEpoch;
    final profile = CredentialProfile(
      id: id,
      providerProfileId: providerProfileId,
      name: name ?? '凭据（$providerProfileId）',
      secretRef: ref,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await _repos.credentials.upsert(profile);
    return profile;
  }

  /// 读取某 provider 的凭据档案（无则返回 null）。
  ///
  /// 与 [resolveSecret] 的区别：本方法**不读明文**，仅供链路上判断
  /// 「该 provider 是否已单独持钥」。
  Future<CredentialProfile?> getForProvider(String providerProfileId) =>
      _repos.credentials.get('cred_$providerProfileId');

  Future<List<CredentialProfile>> list() => _repos.credentials.list();

  Future<bool> hasDefault() async =>
      (await _repos.credentials.get(defaultCredentialId)) != null;

  Future<String?> get defaultCredentialProfileId =>
      _repos.settings.get(SettingKeys.defaultCredentialProfileId);
}

// ---------------------------------------------------------------------------
// ExpertService
// ---------------------------------------------------------------------------

/// 专家管理：创建 / 更新 / 删除 / 安装 / 克隆 / 生效配置解析 / 知识库绑定。
class ExpertService {
  ExpertService(this._repos);
  final Repositories _repos;

  /// 新建本地专家。
  Future<Expert> createLocal({
    required String name,
    required String systemPrompt,
    String? profession,
    String? categoryId,
    List<String> quickPrompts = const [],
    String? welcomeMessage,
  }) async {
    if (name.trim().isEmpty)
      throw const ValidationError('expert.name', '专家名称不能为空');
    if (systemPrompt.trim().isEmpty) {
      throw const ValidationError('expert.prompt', '系统提示词不能为空');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final expert = Expert(
      id: Ids.next('e'),
      name: name.trim(),
      profession: profession,
      systemPrompt: systemPrompt.trim(),
      welcomeMessage: welcomeMessage,
      quickPrompts: quickPrompts,
      categoryId: categoryId,
      source: ExpertSource.local,
      createdAt: now,
      updatedAt: now,
    );
    await _repos.experts.upsertExpert(expert);
    await _repos.experts
        .upsertRuntimeConfig(ExpertRuntimeConfig(expertId: expert.id));
    await _repos.experts.upsertUserState(ExpertUserState(expertId: expert.id));
    return expert;
  }

  Future<List<Expert>> list() => _repos.experts.listExperts();

  Future<Expert?> get(String id) => _repos.experts.getExpert(id);

  /// 更新专家本体（记录本地修改时间，保护其不被市场更新覆盖）。
  Future<void> updateExpert(Expert expert) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _repos.experts.upsertExpert(expert.copyWith(updatedAt: now));
    final state = await _repos.experts.getUserState(expert.id) ??
        ExpertUserState(expertId: expert.id);
    await _repos.experts.upsertUserState(state.copyWith(localModifiedAt: now));
  }

  /// 更新用户侧状态（备注 / 分组 / 置顶 / 自定义提示词）。
  Future<void> updateUserState(ExpertUserState state) async {
    await _repos.experts.upsertUserState(
      state.copyWith(localModifiedAt: DateTime.now().millisecondsSinceEpoch),
    );
  }

  Future<void> updateRuntimeConfig(ExpertRuntimeConfig config) =>
      _repos.experts.upsertRuntimeConfig(config);

  /// 删除专家及其全部关联；**市场来源**专家按「卸载」语义清 `installed_packages`。
  ///
  /// 第 #80 轮走查缺陷 B：旧实现只删 `experts`，不碰 `installed_packages` → 用户删了
  /// 专家，市场页仍认为该包「已添加」，而安装入口首行的「已添加」判定使其**永久无法重装**。
  ///
  /// 边界（务必保持）：
  /// - 仅当专家 `source == market` **且** `packageId != null` 时才考虑卸载；
  ///   本地（`local`）/ 导入（`imported`）专家**不碰** installed 表；
  /// - **同一包装了多位专家时，删其中一位不卸载**——仅当删除后已无任何专家引用该
  ///   `packageId` 时才调 [deleteInstalledByPackageId]（否则会让仍在用的包变「未安装」）。
  Future<void> delete(String expertId) async {
    final expert = await _repos.experts.getExpert(expertId);
    await _repos.experts.deleteExpert(expertId);
    final packageId = expert?.packageId;
    if (expert == null ||
        expert.source != ExpertSource.market ||
        packageId == null) {
      return;
    }
    final remaining = await _repos.experts.listExperts();
    final stillReferenced = remaining.any((e) => e.packageId == packageId);
    if (!stillReferenced) {
      await _repos.market.deleteInstalledByPackageId(packageId);
    }
  }

  /// 从市场包安装：一次事务写入 4 张表（契约 02 §3.3）。
  ///
  /// [avatarEmoji] / [avatarColor]（第 #66 轮新增，**additive**）：市场包自带的
  /// emoji 头像与底色。缺省 null → 该专家 UI 回退"首字 + 确定性色"。
  /// 由 [MarketService.installPackage] 从本地市场索引（`market_packages`）读出
  /// 后传入——**专家表此前没有这两列**，安装时直接丢弃，于是"市场页有 emoji、
  /// 加进通讯录变成首字"（用户走查反馈）。
  Future<Expert> installFromPackage({
    required String packageId,
    required String version,
    required String displayName,
    required String systemPrompt,
    required String installPath,
    String? profession,
    String? categoryId,
    List<String> quickPrompts = const [],
    String? welcomeMessage,
    String? avatarPath,
    String? avatarEmoji,
    String? avatarColor,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expert = Expert(
      id: Ids.next('e'),
      name: displayName,
      profession: profession,
      avatarPath: avatarPath,
      avatarEmoji: avatarEmoji,
      avatarColor: avatarColor,
      systemPrompt: systemPrompt,
      quickPrompts: quickPrompts,
      welcomeMessage: welcomeMessage,
      categoryId: categoryId,
      packageId: packageId,
      packageVersion: version,
      source: ExpertSource.market,
      createdAt: now,
      updatedAt: now,
    );
    await _repos.experts.upsertExpert(expert);
    await _repos.experts
        .upsertRuntimeConfig(ExpertRuntimeConfig(expertId: expert.id));
    await _repos.experts.upsertUserState(ExpertUserState(expertId: expert.id));
    // 安装幂等（第 #80 轮缺陷 B）：同一 `package_id` 在 `installed_packages` 中
    // **最多 1 行**。旧链路以新 `installationId` 追加 → 同包重复安装产生重复行。
    // 这里在插入前按 `packageId` 清旧，走**应用层去重**（⛔ 不加 UNIQUE 索引——
    // 存量库可能已有重复行，加索引会失败；且不动 schema / kSchemaVersion）。
    await _repos.market.deleteInstalledByPackageId(packageId);
    await _repos.market.upsertInstalled(InstalledPackage(
      installationId: Ids.next('inst'),
      packageId: packageId,
      version: SemVer.parse(version),
      installPath: installPath,
      installedAt: now,
      source: 'market',
    ));
    return expert;
  }

  /// 克隆专家（用于"分享副本"场景）。
  Future<Expert> clone(String expertId) async {
    final src = await _repos.experts.getExpert(expertId);
    if (src == null)
      throw ValidationError('expert.notfound', '专家不存在：$expertId');
    final now = DateTime.now().millisecondsSinceEpoch;
    final copy = Expert(
      id: Ids.next('e'),
      name: '${src.name} 副本',
      profession: src.profession,
      avatarPath: src.avatarPath,
      systemPrompt: src.systemPrompt,
      welcomeMessage: src.welcomeMessage,
      quickPrompts: src.quickPrompts,
      categoryId: src.categoryId,
      source: ExpertSource.local,
      createdAt: now,
      updatedAt: now,
    );
    await _repos.experts.upsertExpert(copy);
    final cfg = await _repos.experts.getRuntimeConfig(expertId);
    if (cfg != null) {
      await _repos.experts.upsertRuntimeConfig(ExpertRuntimeConfig(
        expertId: copy.id,
        modelProfileId: cfg.modelProfileId,
        credentialProfileId: cfg.credentialProfileId,
        temperature: cfg.temperature,
        topP: cfg.topP,
        maxTokens: cfg.maxTokens,
        groundingPolicy: cfg.groundingPolicy,
        enabled: cfg.enabled,
      ));
    }
    await _repos.experts.upsertUserState(ExpertUserState(expertId: copy.id));
    return copy;
  }

  /// 解析生效配置（契约 01 §5）。
  Future<EffectiveExpertConfig> resolveEffective(String expertId) async {
    final expert = await _repos.experts.getExpert(expertId);
    if (expert == null)
      throw ValidationError('expert.notfound', '专家不存在：$expertId');
    final state = await _repos.experts.getUserState(expertId);
    final cfg = await _repos.experts.getRuntimeConfig(expertId) ??
        ExpertRuntimeConfig(expertId: expertId);

    final modelId = cfg.modelProfileId ??
        await _repos.settings.get(SettingKeys.defaultModelProfileId);
    final credId = cfg.credentialProfileId ??
        await _repos.settings.get(SettingKeys.defaultCredentialProfileId);

    final bindings = await _repos.experts.listKnowledgeBindings(expertId);
    final kbIds =
        bindings.where((b) => b.enabled).map((b) => b.knowledgeBaseId).toList();

    return EffectiveExpertConfig(
      expertId: expertId,
      displayName: EffectiveExpertConfig.resolveName(expert, state),
      prompt: EffectiveExpertConfig.resolvePrompt(expert, state),
      styleId: EffectiveExpertConfig.resolveStyle(state),
      modelProfileId: modelId,
      credentialProfileId: credId,
      groundingPolicy: cfg.groundingPolicy,
      temperature: cfg.temperature,
      topP: cfg.topP,
      maxTokens: cfg.maxTokens,
      knowledgeBaseIds: kbIds,
    );
  }

  /// 绑定知识库（多选）。
  Future<void> bindKnowledge(
    String expertId,
    String knowledgeBaseId, {
    int topK = 5,
    double threshold = kDefaultCoverageThreshold,
  }) =>
      _repos.experts.upsertKnowledgeBinding(ExpertKnowledgeBinding(
        expertId: expertId,
        knowledgeBaseId: knowledgeBaseId,
        topK: topK,
        similarityThreshold: threshold,
      ));

  Future<void> unbindKnowledge(String expertId, String knowledgeBaseId) =>
      _repos.experts.removeKnowledgeBinding(expertId, knowledgeBaseId);

  Future<List<ExpertKnowledgeBinding>> listBindings(String expertId) =>
      _repos.experts.listKnowledgeBindings(expertId);

  Future<void> setTags(String expertId, List<String> tags) =>
      _repos.experts.setTags(expertId, tags);

  Future<List<String>> getTags(String expertId) =>
      _repos.experts.getTags(expertId);

  // -------------------------------------------------------------------------
  // 风格（第 3 轮 §3.4）：专家级，落 expert_user_states.style_id
  // -------------------------------------------------------------------------

  /// 设置专家风格（`ExpertStyle.name`）；[styleId] 为 null / 空 → 关闭风格。
  Future<void> setStyle(String expertId, String? styleId) async {
    final normalized = ExpertStyle.parse(styleId)?.name; // 非法值归一为 null
    final state = await _repos.experts.getUserState(expertId) ??
        ExpertUserState(expertId: expertId);
    await updateUserState(state.copyWith(
      styleId: normalized,
      clearStyle: normalized == null,
    ));
  }

  /// 读取专家风格 id（null = 未设置）。
  Future<String?> getStyle(String expertId) async =>
      (await _repos.experts.getUserState(expertId))?.styleId;

  // -------------------------------------------------------------------------
  // 分组（第 3 轮 §3.1）：expert_groups 主表；成员 group_id 服务层维护（无 DB FK）
  // -------------------------------------------------------------------------

  /// 新建分组。
  Future<ExpertGroup> createGroup(String name, {int sortOrder = 0}) async {
    final group = ExpertGroup.create(name, sortOrder: sortOrder);
    await _repos.groups.upsertGroup(group);
    return group;
  }

  /// 更新分组（改名 / 排序）。
  Future<void> updateGroup(ExpertGroup group) => _repos.groups.upsertGroup(
      group.copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch));

  Future<List<ExpertGroup>> listGroups() => _repos.groups.listGroups();

  /// 删除分组：**先清空成员 `group_id`**（无 DB FK，服务层保证完整性），再删分组。
  Future<void> deleteGroup(String groupId) async {
    for (final e in await _repos.experts.listExperts()) {
      final state = await _repos.experts.getUserState(e.id);
      if (state != null && state.groupId == groupId) {
        await _repos.experts.upsertUserState(state.copyWith(groupId: ''));
      }
    }
    await _repos.groups.deleteGroup(groupId);
  }

  /// 把专家分配到分组（[groupId] 为 null / 空 → 移出分组）。
  Future<void> assignGroup(String expertId, String? groupId) async {
    final state = await _repos.experts.getUserState(expertId) ??
        ExpertUserState(expertId: expertId);
    await updateUserState(state.copyWith(groupId: groupId ?? ''));
  }
}

// ---------------------------------------------------------------------------
// ConversationService
// ---------------------------------------------------------------------------

/// 会话列表项（PRD §6.4 inbox）。
class InboxEntry {
  const InboxEntry({
    required this.conversation,
    required this.title,
    required this.snippet,
    required this.sortAt,
  });

  final Conversation conversation;

  /// 单聊 = 专家备注名（优先）?? 专家名；群聊 = `conversations.title`。
  final String title;

  /// 最后一条消息内容摘要（前 N 字）。
  final String snippet;

  /// 排序时间：`last_message_at ?? created_at`。
  final int sortAt;
}

/// 会话管理：单聊 / 群聊创建、成员、发消息落库。
class ConversationService {
  ConversationService(this._repos, {AttachmentStore? attachmentStore})
      : _attachments = attachmentStore;

  final Repositories _repos;

  /// 附件物理存储（注入 [LocalAttachmentStore]；null → 只清 DB 行，不动物理文件）。
  final AttachmentStore? _attachments;

  /// 创建单聊（若已存在则直接返回）。
  Future<Conversation> createSingle(String expertId) async {
    final all = await _repos.conversations.listConversations();
    for (final c in all) {
      if (c.type != ConversationType.single) continue;
      final members = await _repos.conversations.listMembers(c.id);
      if (members.length == 1 && members.first.expertId == expertId) return c;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final conv = Conversation(
      id: Ids.next('conv'),
      type: ConversationType.single,
      createdAt: now,
      updatedAt: now,
    );
    await _repos.conversations.upsertConversation(conv);
    await _repos.conversations.upsertMember(
      ConversationMember(conversationId: conv.id, expertId: expertId),
    );
    return conv;
  }

  /// 创建群聊。
  Future<Conversation> createGroup({
    required String title,
    required List<String> expertIds,
    String speakStrategy = 'auto',
    String? summarizerExpertId,
    String? leaderExpertId,
    int tokenBudget = 40000,
  }) async {
    if (expertIds.isEmpty) {
      throw const ValidationError('group.empty', '群聊至少需要 1 位专家');
    }
    if (leaderExpertId != null && !expertIds.contains(leaderExpertId)) {
      throw ValidationError(
          'group.leader_missing', '指定组长不在成员中：$leaderExpertId');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final conv = Conversation(
      id: Ids.next('conv'),
      type: ConversationType.group,
      title: title,
      createdAt: now,
      updatedAt: now,
    );
    await _repos.conversations.upsertConversation(conv);
    var order = 0;
    for (final id in expertIds) {
      final role = id == leaderExpertId
          ? MemberRole.leader
          : (id == summarizerExpertId
              ? MemberRole.summarizer
              : MemberRole.member);
      await _repos.conversations.upsertMember(ConversationMember(
        conversationId: conv.id,
        expertId: id,
        role: role,
        sortOrder: order++,
      ));
    }
    await _repos.conversations.upsertGroupConfig(GroupConfig(
      conversationId: conv.id,
      speakStrategy: speakStrategy,
      summarizerExpertId: summarizerExpertId,
      tokenBudget: tokenBudget,
    ));
    return conv;
  }

  Future<List<Conversation>> list() => _repos.conversations.listConversations();

  /// 置顶 / 取消置顶（幂等；会话不存在抛 `conversation.notfound`）。
  ///
  /// 排序由既有口径保证：`ConversationService.listInbox` 与应用层排序均为
  /// **置顶优先 → 时间倒序**；SQLite 仓储侧 `ORDER BY pinned DESC,
  /// last_message_at DESC` 同口径。
  Future<void> setPinned(String conversationId, bool pinned) async {
    await _requireConversation(conversationId);
    await _repos.conversations.setConversationPinned(conversationId, pinned);
  }

  /// 清空聊天记录（**会话本身保留**；消息及其附件 / 引用行由 DB 级联删除）。
  ///
  /// **UI 必须二次确认**（确认文案由 UI 给，服务层不弹窗、不阻止重入），
  /// 清空后 `listInbox` 摘要回落「（暂无消息，点开即可开始）」。
  Future<void> clearMessages(String conversationId) async {
    await _requireConversation(conversationId);
    await _repos.conversations.clearMessages(conversationId);
  }

  /// 删除会话（连带成员 / 群配置 / 消息及其附件引用，靠 DB 外键级联）。
  ///
  /// **UI 必须二次确认且文案写明不可恢复**（服务层不弹窗）。
  /// 已知边界：`generation_runs` 无指向 `conversations` 的 FK，
  /// 生成运行记录不随会话删除而清除（既定事实，见仓储端口注释）。
  Future<void> delete(String conversationId) async {
    await _requireConversation(conversationId);
    await _repos.conversations.deleteConversation(conversationId);
  }

  /// 会话存在性校验（置顶 / 清空 / 删除共用的 fail-closed 前置）。
  Future<Conversation> _requireConversation(String conversationId) async {
    final conv = await _repos.conversations.getConversation(conversationId);
    if (conv == null) {
      throw ValidationError('conversation.notfound', '会话不存在：$conversationId');
    }
    return conv;
  }

  /// 会话列表（置顶优先 → 时间倒序）+ 标题 + 摘要（PRD §6.4）。
  ///
  /// 单聊标题 = 专家备注名（优先）?? 专家名；群聊标题 = `conversations.title`。
  Future<List<InboxEntry>> listInbox({int snippetLength = 40}) async {
    final convs = await _repos.conversations.listConversations();
    final out = <InboxEntry>[];
    for (final c in convs) {
      final title = await _titleFor(c);
      final msgs = await _repos.messages.listMessages(c.id, limit: 1);
      final last = msgs.isNotEmpty ? msgs.last : null;
      out.add(InboxEntry(
        conversation: c,
        title: title,
        snippet: last == null ? '' : _snippet(last.content, snippetLength),
        sortAt: c.lastMessageAt ?? c.createdAt,
      ));
    }
    // 置顶优先，其次按时间倒序（无消息回退 created_at）。
    out.sort((a, b) {
      if (a.conversation.pinned != b.conversation.pinned) {
        return a.conversation.pinned ? -1 : 1;
      }
      return b.sortAt.compareTo(a.sortAt);
    });
    return out;
  }

  Future<String> _titleFor(Conversation c) async {
    if (c.type == ConversationType.group) {
      final t = c.title?.trim() ?? '';
      return t.isEmpty ? '未命名群聊' : t;
    }
    final members = await _repos.conversations.listMembers(c.id);
    if (members.isEmpty) return '空会话';
    final expertId = members.first.expertId;
    final expert = await _repos.experts.getExpert(expertId);
    if (expert == null) return expertId;
    final state = await _repos.experts.getUserState(expertId);
    return EffectiveExpertConfig.resolveName(expert, state);
  }

  static String _snippet(String content, int maxChars) {
    final flat = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= maxChars) return flat;
    return '${flat.substring(0, maxChars)}…';
  }

  Future<List<ConversationMember>> members(String conversationId) =>
      _repos.conversations.listMembers(conversationId);

  Future<void> addMember(String conversationId, String expertId,
          {double weight = 1.0}) =>
      _repos.conversations.upsertMember(ConversationMember(
        conversationId: conversationId,
        expertId: expertId,
        weight: weight,
      ));

  Future<void> removeMember(String conversationId, String expertId) =>
      _repos.conversations.removeMember(conversationId, expertId);

  Future<GroupConfig?> groupConfig(String conversationId) =>
      _repos.conversations.getGroupConfig(conversationId);

  Future<void> updateGroupConfig(GroupConfig config) =>
      _repos.conversations.upsertGroupConfig(config);

  Future<List<Message>> history(String conversationId, {int limit = 200}) =>
      _repos.messages.listMessages(conversationId, limit: limit);

  /// 落一条用户消息并更新会话时间。
  Future<Message> appendUserMessage(
      String conversationId, String content) async {
    final msg = Message.user(conversationId, content);
    await _repos.messages.insertMessage(msg);
    await _touch(conversationId, msg.createdAt);
    return msg;
  }

  Future<void> _touch(String conversationId, int at) async {
    final conv = await _repos.conversations.getConversation(conversationId);
    if (conv != null) {
      await _repos.conversations.upsertConversation(
        conv.copyWith(lastMessageAt: at, updatedAt: at),
      );
    }
  }

  /// 落一条专家消息（供生成服务调用）。
  Future<Message> appendExpertMessage(
    String conversationId,
    String expertId,
    String content, {
    MessageStatus status = MessageStatus.completed,
    String? parentMessageId,
  }) async {
    final msg = Message.expert(
      conversationId,
      expertId,
      content: content,
      status: status,
      parentMessageId: parentMessageId,
    );
    await _repos.messages.insertMessage(msg);
    await _touch(conversationId, msg.createdAt);
    return msg;
  }

  /// **批量预载**消息及其附件（防 N+1；UI 消息流一次取全）。
  ///
  /// 返回 `{消息: [附件]}` 映射；无附件的消息映射到空列表。
  Future<Map<Message, List<Attachment>>> listMessagesWithAttachments(
    String conversationId, {
    int? limit,
  }) async {
    final msgs =
        await _repos.messages.listMessages(conversationId, limit: limit);
    final ids = msgs.map((m) => m.id).toList();
    final rows = await _repos.attachments.listAttachmentsByMessages(ids);
    final grouped = <String, List<Attachment>>{};
    for (final a in rows) {
      grouped.putIfAbsent(a.messageId, () => []).add(a);
    }
    return {for (final m in msgs) m: grouped[m.id] ?? const <Attachment>[]};
  }

  /// 删除消息（第 8 轮；**铁律：只允许删用户自己发的消息**）。
  ///
  /// 三级校验（UI 隐藏入口只是第一道，服务层 fail-closed 二次拒绝）：
  /// 1. 消息存在；
  /// 2. 消息属于 [conversationId]（防跨会话删）；
  /// 3. **`senderType == user`** —— 专家消息一律不可删（删了会让
  ///    `generation_steps.output_message_id` 悬空，且牵连 QA 快照/引用语义）。
  ///
  /// **双清（不依赖单一 FK）**：
  /// ① `messages.deleteMessage`（DDL 级联清 `message_attachments` / `message_citations`）；
  /// ② `attachments.deleteByMessage`（显式删附件行，防某连接 FK 为 OFF）；
  /// ③ 按 **DB 引用计数**清理物理文件（`countByStoredPath`；**绝不扫盘**）。
  ///
  /// > 实现顺序说明：先删行再计数（不带 `excludeId`）。若按"删前计数 + `id != ?`"的
  /// > 写法，**同一条消息里重复上传同一内容**时会各自判"还有 1 条引用"→ 两条都不删
  /// > 物理文件 → 泄漏孤儿。先删行再计数则同内容多行一并消失，计数归零，只删一次。
  Future<DeletedMessageResult> deleteMessage(
    String conversationId,
    String messageId,
  ) async {
    final msg = await _repos.messages.getMessage(messageId);
    if (msg == null) {
      throw const ValidationError('message.notfound', '消息不存在或已被删除');
    }
    if (msg.conversationId != conversationId) {
      throw const ValidationError('message.notfound', '消息不属于该会话');
    }
    if (msg.senderType != MessageSenderType.user) {
      throw const ValidationError(
        'message.not_deletable',
        '只有你自己发送的消息可以删除（专家消息不可删）',
      );
    }

    // ① 记录待清理的存储路径（先读，因为删行后就查不到了）。
    final rows = await _repos.attachments.listAttachmentsByMessage(messageId);
    final storedPaths = rows.map((a) => a.storedPath).toSet();

    // ② 数据层删除（DDL 级联）+ ③ 显式删附件行（双保险）。
    await _repos.messages.deleteMessage(messageId);
    await _repos.attachments.deleteByMessage(messageId);

    // ④ 按 DB 引用计数清理物理文件（注入了 store 才做；未注入则只清 DB 行）。
    //    走 [AttachmentStore.referenceCount]（端口规定的唯一定价入口，DB 计数、非 IO）。
    final purged = <String>[];
    if (_attachments != null) {
      for (final path in storedPaths) {
        final remaining =
            await _attachments.referenceCount(path, excludeId: messageId);
        if (remaining == 0) {
          await _attachments.deleteIfUnreferenced(path);
          purged.add(path);
        }
      }
    }

    return DeletedMessageResult(
      messageId: messageId,
      conversationId: conversationId,
      removedAttachments: rows.length,
      purgedFiles: purged,
    );
  }
}

/// 删除消息的结果（供 UI 摘要提示）。
class DeletedMessageResult {
  const DeletedMessageResult({
    required this.messageId,
    required this.conversationId,
    required this.removedAttachments,
    required this.purgedFiles,
  });

  final String messageId;
  final String conversationId;

  /// 随消息一并删除的附件行数。
  final int removedAttachments;

  /// 已删除的物理文件路径（引用计数归零者）。
  final List<String> purgedFiles;
}

// ---------------------------------------------------------------------------
// KnowledgeService
// ---------------------------------------------------------------------------

/// 知识库管理：建库 / 导入 / 解析 / 分块 / 向量化 / 检索 / 引用。
///
/// 检索后端二选一（第 2 轮设计 §1 / §2）：
/// - 传入 [retriever]（如 `Fts5Retriever`）→ 走**关键词 / FTS5** 路径，且**不做 embedding 双写**；
/// - [retriever] 为 `null` → 走**旧向量路径**（[embeddingModel] + [vectorStore]）作为降级。
class KnowledgeService {
  KnowledgeService(
    this._repos, {
    required this.parsers,
    required this.chunker,
    required this.vectorStore,
    this.embeddingModel,
    this.retriever,
  });

  final Repositories _repos;
  final List<DocumentParser> parsers;
  final Chunker chunker;
  final VectorStore vectorStore;
  EmbeddingModel? embeddingModel;

  /// 关键词检索后端（FTS5）。为 `null` 时回退到 [vectorStore] 老路径。
  final Retriever? retriever;

  Future<KnowledgeBase> createBase({
    required String name,
    String? description,
    String? embeddingModelId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final base = KnowledgeBase(
      id: Ids.next('kb'),
      name: name.trim().isEmpty ? '未命名知识库' : name.trim(),
      description: description,
      embeddingModelId: embeddingModelId ?? embeddingModel?.modelId,
      createdAt: now,
      updatedAt: now,
    );
    await _repos.knowledge.upsertBase(base);
    return base;
  }

  Future<List<KnowledgeBase>> listBases() => _repos.knowledge.listBases();

  Future<KnowledgeBase?> getBase(String id) => _repos.knowledge.getBase(id);

  /// 重命名知识库（用户走查反馈 #15-A）。
  ///
  /// 只改写 `name` 并刷新 `updatedAt`（additive，不动 schema）：
  /// - 知识库不存在 → `kb.not_found`；
  /// - `newName` trim 后为空 → `kb.name_empty`；
  /// - 成功经 `upsertBase` 持久化并返回改名后的档案。
  Future<KnowledgeBase> renameBase(String id, String newName) async {
    final base = await getBase(id);
    if (base == null) {
      throw const KnowledgeError('kb.not_found', '知识库不存在');
    }
    final name = newName.trim();
    if (name.isEmpty) {
      throw const KnowledgeError('kb.name_empty', '名称不能为空');
    }
    final renamed = base.copyWith(
      name: name,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _repos.knowledge.upsertBase(renamed);
    return renamed;
  }

  /// 列出某知识库下的全部文档（按创建时间）。
  Future<List<KnowledgeDocument>> listDocuments(String knowledgeBaseId) =>
      _repos.knowledge.listDocuments(knowledgeBaseId);

  /// 列出某文档的全部分块（按 sequence）。
  Future<List<KnowledgeChunk>> listChunks(String documentId) =>
      _repos.knowledge.listChunks(documentId);

  DocumentParser? parserFor(String fileName) {
    final lower = fileName.toLowerCase();
    for (final p in parsers) {
      for (final ext in p.supportedExtensions) {
        if (lower.endsWith(ext)) return p;
      }
    }
    return null;
  }

  /// 导入一个本地文件：解析 → 分块 → 向量化 → 入库 → 建索引。
  ///
  /// [folderId] / [sourceMtime]（第 4 轮 additive）：由文件夹重扫链路传入，
  /// 使新文档**落库即携带来源关联**与增量快速路径依据；手动导入路径不传（保持
  /// `folder_id IS NULL` 孤儿语义）。去重命中返回既有文档时不改写其 folder_id
  /// （先到先得，防夺走其他关联的归属）。
  Future<({KnowledgeDocument doc, int chunkCount})> importDocument({
    required String knowledgeBaseId,
    required String filePath,
    required String fileName,
    required List<int> fileBytes,
    String? mimeType,
    String? folderId,
    int? sourceMtime,
  }) async {
    final parser = parserFor(fileName);
    if (parser == null) {
      throw KnowledgeError('kb.unsupported', '不支持的格式：$fileName');
    }
    final hash = sha256.convert(fileBytes).toString();

    final dup =
        await _repos.knowledge.findDocumentByHash(knowledgeBaseId, hash);
    if (dup != null) {
      final chunks = await _repos.knowledge.listChunks(dup.id);
      return (doc: dup, chunkCount: chunks.length);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    var doc = KnowledgeDocument(
      id: Ids.next('doc'),
      knowledgeBaseId: knowledgeBaseId,
      fileName: fileName,
      filePath: filePath,
      fileHash: hash,
      fileSize: fileBytes.length,
      mimeType: mimeType,
      parser: parser.name,
      parserVersion: parser.version,
      status: DocumentStatus.parsing,
      folderId: folderId,
      sourceMtime: sourceMtime,
      createdAt: now,
      updatedAt: now,
    );
    await _repos.knowledge.upsertDocument(doc);

    try {
      final parsed = await parser.parse(filePath);
      doc = doc.copyWith(
        status: DocumentStatus.indexed,
        pageCount: parsed.pageCount,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _repos.knowledge.upsertDocument(doc);

      final chunks = chunker.chunk(doc.id, parsed);
      await _repos.knowledge.insertChunks(chunks);

      final rt = retriever;
      if (rt != null && await _retrieverUsable()) {
        // 关键词后端独占：索引 bigram，**不做 embedding 双写**（第 2 轮裁定 #2）。
        await rt.indexChunks(chunks,
            knowledgeBaseId: knowledgeBaseId, documentId: doc.id);
      } else {
        final model = embeddingModel;
        if (model != null && chunks.isNotEmpty) {
          // 显式补齐 embedding 模型档案，避免 chunk_embeddings 外键（→ embedding_models）
          // 失败（仓储层另有占位行兜底，此处保证档案信息正确落地）。
          await _repos.knowledge.upsertEmbeddingModel(EmbeddingModelProfile(
            id: model.modelId,
            name: model.modelId,
            dimension: model.dimension,
            runtime: 'local',
          ));
          final vectors = await model.embed(chunks.map((c) => c.text).toList());
          await vectorStore.upsert(chunks, vectors, model.modelId);
          for (var i = 0; i < chunks.length; i++) {
            await _repos.knowledge.upsertEmbedding(ChunkEmbedding(
              chunkId: chunks[i].id,
              embeddingModelId: model.modelId,
              dimension: model.dimension,
              vectorRef: 'vec:${chunks[i].id}',
              createdAt: DateTime.now().millisecondsSinceEpoch,
            ));
          }
        }
      }

      final base = await _repos.knowledge.getBase(knowledgeBaseId);
      if (base != null) {
        final docs = await _repos.knowledge.listDocuments(knowledgeBaseId);
        await _repos.knowledge.upsertBase(base.copyWith(
          fileCount: docs.length,
          chunkCount: base.chunkCount + chunks.length,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      return (doc: doc, chunkCount: chunks.length);
    } catch (e) {
      await _repos.knowledge.upsertDocument(doc.copyWith(
        status: DocumentStatus.failed,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      if (e is AppError) rethrow;
      throw KnowledgeError('kb.parse', '解析失败：$e', e);
    }
  }

  /// 检索：返回达到阈值的引用列表。
  ///
  /// [threshold] 语义为"查询 bigram 的最低命中比例（coverage）"，默认
  /// [kDefaultCoverageThreshold]（第 2 轮由 0.75 下调为 0.5，见设计 §3.4）。
  ///
  /// 分派：优先 [retriever]（FTS5）；不可用或未注入时降级到 [vectorStore] 老路径。
  Future<List<Citation>> retrieve({
    required String query,
    required List<String> knowledgeBaseIds,
    int topK = 5,
    double threshold = kDefaultCoverageThreshold,
  }) async {
    if (knowledgeBaseIds.isEmpty) return const [];

    final rt = retriever;
    if (rt != null) {
      try {
        if (await rt.health()) {
          final hits = await rt.search(
            query,
            knowledgeBaseIds: knowledgeBaseIds,
            topK: topK,
            threshold: threshold,
          );
          return hits.map((h) => h.citation).toList();
        }
      } catch (_) {
        // 关键词后端异常：若有向量降级路径则继续，否则向上抛（不静默吞错）。
        if (embeddingModel == null) rethrow;
      }
    }

    final model = embeddingModel;
    if (model == null) {
      throw const KnowledgeError('kb.no_embedding', '未配置本地 embedding 模型');
    }
    final vectors = await model.embed([query]);
    final hits = await vectorStore.search(
      vectors.first,
      knowledgeBaseIds: knowledgeBaseIds,
      topK: topK,
      threshold: threshold,
    );
    return hits.map((h) => h.citation).toList();
  }

  /// 为某个专家检索其绑定知识库。
  Future<List<Citation>> retrieveForExpert({
    required String expertId,
    required String query,
  }) async {
    final bindings = await _repos.experts.listKnowledgeBindings(expertId);
    final enabled = bindings.where((b) => b.enabled).toList();
    if (enabled.isEmpty) return const [];

    final kbIds = enabled.map((b) => b.knowledgeBaseId).toList();
    final topK = enabled.map((b) => b.topK).reduce((a, b) => a > b ? a : b);
    final threshold = enabled
        .map((b) => b.similarityThreshold)
        .reduce((a, b) => a < b ? a : b);
    return retrieve(
      query: query,
      knowledgeBaseIds: kbIds,
      topK: topK,
      threshold: threshold,
    );
  }

  Future<void> rebuildIndex(String knowledgeBaseId) {
    final rt = retriever;
    return rt != null
        ? rt.rebuild(knowledgeBaseId)
        : vectorStore.rebuild(knowledgeBaseId);
  }

  /// 关键词后端是否可用（FTS5 就绪）。用于 UI 降级提示（[retrievalBackendLabel]）。
  Future<bool> isKeywordRetrievalHealthy() async {
    final rt = retriever;
    if (rt == null) return false;
    try {
      return await rt.health();
    } catch (_) {
      return false;
    }
  }

  /// 内部：关键词后端是否可用于本次调用（未注入或探测失败均返回 false → 走降级路径）。
  Future<bool> _retrieverUsable() async {
    final rt = retriever;
    if (rt == null) return false;
    try {
      return await rt.health();
    } catch (_) {
      return false;
    }
  }

  /// 当前检索后端标签（供 UI 明确显示是否降级，**严禁静默降级**）。
  Future<String> retrievalBackendLabel() async {
    final rt = retriever;
    if (rt == null) return '向量检索（未启用关键词检索）';
    return await isKeywordRetrievalHealthy()
        ? 'FTS5 中文检索'
        : '降级：向量检索（FTS5 不可用）';
  }

  /// 删除单个文档：删分块 + 删文档 + 同步向量库，并刷新所属知识库统计。
  ///
  /// 注：`message_citations` 对 document/chunk 无外键，历史回答的引用会保留
  /// （历史不可变，见设计 §5 待明确 #4）。
  Future<void> deleteDocument(String documentId) async {
    KnowledgeDocument? doc;
    for (final base in await _repos.knowledge.listBases()) {
      for (final d in await _repos.knowledge.listDocuments(base.id)) {
        if (d.id == documentId) {
          doc = d;
          break;
        }
      }
      if (doc != null) break;
    }

    await _repos.knowledge.deleteChunksByDocument(documentId);
    await _repos.knowledge.deleteDocument(documentId);
    await vectorStore.deleteByDocument(documentId);
    await retriever?.deleteByDocument(documentId);

    if (doc != null) {
      final base = await _repos.knowledge.getBase(doc.knowledgeBaseId);
      if (base != null) {
        final docs = await _repos.knowledge.listDocuments(base.id);
        var chunkTotal = 0;
        for (final d in docs) {
          chunkTotal += (await _repos.knowledge.listChunks(d.id)).length;
        }
        await _repos.knowledge.upsertBase(base.copyWith(
          fileCount: docs.length,
          chunkCount: chunkTotal,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    }
  }

  /// 删除知识库及其全部关联（契约 02 §3.3）。
  Future<void> deleteBase(String knowledgeBaseId) async {
    final docs = await _repos.knowledge.listDocuments(knowledgeBaseId);
    for (final d in docs) {
      await _repos.knowledge.deleteChunksByDocument(d.id);
      await _repos.knowledge.deleteDocument(d.id);
    }
    await vectorStore.deleteByKnowledgeBase(knowledgeBaseId);
    await retriever?.deleteByKnowledgeBase(knowledgeBaseId);
    await _repos.knowledge.deleteBase(knowledgeBaseId);
  }
}

// ---------------------------------------------------------------------------
// 附件告知 + 内容注入（第 8 轮 T51 → 第 9 轮：文档抽文本 + 图片多模态）
// ---------------------------------------------------------------------------

/// 附件 prompt 上下文：注入后的 userTask + 待走多模态的图片 data URL。
class AttachmentPromptContext {
  const AttachmentPromptContext({
    required this.userTask,
    required this.imageUrls,
  });

  /// 注入附件信息后的用户任务文本（无附件时与原文**逐字相同**）。
  final String userTask;

  /// 待随 user 消息发送的图片 data URL（`data:<mime>;base64,...`）。
  final List<String> imageUrls;
}

/// 按 [userMessageId] 取附件，把「可读内容」转换成送给模型的输入（第 9 轮）。
///
/// - **文档类**（[AttachmentKind.file] 且扩展名命中解析器）→ 抽文本注入
///   userTask：单文档 ≤ [kMaxDocCharsPerAttachment]、单轮合计 ≤
///   [kMaxDocCharsPerRound] 字，超限在注入文本标注「（已截断，原长 N 字）」；
/// - **图片类**（[AttachmentKind.image]）→ 读文件转 data URL 进
///   [AttachmentPromptContext.imageUrls]（> [kMaxImageBytesForVision] 拒绝并注明）；
/// - **解析失败 / 解析器缺失 / 读取失败** → 告知段内写明原因，**不静默**；
/// - **无附件 → userTask 与 [userText] 逐字相同**（防回归关键断言）；
/// - 附件查询异常 → 按无附件处理，**绝不中断本次运行**（失败隔离，T51 同口径）；
/// - 检索 query **不得**使用本函数产物（附件名/正文不混入检索式，由调用方保证）。
Future<AttachmentPromptContext> _buildAttachmentPromptContext(
  Repositories repos,
  String userMessageId,
  String userText,
  List<DocumentParser> parsers,
) async {
  final List<Attachment> rows;
  try {
    rows = await repos.attachments.listAttachmentsByMessage(userMessageId);
  } catch (_) {
    // 失败隔离：查询异常一律按"无附件"处理，不中断本次生成。
    return AttachmentPromptContext(userTask: userText, imageUrls: const []);
  }
  if (rows.isEmpty) {
    return AttachmentPromptContext(userTask: userText, imageUrls: const []);
  }

  final imageUrls = <String>[];
  final lines = <String>[];
  final sections = <String>[];
  var docBudget = kMaxDocCharsPerRound;

  for (final a in rows) {
    // 附件行格式与 T51 逐字一致（'- 名称（类型，体积）'），状态注解**追加在后**，
    // 既有断言（verify_round8 §11 ②③）继续成立。
    final head =
        '- ${a.fileName}（${a.kind.label}，${AttachmentPolicy.formatBytes(a.sizeBytes)}）';
    if (a.kind == AttachmentKind.image) {
      final img = await readImageDataUrl(a);
      if (img.ok) {
        imageUrls.add(img.dataUrl!);
        lines.add('$head（图片内容已发送给模型识别）');
      } else {
        lines.add('$head（${img.failureReason}）');
      }
      continue;
    }
    final doc = await readDocumentText(
      attachment: a,
      parsers: parsers,
      remainingBudget: docBudget,
    );
    if (doc.ok) {
      docBudget -= doc.text!.length;
      final note = doc.truncated ? '；${doc.truncationNote}' : '';
      sections.add('——《${a.fileName}》正文'
          '（解析器 ${doc.parserName}；原长 ${doc.originalLength} 字$note）——\n'
          '${doc.text}');
      lines.add('$head（正文已读取，见下方「附件正文」）');
    } else {
      lines.add('$head（${doc.failureReason}）');
    }
  }

  final buf = StringBuffer()
    ..write(userText)
    ..write('\n\n【用户附件】本条消息附带 ${rows.length} 个文件：\n')
    ..write(lines.join('\n'));
  if (sections.isEmpty) {
    // 一份正文都没拿到 → 回落 T51 引导句（请用户粘贴文字）。
    buf.write('\n请以文字告知用户你已收到附件，并请其把关键内容粘贴为文字后继续。');
  } else {
    buf.write('\n\n【附件正文】以下为从附件中读取到的文字内容'
        '（可能因长度上限截断，均已标注）：\n\n');
    buf.write(sections.join('\n\n'));
    buf.write('\n\n以上即附件正文，请直接基于其内容回答，无需再请用户粘贴。');
  }
  return AttachmentPromptContext(userTask: buf.toString(), imageUrls: imageUrls);
}

// ---------------------------------------------------------------------------
// 生成服务（单聊）
// ---------------------------------------------------------------------------

/// 单聊生成编排（M1 Vertical Slice）。
class GenerationService {
  GenerationService(
    this._repos, {
    required this.experts,
    required this.conversations,
    required this.knowledge,
    required this.llmFactory,
    List<DocumentParser> documentParsers = defaultAttachmentDocumentParsers,
  }) : _documentParsers = documentParsers;

  final Repositories _repos;
  final ExpertService experts;
  final ConversationService conversations;
  final KnowledgeService knowledge;

  /// 附件内容提取用解析器（第 9 轮：与知识库导入链同一批实现；
  /// 默认 [defaultAttachmentDocumentParsers]，装配处可覆盖）。
  final List<DocumentParser> _documentParsers;

  /// 按 providerProfileId 取得 LlmProvider 实例。
  final LlmProvider Function(String providerProfileId) llmFactory;

  final Set<String> _cancelRequested = {};

  /// 单聊：跑一次完整链路（Run → 检索 → Grounding → 流式 → 落库）。
  Stream<GenerationUpdate> runSingleChat({
    required String conversationId,
    required String userMessageId,
    required String userText,
  }) async* {
    final members = await _repos.conversations.listMembers(conversationId);
    if (members.isEmpty) throw const ValidationError('gen.no_member', '会话没有成员');
    final expertId = members.first.expertId;

    // 附件内容注入（第 8 轮 T51 → 第 9 轮）：文档抽文本进 userTask、
    // 图片转 data URL 进 imageUrls。查询失败按无附件处理，绝不中断本次运行；
    // 检索 query 仍用原始 userText（附件名/正文不混入检索式）。
    final attCtx = await _buildAttachmentPromptContext(
        _repos, userMessageId, userText, _documentParsers);
    final userTask = attCtx.userTask;
    final userImageUrls = attCtx.imageUrls;

    final eff = await experts.resolveEffective(expertId);
    final resolved = await _resolveRuntime(eff);

    var run = GenerationRun.create(
      conversationId: conversationId,
      runType: RunType.singleChat,
      triggerMessageId: userMessageId,
      modelProfileId: resolved.modelProfileId,
    ).copyWith(
        status: RunStatus.running,
        startedAt: DateTime.now().millisecondsSinceEpoch);
    await _repos.generations.upsertRun(run);
    yield RunStartedUpdate(run);

    var step = GenerationStep.create(
      runId: run.id,
      stage: StepStage.generation,
      sequence: 0,
      expertId: expertId,
    ).copyWith(
        status: RunStatus.running,
        startedAt: DateTime.now().millisecondsSinceEpoch);
    await _repos.generations.upsertStep(step);

    yield StepStatusUpdate(expertId: expertId, activity: Activity.thinking);

    // 失败路径（task #42 / 契约 §2.4）：占位消息与已累积正文需在 catch 中可见——
    // run/step 置 failed 的同时必须把占位消息一并置 MessageStatus.failed
    // （正文保留已累积内容，为空则空串），**不得停留在 streaming**。
    Message? failedPlaceholder;
    final buffer = StringBuffer();

    try {
      // 知识检索 + Grounding 决策
      var evidence = <Citation>[];
      if (eff.groundingPolicy.needsRetrieval) {
        evidence = await knowledge.retrieveForExpert(
            expertId: expertId, query: userText);
        step = step.copyWith(retrievalCount: evidence.length);
        await _repos.generations.upsertStep(step);
      }
      final decision = GroundingResolver.resolve(
          policy: eff.groundingPolicy, evidence: evidence);

      if (decision is GroundedNoAnswer) {
        final msg = await conversations.appendExpertMessage(
          conversationId,
          expertId,
          kNoAnswerText,
          parentMessageId: userMessageId,
        );
        step = step.copyWith(
          status: RunStatus.completed,
          endedAt: DateTime.now().millisecondsSinceEpoch,
          outputMessageId: msg.id,
        );
        await _repos.generations.upsertStep(step);
        run = run.copyWith(
            status: RunStatus.completed,
            endedAt: DateTime.now().millisecondsSinceEpoch);
        await _repos.generations.upsertRun(run);
        yield StepFinishedUpdate(
          expertId: expertId,
          messageId: msg.id,
          content: kNoAnswerText,
          skipped: true,
          skipReason: decision.reason,
        );
        yield RunFinishedUpdate(run);
        return;
      }

      final citations = (decision as GroundedProceed).citations;
      final history =
          await _repos.messages.listMessages(conversationId, limit: 40);
      final messages = ContextManager.build(
        systemPrompt: eff.prompt,
        styleDirective: StyleLibrary.directiveFor(eff.styleId),
        userTask: userTask,
        recentMessages: history,
        evidence: citations,
        strictGrounding: eff.groundingPolicy == GroundingPolicy.strict,
        // 预算按模型上下文推导（用户反馈 #61）：写死的 8000/1200 在长文档
        // 注入时会把历史预算吃光——模型看得见附件、看不见任何聊天记录。
        budget: resolved.budget,
        // 第 9 轮：本轮图片随 user 消息走多模态（无图 → 空列表，行为零变化）。
        userImageUrls: userImageUrls,
        // 历史发言者标签用**展示名**，不用裸 expertId（第 8 轮根因修复；
        // QA `qa_verify_group_identity` F2.2/F2.3 抓到单聊此前漏传 nameOf）。
        // 单聊历史只会出现本专家本人 → 任何 senderId 都返回本专家的展示名。
        nameOf: (_) => eff.displayName,
      );

      // 视觉门控（第 9 轮）：模型未开 supports_vision 而消息带图 →
      // 明确抛 `provider.vision_unsupported`，**绝不静默丢图**。错误经既有
      // 失败路径落 run/step failed + RunFailedUpdate，用户在界面上看得到原因
      // （换用支持视觉的模型 / 去「设置 → 模型」开启「支持视觉」）。
      assertVisionSupported(
        supportsVision: resolved.supportsVision,
        modelId: resolved.modelId,
        messages: messages,
      );

      final outMsg = Message.expert(
        conversationId,
        expertId,
        parentMessageId: userMessageId,
      );
      failedPlaceholder = outMsg;
      await _repos.messages.insertMessage(outMsg);

      yield StepStatusUpdate(expertId: expertId, activity: Activity.generating);

      var seq = 0;
      var promptTokens = 0;
      var completionTokens = 0;
      var cancelled = false;

      final request = ChatRequest(
        model: resolved.modelId,
        messages: messages,
        temperature: eff.temperature,
        topP: eff.topP,
        maxTokens: eff.maxTokens,
        stream: true,
      );

      await for (final event in resolved.llm.stream(request)) {
        if (_cancelRequested.contains(run.id)) {
          cancelled = true;
          break;
        }
        switch (event) {
          case TokenDelta(:final text):
            buffer.write(text);
            seq++;
            await _repos.generations.appendEvent(GenerationEvent.create(
              stepId: step.id,
              sequence: seq,
              eventType: GenerationEventType.tokenDelta,
              delta: text,
            ));
            yield DeltaUpdate(
                expertId: expertId, messageId: outMsg.id, text: text);
          case ReasoningDelta(:final text):
            // A①：思考通道**绝不进正文**，仅落 events（用户不可见）。
            seq++;
            await _repos.generations.appendEvent(GenerationEvent.create(
              stepId: step.id,
              sequence: seq,
              eventType: GenerationEventType.reasoningDelta,
              delta: text,
            ));
          case UsageEvent(promptTokens: final pt, completionTokens: final ct):
            promptTokens = pt;
            completionTokens = ct;
          case StreamErrorEvent(:final error):
            throw error;
          case StreamDone():
            break;
        }
      }

      // A② 接线（第 3 轮设计 → 第 6 轮回填）：模型可见正文中的「过程性元叙述」
      // （段首「让我想想。」「我来分析一下。」等 + 显式思考围栏）在此**保守剥离**后
      // 才落库 / 交付展示——PresentedContent.text 是唯一可展示 / 入库内容。
      // 保守优先：宁可漏剥一句过渡语，也绝不误删真实正文（剥空时回退原文）。
      final finalContent = ReasoningStripper.strip(buffer.toString()).text;
      final status =
          cancelled ? MessageStatus.cancelled : MessageStatus.completed;

      final finalMsg = outMsg.copyWith(
        content: finalContent,
        status: status,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _repos.messages.updateMessage(finalMsg);
      for (final c in citations) {
        await _repos.messages.insertCitation(finalMsg.id, c);
      }

      step = step.copyWith(
        status: cancelled ? RunStatus.cancelled : RunStatus.completed,
        endedAt: DateTime.now().millisecondsSinceEpoch,
        outputMessageId: finalMsg.id,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        latencyMs:
            DateTime.now().millisecondsSinceEpoch - (step.startedAt ?? 0),
      );
      await _repos.generations.upsertStep(step);

      run = run.copyWith(
        status: cancelled ? RunStatus.cancelled : RunStatus.completed,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        endedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _repos.generations.upsertRun(run);

      yield StepFinishedUpdate(
        expertId: expertId,
        messageId: finalMsg.id,
        content: finalContent,
        citations: citations,
      );
      yield RunFinishedUpdate(run);
    } catch (e) {
      final err = e is AppError ? e : resolved.llm.mapError(e);
      // 占位消息不得停留在 streaming（契约 §2.4）：与 run/step failed 同步置 failed，
      // 正文保留已累积内容（为空则空串）。
      final ph = failedPlaceholder;
      if (ph != null) {
        await _repos.messages.updateMessage(ph.copyWith(
          content: buffer.toString(),
          status: MessageStatus.failed,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      step = step.copyWith(
        status: RunStatus.failed,
        endedAt: DateTime.now().millisecondsSinceEpoch,
        errorCode: err.code,
        errorMessage: err.message,
      );
      await _repos.generations.upsertStep(step);
      run = run.copyWith(
        status: RunStatus.failed,
        endedAt: DateTime.now().millisecondsSinceEpoch,
        errorCode: err.code,
        errorMessage: err.message,
      );
      await _repos.generations.upsertRun(run);
      yield RunFailedUpdate(run, err);
    } finally {
      _cancelRequested.remove(run.id);
    }
  }

  /// 解析运行所需的 model / provider / key，任一缺失都抛出明确错误。
  Future<_ResolvedRuntime> _resolveRuntime(EffectiveExpertConfig eff) async {
    final modelProfileId = eff.modelProfileId;
    final credId = eff.credentialProfileId;
    if (modelProfileId == null) {
      throw const ValidationError('gen.no_model', '未配置默认模型，请先在设置中配置');
    }
    if (credId == null) {
      throw const ValidationError('gen.no_credential', '未配置 API Key，请先在设置中配置');
    }
    final model = await _repos.providers.getModel(modelProfileId);
    if (model == null) {
      throw ValidationError('gen.model_missing', '模型档案不存在：$modelProfileId');
    }
    final provider =
        await _repos.providers.getProvider(model.providerProfileId);
    if (provider == null) {
      throw ValidationError(
          'gen.provider_missing', 'Provider 不存在：${model.providerProfileId}');
    }
    final cred = await _repos.credentials.get(credId);
    final apiKey =
        cred == null ? null : await _repos.secrets.read(cred.secretRef);
    if (apiKey == null || apiKey.isEmpty) {
      throw const AuthenticationError('未找到 API Key，请先在设置中配置');
    }
    return _ResolvedRuntime(
      modelProfileId: modelProfileId,
      modelId: model.modelId,
      supportsVision: model.supportsVision,
      llm: llmFactory(provider.id),
      contextWindow: model.contextWindow,
    );
  }
  /// 取消运行中的生成。
  Future<void> cancel(String runId) async {
    _cancelRequested.add(runId);
    final run = await _repos.generations.getRun(runId);
    if (run != null && run.status == RunStatus.running) {
      await _repos.generations.upsertRun(
        run.copyWith(
            status: RunStatus.cancelled,
            endedAt: DateTime.now().millisecondsSinceEpoch),
      );
    }
  }

  /// 启动恢复：把中断的 run/step 标记为 cancelled（M1 验收项）。
  Future<int> recoverOnStartup() => _repos.generations.recoverInterrupted();
}

/// 解析后的运行上下文。
class _ResolvedRuntime {
  const _ResolvedRuntime({
    required this.modelProfileId,
    required this.modelId,
    required this.supportsVision,
    required this.llm,
    this.contextWindow,
  });

  final String modelProfileId;
  final String modelId;

  /// 模型档案的「支持视觉」开关（第 9 轮图片多模态门控依据）。
  final bool supportsVision;

  final LlmProvider llm;

  /// 模型档案配置的上下文窗口（tokens；未配置为 null）。
  ///
  /// 预算由它推导（[TokenBudget.forContext]）——**不再使用写死的 64K 时代常量**，
  /// 否则长文档一注入就把历史预算吃光、群聊也会被过早掐断（用户反馈 #61）。
  final int? contextWindow;

  /// 本次运行使用的预算（上下文推导值；模型未配置时退回旧默认）。
  TokenBudget get budget => TokenBudget.forContext(contextWindow);
}

// ---------------------------------------------------------------------------
// 群聊服务
// ---------------------------------------------------------------------------

/// 群聊编排服务（V1.3 §9 / §25）。
/// 取较大者（`a` 为 null 视为不设限）。
int? _maxOf(int? a, int? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a > b ? a : b;
}

/// 由**默认模型档案的上下文**推导群总预算（与 `TokenBudget.forContext` 同口径：
/// 上下文 × 3/4）；未配置上下文时返回 null（退回群配置或 40000 旧默认）。
///
/// 用户反馈 #61：原群总预算写死 40000（64K 时代的尺子），长文档群聊会在第 1 位
/// 专家发言后被 `run.isOverBudget` 掐断；改为按模型真实上下文推导后，护栏仍在
/// （不会无限运行），只是不再按过小的尺子裁。
Future<int?> _derivedGroupBudget(ProviderService? providers) async {
  if (providers == null) return null;
  final modelId = await providers.defaultModelProfileId;
  if (modelId == null || modelId.isEmpty) return null;
  final models = await providers.listModels();
  for (final m in models) {
    if (m.id == modelId && m.contextWindow != null && m.contextWindow! > 0) {
      return m.contextWindow! * 3 ~/ 4;
    }
  }
  return null;
}

class GroupService {
  GroupService(
    this._repos, {
    required this.experts,
    required this.conversations,
    required this.knowledge,
    required this.llmFactory,
    List<DocumentParser> documentParsers = defaultAttachmentDocumentParsers,
    ProviderService? providers,
  })  : _documentParsers = documentParsers,
        _providers = providers;

  final Repositories _repos;
  final ExpertService experts;
  final ConversationService conversations;
  final KnowledgeService knowledge;
  final LlmProvider Function(String providerProfileId) llmFactory;

  /// 模型档案服务（可选）：用于按模型上下文推导群总预算（用户反馈 #61）。
  final ProviderService? _providers;

  /// 附件内容提取用解析器（第 9 轮，同 [GenerationService] 口径）。
  final List<DocumentParser> _documentParsers;

  DuplicateDetector duplicateDetector = DuplicateDetector();
  OffTopicDetector offTopicDetector = OffTopicDetector();

  /// 指定组长（旧组长自动降为 member；组长唯一）。
  Future<void> setLeader(String conversationId, String expertId) async {
    final members = await _repos.conversations.listMembers(conversationId);
    final next = GroupRolePolicy.promoteToLeader(members, expertId);
    for (final m in next) {
      await _repos.conversations.upsertMember(m);
    }
  }

  /// 当前组长 expertId（无则 null）。
  Future<String?> leaderId(String conversationId) async =>
      GroupRolePolicy.leaderId(
          await _repos.conversations.listMembers(conversationId));

  /// 添加成员。
  Future<void> addMember(
    String conversationId,
    String expertId, {
    MemberRole role = MemberRole.member,
  }) =>
      _repos.conversations.upsertMember(ConversationMember(
        conversationId: conversationId,
        expertId: expertId,
        role: role,
      ));

  /// 移除成员：最少 1 名成员约束；若被删者是配置的总结者 → 清空 `group_configs`。
  Future<MemberRemovalResult> removeMember(
      String conversationId, String expertId) async {
    final members = await _repos.conversations.listMembers(conversationId);
    final result = GroupRolePolicy.removeMember(members, expertId);
    if (!result.applied) return result;

    await _repos.conversations.removeMember(conversationId, expertId);

    final cfg = await _repos.conversations.getGroupConfig(conversationId);
    if (cfg != null && cfg.summarizerExpertId == expertId) {
      await _repos.conversations
          .upsertGroupConfig(cfg.copyWith(summarizerExpertId: ''));
    }
    return result;
  }

  /// 生效总结者：`group_configs.summarizerExpertId ?? 组长`。
  Future<String?> effectiveSummarizer(String conversationId) async {
    final cfg = await _repos.conversations.getGroupConfig(conversationId);
    final members = await _repos.conversations.listMembers(conversationId);
    final configured =
        (cfg?.summarizerExpertId != null && cfg!.summarizerExpertId!.isNotEmpty)
            ? cfg.summarizerExpertId
            : null;
    return GroupRolePolicy.effectiveSummarizerId(configured, members);
  }

  // -------------------------------------------------------------------------
  // 群管理（第 6 轮：公告 / 策略 / 上限 / 群名）
  // -------------------------------------------------------------------------

  /// 读取群配置（供 UI 群管理面板；含公告 / 策略 / 单轮上限）。
  Future<GroupConfig?> config(String conversationId) =>
      _repos.conversations.getGroupConfig(conversationId);

  /// 更新群公告 / 共识（第 6 轮）：写 `announcement` + `announcement_updated_at`。
  ///
  /// 传空串表示清除公告（存储为 `''`；`GroupPromptComposer` 视为无公告跳过）。
  Future<void> updateAnnouncement(String conversationId, String text) async {
    final cfg = await _repos.conversations.getGroupConfig(conversationId) ??
        GroupConfig(conversationId: conversationId);
    await _repos.conversations.upsertGroupConfig(cfg.copyWith(
      announcement: text.trim(),
      announcementUpdatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// 更新发言策略（第 6 轮）：写 `speak_strategy`（含 `leader_led`）。
  ///
  /// 未注册的策略 id 直接拒绝（避免落一个运行时回落 auto 的死值）。
  Future<void> updateSpeakStrategy(
      String conversationId, String strategyId) async {
    if (SpeakingStrategies.byId(strategyId) == null) {
      throw ValidationError('group.strategy.unknown', '未知发言策略：$strategyId');
    }
    final cfg = await _repos.conversations.getGroupConfig(conversationId) ??
        GroupConfig(conversationId: conversationId);
    await _repos.conversations
        .upsertGroupConfig(cfg.copyWith(speakStrategy: strategyId));
  }

  /// 更新单轮发言者上限（第 6 轮）：写 `max_speakers_per_round`（防刷屏）。
  Future<void> updateMaxSpeakers(String conversationId, int n) async {
    if (n < 1 || n > 20) {
      throw ValidationError(
          'group.max_speakers.invalid', '单轮发言上限需在 1..20 之间：$n');
    }
    final cfg = await _repos.conversations.getGroupConfig(conversationId) ??
        GroupConfig(conversationId: conversationId);
    await _repos.conversations
        .upsertGroupConfig(cfg.copyWith(maxSpeakersPerRound: n));
  }

  /// 重命名群聊（第 6 轮）：写 `conversations.title`。
  Future<void> renameGroup(String conversationId, String title) async {
    final conv = await _repos.conversations.getConversation(conversationId);
    if (conv == null) {
      throw ValidationError('group.notfound', '会话不存在：$conversationId');
    }
    final t = title.trim();
    if (t.isEmpty) {
      throw ValidationError('group.title.empty', '群名称不能为空');
    }
    await _repos.conversations.upsertConversation(
      conv.copyWith(title: t, updatedAt: DateTime.now().millisecondsSinceEpoch),
    );
  }

  /// 判定专家输出是否为「不参与」静默哨兵（第 6 轮静默契约）。
  ///
  /// 容错：去首尾空白、去 markdown 强调符、去尾标点后，等于 [kNonParticipationToken]
  /// 或裸「不参与」即判定。**只做精确判定**（不做前缀匹配，避免误杀
  /// 「【不参与】，但我补充一点」这类实质发言）。
  static bool _looksLikeNonParticipation(String content) {
    final t = content.trim();
    if (t.isEmpty) return false;
    if (t.length > kNonParticipationToken.length + 8) return false;
    final cleaned = t
        .replaceAll(RegExp(r'[*_`~\s]'), '')
        .replaceAll(RegExp(r'[。.！!？?]+$'), '');
    return cleaned == kNonParticipationToken || cleaned == '不参与';
  }

  /// 跑一次群聊（完整流水线）。
  Stream<GenerationUpdate> runGroupChat({
    required String conversationId,
    required String userMessageId,
    required String userText,
    String? strategyOverride,
  }) async* {
    final conv = await _repos.conversations.getConversation(conversationId);
    if (conv == null) {
      throw ValidationError('group.notfound', '会话不存在：$conversationId');
    }

    final cfg = await _repos.conversations.getGroupConfig(conversationId) ??
        GroupConfig(conversationId: conversationId);
    final members = await _repos.conversations.listMembers(conversationId);

    // 附件内容注入（第 8 轮 T51 → 第 9 轮）：**每位发言者与总结者**都注入
    // 同一段（与单聊同口径）；文档正文进 userTask，图片 data URL 随每位发言者
    // 的 user 消息走多模态。检索 query 保持原始 userText（附件名/正文不混入）。
    final attCtx = await _buildAttachmentPromptContext(
        _repos, userMessageId, userText, _documentParsers);
    final userTask = attCtx.userTask;
    final userImageUrls = attCtx.imageUrls;

    final groupMembers = <GroupMember>[];
    for (final m in members) {
      final e = await _repos.experts.getExpert(m.expertId);
      if (e == null) continue;
      final tags = await _repos.experts.getTags(m.expertId);
      final state = await _repos.experts.getUserState(m.expertId);
      final rt = await _repos.experts.getRuntimeConfig(m.expertId);
      groupMembers.add(GroupMember(
        expertId: m.expertId,
        name: EffectiveExpertConfig.resolveName(e, state),
        weight: m.weight,
        expertise: tags.isNotEmpty
            ? tags
            : [
                if (e.profession != null && e.profession!.isNotEmpty)
                  e.profession!
              ],
        enabled: m.enabled && (rt?.enabled ?? true),
        sortOrder: m.sortOrder,
        role: m.role,
      ));
    }

    final history = await _repos.messages
        .listMessages(conversationId, limit: cfg.contextWindow ?? 60);

    final userMessage = Message(
      id: userMessageId,
      conversationId: conversationId,
      senderType: MessageSenderType.user,
      content: userText,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

    final ctx = GroupContext(
      conversationId: conversationId,
      userMessage: userMessage,
      recentMessages: history,
      members: groupMembers,
      budget: TokenBudget(maxTotalGroupBudget: cfg.tokenBudget ?? 40000),
      lastSpeakerId: history.reversed
          .where((m) => m.isFromExpert)
          .map((m) => m.senderId)
          .firstOrNull,
    );

    var run = GenerationRun.create(
      conversationId: conversationId,
      runType: RunType.groupChat,
      triggerMessageId: userMessageId,
      // 群总预算：优先用**模型上下文推导值**；群配置里显式设置的更小值仍然生效
      // （那是用户主动裁量）。此前写死 40000 是 64K 时代的尺子，会把长文档群聊
      // 在第 1 位专家后掐断（用户反馈 #61）。
      tokenBudget: _maxOf(cfg.tokenBudget,
          await _derivedGroupBudget(_providers)),
    ).copyWith(
        status: RunStatus.running,
        startedAt: DateTime.now().millisecondsSinceEpoch);
    await _repos.generations.upsertRun(run);
    yield RunStartedUpdate(run);

    // 第 6 轮：群角色信号（组长姓名 + 是否为组长），供提示词组装与发言范围使用。
    GroupMember? leaderMember;
    for (final m in groupMembers) {
      if (m.role == MemberRole.leader) {
        leaderMember = m;
        break;
      }
    }
    final leaderName = leaderMember?.name;

    // 发言范围指令（**用户本次指令**，优先级最高）：仅组长一人 / 组长发言 / 全体 / @点名。
    final directive = GroupDirectiveResolver.resolve(
      userText: userText,
      members: groupMembers,
      leaderId: leaderMember?.expertId,
    );

    // 单轮发言者上限（含强制入选者；NULL → 默认 3）。
    final maxSpeakers = cfg.maxSpeakersPerRound ?? 3;

    final strategyId = strategyOverride ?? cfg.speakStrategy;
    final List<String> rawSpeakers;
    if (directive != null) {
      // 用户显式指定 → 完全按指令执行（不再叠加策略相关性选择）。
      rawSpeakers = directive.expertIds;
    } else {
      // `leader_led` 需要按群配置动态构造（携带 max_speakers_per_round 上限）。
      final strategy = strategyId == kLeaderLedStrategyId
          ? LeaderLedStrategy(maxSpeakers: maxSpeakers)
          : (SpeakingStrategies.byId(strategyId) ?? AutoStrategy());
      final plan = await strategy.selectNextSpeakers(ctx);
      rawSpeakers = plan.primarySpeakers.take(maxSpeakers).toList();
    }
    // 只保留仍在群内且启用的成员；去重保序。
    final speakerIds = <String>[];
    for (final id in rawSpeakers) {
      final m = groupMembers.where((x) => x.expertId == id).firstOrNull;
      if (m == null || !m.enabled) continue;
      if (!speakerIds.contains(id)) speakerIds.add(id);
    }
    final speakerNames = <String>[
      for (final id in speakerIds)
        groupMembers.where((m) => m.expertId == id).firstOrNull?.name ?? id,
    ];

    var seq = 0;
    final outputs = <ExpertOutput>[];
    var totalPrompt = 0;
    var totalCompletion = 0;
    var anyFailed = false;
    // 6-B（契约 §2.8）：总结者失败用**独立标志**——**不复用 anyFailed**（避免"成员失败"
    // 与"总结失败"语义混淆：anyFailed 语义是"有成员失败"，同时驱动 errorCode 回填与终态真值表）。
    var summarizerFailed = false;
    // 首个失败成员的 error 对象（run 落 failed 时供 RunFailedUpdate 携带）。
    AppError? firstError;
    // 群级终态失败原因（首个失败成员的 error）：仅在 run 落 failed 时回填到 run
    // （与单聊失败路径同口径；partial 不回填，见 qa_verify_group_failure H1.13）。
    String? firstErrorCode;
    String? firstErrorMessage;

    for (final expertId in speakerIds) {
      if (run.isOverBudget) break;
      if (_cancelRequested.contains(run.id)) break;

      final member = groupMembers.firstWhere((m) => m.expertId == expertId);
      var step = GenerationStep.create(
        runId: run.id,
        stage: StepStage.generation,
        sequence: seq++,
        expertId: expertId,
      ).copyWith(
          status: RunStatus.running,
          startedAt: DateTime.now().millisecondsSinceEpoch);
      await _repos.generations.upsertStep(step);

      yield StepStatusUpdate(expertId: expertId, activity: Activity.preparing);

      // 失败路径（task #42 / 契约 §2.4）：占位消息与已累积正文需在 catch 中可见——
      // 单专家失败（Fail Soft）时也须把其占位消息置 MessageStatus.failed，不得留 streaming。
      Message? failedPlaceholder;
      final buffer = StringBuffer();

      try {
        final eff = await experts.resolveEffective(expertId);
        final resolved = await _resolveFor(eff);

        var evidence = <Citation>[];
        if (eff.groundingPolicy.needsRetrieval) {
          evidence = await knowledge.retrieveForExpert(
              expertId: expertId, query: userText);
          step = step.copyWith(retrievalCount: evidence.length);
          await _repos.generations.upsertStep(step);
        }
        final decision = GroundingResolver.resolve(
            policy: eff.groundingPolicy, evidence: evidence);

        if (decision is GroundedNoAnswer) {
          final msg = await conversations.appendExpertMessage(
            conversationId,
            expertId,
            kNoAnswerText,
          );
          step = step.copyWith(
            status: RunStatus.completed,
            endedAt: DateTime.now().millisecondsSinceEpoch,
            outputMessageId: msg.id,
          );
          await _repos.generations.upsertStep(step);
          outputs.add(
              ExpertOutput.skippedBy(expertId, member.name, decision.reason));
          yield StepFinishedUpdate(
            expertId: expertId,
            messageId: msg.id,
            content: kNoAnswerText,
            skipped: true,
            skipReason: decision.reason,
          );
          continue;
        }

        final citations = (decision as GroundedProceed).citations;
        // 第 6 轮群级提示词（**硬契约**）：群角色声明 + 群公告/共识 + 本轮发言范围 +
        // 表达纪律 + 相关性自判——注入**每位发言者**（含总结者）的 system。
        final groupBlocks = GroupPromptComposer.block(
          selfName: member.name,
          role: member.role,
          leaderName: leaderName,
          announcement: cfg.announcement,
          directive: directive,
          speakerNames: speakerNames,
        );
        final messages = ContextManager.build(
          systemPrompt: eff.prompt,
          styleDirective: StyleLibrary.directiveFor(eff.styleId),
          groupBlocks: groupBlocks,
          userTask: userTask,
          recentMessages: ctx.recentMessages,
          evidence: citations,
          strictGrounding: eff.groundingPolicy == GroundingPolicy.strict,
          // 预算按模型上下文推导（用户反馈 #61）：群总量 40000 是 64K 时代的
          // 写死值，会让招标文件这类长输入在第 1 位专家后被 isOverBudget 掐断。
          budget: resolved.budget,
          // 第 9 轮：本轮图片随每位发言者的 user 消息走多模态（无图 → 空列表）。
          userImageUrls: userImageUrls,
          // 历史发言者标签用展示名（防模型模仿 `【id】` 并冒领身份，第 8 轮根因修复）。
          nameOf: (id) =>
              groupMembers.where((m) => m.expertId == id).firstOrNull?.name ??
              id,
        );

        // 视觉门控（第 9 轮，与单聊同口径）：该发言者的模型未开
        // supports_vision 而本轮带图 → 明确报错（Fail Soft：仅本成员失败，
        // 不拖垮其他成员；错误原因在 step/消息/run 上均可见，不静默）。
        assertVisionSupported(
          supportsVision: resolved.supportsVision,
          modelId: resolved.modelId,
          messages: messages,
        );

        final msg = Message.expert(conversationId, expertId);
        failedPlaceholder = msg;
        await _repos.messages.insertMessage(msg);
        yield StepStatusUpdate(
            expertId: expertId, activity: Activity.generating);

        var evtSeq = 0;
        await for (final event in resolved.llm.stream(ChatRequest(
          model: resolved.modelId,
          messages: messages,
          temperature: eff.temperature,
          topP: eff.topP,
          maxTokens: eff.maxTokens,
        ))) {
          switch (event) {
            case TokenDelta(:final text):
              buffer.write(text);
              yield DeltaUpdate(
                  expertId: expertId, messageId: msg.id, text: text);
            case ReasoningDelta(:final text):
              // A①：思考通道**绝不进正文**，仅落 events 供排查（用户不可见）。
              await _repos.generations.appendEvent(GenerationEvent.create(
                stepId: step.id,
                sequence: ++evtSeq,
                eventType: GenerationEventType.reasoningDelta,
                delta: text,
              ));
            case UsageEvent(:final promptTokens, :final completionTokens):
              totalPrompt += promptTokens;
              totalCompletion += completionTokens;
            case StreamErrorEvent(:final error):
              throw error;
            case StreamDone():
              break;
          }
        }

        // A② 接线：先剥离过程性元叙述，再做长度裁剪，落库 / 交付均为剥离后的正文。
        final content = ReasoningStripper.strip(
          ContextManager.clampOutput(buffer.toString(), ctx.budget),
        ).text;

        // 静默契约（第 6 轮）：成员自判「与自身专业无关」→ step 记 skipped、
        // 消息置 cancelled 且正文清空、**UI 不渲染气泡**（绝不产生可见消息）。
        if (_looksLikeNonParticipation(content)) {
          final silent = msg.copyWith(
            content: '',
            status: MessageStatus.cancelled,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          );
          await _repos.messages.updateMessage(silent);
          step = step.copyWith(
            status: RunStatus.partial,
            endedAt: DateTime.now().millisecondsSinceEpoch,
            outputMessageId: msg.id,
          );
          await _repos.generations.upsertStep(step);
          outputs.add(
              ExpertOutput.skippedBy(expertId, member.name, '与自身专业无关，未参与'));
          yield StepFinishedUpdate(
            expertId: expertId,
            messageId: msg.id,
            content: '',
            skipped: true,
            skipReason: '与自身专业无关，未参与',
          );
          continue;
        }

        final finalMsg = msg.copyWith(
          content: content,
          status: MessageStatus.completed,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await _repos.messages.updateMessage(finalMsg);

        // 去重 / 跑题
        final dup = duplicateDetector.check(content, outputs,
            currentExpertId: expertId);
        if (dup.isDuplicate) {
          step = step.copyWith(
            status: RunStatus.partial,
            endedAt: DateTime.now().millisecondsSinceEpoch,
            outputMessageId: finalMsg.id,
          );
          await _repos.generations.upsertStep(step);
          outputs.add(ExpertOutput.skippedBy(
            expertId,
            member.name,
            '与前者重复（${dup.similarity.toStringAsFixed(2)}）',
          ));
          yield StepFinishedUpdate(
            expertId: expertId,
            messageId: finalMsg.id,
            content: content,
            citations: citations,
            skipped: true,
            skipReason: '与前者重复',
          );
          continue;
        }

        // 跑题检测：默认只记录信号，不丢弃输出（见 OffTopicDetector.skipEnabled）
        final topic = offTopicDetector.check(content, userText);
        if (topic.isOffTopic &&
            offTopicDetector.skipEnabled &&
            content.length > 40) {
          step = step.copyWith(
            status: RunStatus.partial,
            endedAt: DateTime.now().millisecondsSinceEpoch,
            outputMessageId: finalMsg.id,
          );
          await _repos.generations.upsertStep(step);
          outputs
              .add(ExpertOutput.skippedBy(expertId, member.name, topic.reason));
          yield StepFinishedUpdate(
            expertId: expertId,
            messageId: finalMsg.id,
            content: content,
            citations: citations,
            skipped: true,
            skipReason: topic.reason,
          );
          continue;
        }

        step = step.copyWith(
          status: RunStatus.completed,
          endedAt: DateTime.now().millisecondsSinceEpoch,
          outputMessageId: finalMsg.id,
          promptTokens: totalPrompt,
          completionTokens: totalCompletion,
          latencyMs:
              DateTime.now().millisecondsSinceEpoch - (step.startedAt ?? 0),
        );
        await _repos.generations.upsertStep(step);

        for (final c in citations) {
          await _repos.messages.insertCitation(finalMsg.id, c);
        }

        outputs.add(ExpertOutput(
          expertId: expertId,
          expertName: member.name,
          content: content,
          messageId: finalMsg.id,
          citations: citations,
        ));
        yield StepFinishedUpdate(
          expertId: expertId,
          messageId: finalMsg.id,
          content: content,
          citations: citations,
        );
      } catch (e) {
        // Fail Soft：单专家失败不拖垮整个群
        anyFailed = true;
        final err = e is AppError ? e : GenerationError('gen.unknown', '$e');
        // 记录**首个**失败成员的原因/错误对象（供 run 落 failed 时回填与 RunFailedUpdate，不覆盖）。
        firstError ??= err;
        firstErrorCode ??= err.code;
        firstErrorMessage ??= err.message;
        // 占位消息不得停留在 streaming（契约 §2.4）：与 step failed 同步置 failed，
        // 正文保留已累积内容（为空则空串）。
        final ph = failedPlaceholder;
        if (ph != null) {
          await _repos.messages.updateMessage(ph.copyWith(
            content: buffer.toString(),
            status: MessageStatus.failed,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ));
        }
        step = step.copyWith(
          status: RunStatus.failed,
          endedAt: DateTime.now().millisecondsSinceEpoch,
          errorCode: err.code,
          errorMessage: err.message,
        );
        await _repos.generations.upsertStep(step);
        outputs.add(ExpertOutput.skippedBy(expertId, member.name, err.message));
      }
    }

    // 总结者
    final accepted = outputs.where((o) => !o.skipped).toList();
    if (accepted.length >= 2) {
      final summarizerId = cfg.summarizerExpertId ?? accepted.first.expertId;
      var sStep = GenerationStep.create(
        runId: run.id,
        stage: StepStage.synthesis,
        sequence: seq++,
        expertId: summarizerId,
      ).copyWith(
          status: RunStatus.running,
          startedAt: DateTime.now().millisecondsSinceEpoch);
      await _repos.generations.upsertStep(sStep);
      yield StepStatusUpdate(
          expertId: summarizerId, activity: Activity.thinking);

      try {
        final eff = await experts.resolveEffective(summarizerId);
        final resolved = await _resolveFor(eff);
        final buf = StringBuffer();
        // 群公告（硬契约）：总结者同样注入——公告为「共识」载体，总结须遵守。
        final summaryBase =
            Summarizer.buildPrompt(userTask: userTask, outputs: accepted);
        final consensus = GroupPromptComposer.consensusBlock(cfg.announcement);
        final summaryMessages = consensus.isEmpty
            ? summaryBase
            : <ChatMessage>[
                ChatMessage(ChatRole.system,
                    '${summaryBase.first.content}\n\n$consensus'),
                ...summaryBase.skip(1),
              ];
        await for (final ev in resolved.llm.stream(ChatRequest(
          model: resolved.modelId,
          messages: summaryMessages,
        ))) {
          switch (ev) {
            case TokenDelta(:final text):
              buf.write(text);
            case ReasoningDelta():
              // 总结阶段同样不将思考写入正文。
              break;
            case StreamErrorEvent(:final error):
              throw error;
            case UsageEvent():
            case StreamDone():
              break;
          }
        }
        // A② 接线：总结者正文同样剥离过程性元叙述（第三条路径，勿漏）。
        final summary = SummaryResult.fromModelText(
          ReasoningStripper.strip(buf.toString()).text,
        );
        final sMsg = await conversations.appendExpertMessage(
          conversationId,
          summarizerId,
          summary.toMarkdown(),
        );
        sStep = sStep.copyWith(
          status: RunStatus.completed,
          endedAt: DateTime.now().millisecondsSinceEpoch,
          outputMessageId: sMsg.id,
        );
        await _repos.generations.upsertStep(sStep);
        yield SummaryUpdate(messageId: sMsg.id, summary: summary);
      } catch (e) {
        // 6-B（契约 §2.8）：总结者失败置**独立标志** summarizerFailed（**不复用 anyFailed**，
        // 避免"成员失败"与"总结失败"语义混淆），使终态按真值表落 partial
        // （成员全成功 + 仅总结者失败时不得静默停在 completed）；
        // 同时产出 SummaryFailedUpdate → UI 渲染"未产出纪要"提示条（不得静默）。
        summarizerFailed = true;
        final err =
            e is AppError ? e : GenerationError('gen.summarizer_failed', '$e');
        sStep = sStep.copyWith(
          status: RunStatus.failed,
          endedAt: DateTime.now().millisecondsSinceEpoch,
          errorCode: err.code,
          errorMessage: err.message,
        );
        await _repos.generations.upsertStep(sStep);
        yield SummaryFailedUpdate(expertId: summarizerId, error: err);
      }
    }

    // 终态真值表（契约 §2.7 / §2.8）：
    //   无成员产出（accepted 空）→ 有成员失败 failed，否则 completed；
    //   有成员产出 → 「有成员失败」或「总结失败」均落 partial；
    //   其余 completed。
    final RunStatus finalStatus;
    if (accepted.isEmpty) {
      finalStatus = anyFailed ? RunStatus.failed : RunStatus.completed;
    } else {
      finalStatus = (anyFailed || summarizerFailed)
          ? RunStatus.partial
          : RunStatus.completed;
    }
    // 6-A（H2.9）：run 落 failed 时回填首个失败成员原因（与单聊口径一致）；
    // partial / completed 不回填（copyWith 传 null = 保持原值 null）。
    final runFailed = finalStatus == RunStatus.failed;
    run = run.copyWith(
      status: finalStatus,
      promptTokens: totalPrompt,
      completionTokens: totalCompletion,
      endedAt: DateTime.now().millisecondsSinceEpoch,
      errorCode: runFailed ? firstErrorCode : null,
      errorMessage: runFailed ? firstErrorMessage : null,
    );
    await _repos.generations.upsertRun(run);
    yield RunFinishedUpdate(run);
    // 6-B（契约 §2.8-B）：群聊 run 落 failed 时同样产出失败事件（与单聊同口径），
    // 修掉"群聊从不产出失败事件"。
    if (runFailed) {
      yield RunFailedUpdate(
        run,
        firstError ?? GenerationError('gen.unknown', '群聊全部成员发言失败'),
      );
    }
  }

  final Set<String> _cancelRequested = {};

  Future<_ResolvedRuntime> _resolveFor(EffectiveExpertConfig eff) async {
    final modelProfileId = eff.modelProfileId;
    final credId = eff.credentialProfileId;
    if (modelProfileId == null) {
      throw const ValidationError('gen.unconfigured', '模型未配置');
    }
    if (credId == null) {
      throw const ValidationError('gen.unconfigured', '凭据未配置');
    }
    final model = await _repos.providers.getModel(modelProfileId);
    if (model == null) throw ValidationError('gen.model_missing', '模型档案不存在');
    final provider =
        await _repos.providers.getProvider(model.providerProfileId);
    if (provider == null)
      throw ValidationError('gen.provider_missing', 'Provider 不存在');
    final cred = await _repos.credentials.get(credId);
    final apiKey =
        cred == null ? null : await _repos.secrets.read(cred.secretRef);
    if (apiKey == null || apiKey.isEmpty)
      throw const AuthenticationError('未找到 API Key');
    return _ResolvedRuntime(
      modelProfileId: modelProfileId,
      modelId: model.modelId,
      supportsVision: model.supportsVision,
      llm: llmFactory(provider.id),
      contextWindow: model.contextWindow,
    );
  }
  /// 取消运行中的群聊生成。
  Future<void> cancel(String runId) async {
    _cancelRequested.add(runId);
    final run = await _repos.generations.getRun(runId);
    if (run != null && run.status == RunStatus.running) {
      await _repos.generations.upsertRun(
        run.copyWith(
            status: RunStatus.cancelled,
            endedAt: DateTime.now().millisecondsSinceEpoch),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// 市场服务
// ---------------------------------------------------------------------------

/// 市场服务：刷新索引 / 安装包 / 检查更新。
class MarketService {
  MarketService(this._repos, {required this.experts});
  final Repositories _repos;
  final ExpertService experts;

  static const defaultSourceId = 'src_github';
  static const defaultBaseUrl =
      'https://raw.githubusercontent.com/TZW1982/private-advisor-market/main';

  /// 注册默认市场源（幂等）。
  Future<void> registerDefaultSource() async {
    await _repos.market.upsertSource(const MarketSource(
      id: defaultSourceId,
      name: '私人顾问团官方市场',
      baseUrl: defaultBaseUrl,
    ));
  }

  Future<List<MarketSource>> sources() => _repos.market.listSources();

  /// 用已下载的索引文本刷新本地市场缓存。
  Future<int> applyIndex(String jsonText,
      {String sourceId = defaultSourceId}) async {
    final index = MarketIndex.parse(jsonText);
    await _repos.market.replacePackages(sourceId, index.packages);
    await _repos.market
        .setIndexEtag(sourceId, null, DateTime.now().millisecondsSinceEpoch);
    return index.packages.length;
  }

  /// 从市场源拉取索引并刷新（第 4 轮新增：HTTP 由 [MarketHttpClient] 端口注入，
  /// core 零网络依赖；实现在 app 层，测试注入假实现）。
  Future<int> refreshIndex({
    required MarketHttpClient client,
    String sourceId = defaultSourceId,
  }) async {
    final sources = await _repos.market.listSources();
    MarketSource? source;
    for (final s in sources) {
      if (s.id == sourceId) source = s;
    }
    if (source == null) {
      throw ValidationError('market.source.notfound', '市场源不存在：$sourceId');
    }
    final text = await client.fetchText(source.catalogUrl);
    return applyIndex(text, sourceId: sourceId);
  }

  Future<List<MarketPackage>> listPackages({String? categoryId}) =>
      _repos.market.listPackages(categoryId: categoryId);

  /// 存量专家**回填** emoji 头像（第 #66 轮配套）。
  ///
  /// v9 之前安装的专家（`experts.avatar_emoji` 为 NULL）依然只有首字头像。
  /// 这里按 `packageId` 从**本地市场索引**补上 emoji / color（纯读库、不联网）：
  /// - 只处理 `source == market` 且尚无 emoji 的专家；
  /// - 索引里查不到该包 / 包本身无 emoji → 跳过（保持 null → 首字回退）；
  /// - 走 `upsertExpert` 直写本体，**不碰** `expert_user_states`（不标记本地修改，
  ///   不影响"市场更新不覆盖用户改动"的既有语义）。
  ///
  /// 返回实际回填的专家数（幂等：回填过后再跑为 0）。
  Future<int> backfillExpertAvatars() async {
    final pkgs = await _repos.market.listPackages();
    final byId = <String, MarketPackage>{
      for (final p in pkgs) p.packageId: p,
    };
    var count = 0;
    for (final e in await _repos.experts.listExperts()) {
      if (e.source != ExpertSource.market) continue;
      final packageId = e.packageId;
      if (packageId == null) continue;
      if ((e.avatarEmoji ?? '').trim().isNotEmpty) continue;
      final pkg = byId[packageId];
      final emoji = pkg?.emoji;
      if (emoji == null || emoji.trim().isEmpty) continue;
      await _repos.experts.upsertExpert(e.copyWith(
        avatarEmoji: emoji,
        avatarColor: pkg?.color,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      count++;
    }
    return count;
  }

  Future<MarketPackage?> getPackage(String packageId) =>
      _repos.market.getPackage(packageId);

  Future<List<InstalledPackage>> installed() => _repos.market.listInstalled();

  /// 检查更新。
  Future<UpdateDecision> checkUpdate(String packageId) async {
    final pkg = await _repos.market.getPackage(packageId);
    final inst = await _repos.market.getInstalledByPackageId(packageId);
    if (pkg == null || inst == null) return UpdateDecision.upToDate;
    return UpdatePolicy.decide(
      installed: inst.version,
      available: pkg.latestVersion,
      localModified: inst.localModified,
    );
  }

  /// 安装（校验通过后写库）。
  ///
  /// [welcomeMessage] / [quickPrompts] 为 expert.json 中的可选字段
  /// （第 4 轮新增，缺省不传则不设置；additive，不影响既有调用方）。
  Future<Expert> installPackage({
    required PackageManifest manifest,
    required PackageVerification verification,
    required String systemPrompt,
    required String installPath,
    String? welcomeMessage,
    List<String> quickPrompts = const [],
  }) async {
    if (!verification.ok) {
      final f = verification.firstFailure;
      throw UnsafePackageError('包校验未通过：${f?.name} ${f?.detail ?? ''}');
    }
    final pkg = await _repos.market.getPackage(manifest.packageId);
    return experts.installFromPackage(
      packageId: manifest.packageId,
      version: manifest.version.toString(),
      displayName: manifest.displayName,
      systemPrompt: systemPrompt,
      installPath: installPath,
      categoryId: manifest.categoryId,
      welcomeMessage: welcomeMessage,
      quickPrompts: quickPrompts,
      // 第 #66 轮：把市场包自带 emoji / color 一并写入专家档案——否则专家只在
      // 市场页有 emoji，加进通讯录后 `Expert` 无头像字段 → 回退首字。
      // 索引里没有该包（如侧载安装）时为 null → 走回退档，行为不变。
      avatarEmoji: pkg?.emoji,
      avatarColor: pkg?.color,
    );
  }
}

/// JSON 编码（供上层使用，避免直接依赖 dart:convert）。
String encodeJson(Object? value) => jsonEncode(value);
