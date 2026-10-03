/// 群成员列表（**共享组件**：群成员对话框 + 中栏内联群卡片共用，第 6 轮 T03）。
///
/// 从 `GroupMembersPanel`（第 3 轮对话框版）**抽取**而来——对话框与新卡片
/// 复用同一实现，**扩展复用、不复制**（避免两份成员管理逻辑漂移）。
///
/// 交互规则（PRD §6.1.5 / §6.5，写死）：
/// - 成员列表**只读**（角色徽标展示；组员角色不可改）；
/// - 组长**恰好 0 或 1 名**：设新组长时旧组长自动降级（`GroupRolePolicy.promoteToLeader`）；
/// - **删到 0 人禁删**：群聊至少保留 1 名成员（`GroupRolePolicy.removeMember` 拒绝）；
/// - 生效总结者 = `group_configs.summarizerExpertId ?? 组长`（无组长则为 null）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import '../../ui/widgets/expert_avatar.dart';

/// 群成员列表（自包含加载 + 动作）。
class GroupMemberList extends StatefulWidget {
  const GroupMemberList({
    super.key,
    required this.conversationId,
    required this.group,
    required this.experts,
    required this.repos,
    this.compact = false,
    this.onChanged,
  });

  final String conversationId;
  final GroupService group;
  final ExpertService experts;
  final Repositories repos;

  /// 紧凑版式（中栏 ~296px 卡片内使用）。
  final bool compact;

  /// 成员/组长发生变更后回调（宿主可刷新计数等）。
  final VoidCallback? onChanged;

  @override
  State<GroupMemberList> createState() => _GroupMemberListState();
}

class _GroupMemberListState extends State<GroupMemberList> {
  List<ConversationMember> _members = const [];
  final Map<String, String> _names = {}; // expertId → 展示名（备注优先）
  final Map<String, String?> _avatarPaths = {}; // expertId → 市场包自带头像路径（可为 null）
  final Map<String, String?> _avatarEmojis = {}; // expertId → 市场包自带 emoji（可为 null）
  final Map<String, String?> _avatarColors = {}; // expertId → emoji 底色（可为 null）
  String? _effectiveSummarizerId;

  bool _loading = true;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final members =
          await widget.repos.conversations.listMembers(widget.conversationId);
      final names = <String, String>{};
      final avatarPaths = <String, String?>{};
      final avatarEmojis = <String, String?>{};
      final avatarColors = <String, String?>{};
      for (final m in members) {
        final e = await widget.experts.get(m.expertId);
        if (e == null) {
          names[m.expertId] = m.expertId;
          avatarPaths[m.expertId] = null;
          avatarEmojis[m.expertId] = null;
          avatarColors[m.expertId] = null;
          continue;
        }
        final state = await widget.repos.experts.getUserState(m.expertId);
        names[m.expertId] = EffectiveExpertConfig.resolveName(e, state);
        avatarPaths[m.expertId] = e.avatarPath;
        // 第 #66 轮：emoji 头像一并带出（安装时从市场索引写入专家档案）。
        avatarEmojis[m.expertId] = e.avatarEmoji;
        avatarColors[m.expertId] = e.avatarColor;
      }
      final summarizer =
          await widget.group.effectiveSummarizer(widget.conversationId);
      if (!mounted) return;
      setState(() {
        _members = members;
        _names
          ..clear()
          ..addAll(names);
        _avatarPaths
          ..clear()
          ..addAll(avatarPaths);
        _avatarEmojis
          ..clear()
          ..addAll(avatarEmojis);
        _avatarColors
          ..clear()
          ..addAll(avatarColors);
        _effectiveSummarizerId = summarizer;
        _loading = false;
      });
    } on AppError catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '加载群成员失败：$e';
        _loading = false;
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AppError catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _reload();
      widget.onChanged?.call();
    }
  }

  // -------------------------------------------------------------------------
  // 动作
  // -------------------------------------------------------------------------

  Future<void> _setLeader(ConversationMember m) async {
    await _guard(() async {
      await widget.group.setLeader(widget.conversationId, m.expertId);
      _snack('已设「${_names[m.expertId] ?? m.expertId}」为组长（原组长已自动降为成员）');
    });
  }

  Future<void> _removeMember(ConversationMember m) async {
    // 禁删到底线：至少保留 1 名成员（按钮已置灰，此处双保险）。
    if (_members.length <= 1) {
      _snack('群聊至少保留 1 名成员，无法移除');
      return;
    }
    final name = _names[m.expertId] ?? m.expertId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除成员'),
        content: Text('确定把「$name」移出群聊？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _guard(() async {
      final result =
          await widget.group.removeMember(widget.conversationId, m.expertId);
      _snack(result.applied
          ? (result.message ?? '已移除「$name」')
          : (result.message ?? '移除失败'));
    });
  }

  Future<void> _addMember() async {
    final existing = _members.map((m) => m.expertId).toSet();
    final all = await widget.experts.list();
    final candidates = <(Expert, ExpertUserState?)>[];
    for (final e in all) {
      if (existing.contains(e.id)) continue;
      candidates.add((e, await widget.repos.experts.getUserState(e.id)));
    }
    if (candidates.isEmpty) {
      _snack('没有可添加的联系人（好友均已在群内）');
      return;
    }
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) {
        final selected = <String>{};
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('添加群成员'),
            content: SizedBox(
              width: 360,
              height: 340,
              child: ListView.builder(
                itemCount: candidates.length,
                itemBuilder: (_, i) {
                  final (e, state) = candidates[i];
                  return CheckboxListTile(
                    dense: true,
                    value: selected.contains(e.id),
                    title: Text(EffectiveExpertConfig.resolveName(e, state),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onChanged: (v) => setDialogState(() =>
                        v == true ? selected.add(e.id) : selected.remove(e.id)),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('取消')),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.of(ctx).pop(selected),
                child: Text('添加 ${selected.length} 位'),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null || picked.isEmpty) return;
    await _guard(() async {
      for (final id in picked) {
        // 新成员一律默认组员（member）；组长只能由「设为组长」产生，保证恰好 0/1 名。
        await widget.group.addMember(widget.conversationId, id);
      }
      _snack('已添加 ${picked.length} 位成员');
    });
  }

  // -------------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(AppDims.space3),
        child: Text(_error!,
            style: const TextStyle(color: AppColors.error, fontSize: 12)),
      );
    }

    final summarizerName = _effectiveSummarizerId == null
        ? '无（无组长且未配置）'
        : _names[_effectiveSummarizerId] ?? _effectiveSummarizerId!;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '成员（${_members.length}） · 生效总结者：$summarizerName',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            IconButton(
              tooltip: '添加成员',
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: const Icon(Icons.person_add_alt),
              onPressed: _busy ? null : _addMember,
            ),
          ],
        ),
        const SizedBox(height: 2),
        // 自包含（用 Column 铺开成员行，避免嵌套滚动；成员数量级很小）。
        for (final m in _members) _memberTile(m),
        if (!widget.compact) ...[
          const SizedBox(height: AppDims.space1),
          const Text(
            '规则：组长恰好 0 或 1 名；设新组长时旧组长自动降级；至少保留 1 名成员。',
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
        ],
      ],
    );
  }

  Widget _memberTile(ConversationMember m) {
    final name = _names[m.expertId] ?? m.expertId;
    final isLeader = m.role == MemberRole.leader;
    final canRemove = _members.length > 1;
    return ListTile(
      dense: true,
      visualDensity: widget.compact ? VisualDensity.compact : null,
      contentPadding: EdgeInsets.zero,
      leading: ExpertAvatar(
        expertId: m.expertId,
        name: name,
        explicitPath: _avatarPaths[m.expertId],
        avatarEmoji: _avatarEmojis[m.expertId],
        avatarColor: _avatarColors[m.expertId],
        radius: widget.compact ? 13 : 15,
        fontSize: widget.compact ? 11 : 12,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: widget.compact ? 12 : 13)),
          ),
          const SizedBox(width: 6),
          _roleBadge(m.role),
        ],
      ),
      // 成员列表只读：不提供改备注/权重等编辑入口（组员只读，按钮仅保留组长/移除）。
      subtitle: widget.compact
          ? null
          : Text('角色：${m.role.label} · 权重 ${m.weight.toStringAsFixed(1)}',
              style:
                  const TextStyle(fontSize: 11, color: AppColors.textTertiary)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            // 已是组长则置灰（组员角色只读，唯一可改操作是"换组长"）。
            onPressed: _busy || isLeader ? null : () => _setLeader(m),
            child: const Text('设为组长', style: TextStyle(fontSize: 12)),
          ),
          IconButton(
            tooltip: canRemove ? '移出群聊' : '群聊至少保留 1 名成员',
            iconSize: AppDims.iconNav,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.remove_circle_outline,
                color: canRemove ? AppColors.error : AppColors.textTertiary),
            onPressed: _busy || !canRemove ? null : () => _removeMember(m),
          ),
        ],
      ),
    );
  }

  Widget _roleBadge(MemberRole role) {
    // 徽标底色/字色一律取自 AppColors（组长=success、总结者=warning 派生、
    // 组员=中性色阶），不写裸色值。
    final (bg, fg) = switch (role) {
      MemberRole.leader => (AppColors.success, AppColors.bgPrimary),
      MemberRole.summarizer => (
          AppColors.warning.withValues(alpha: 0.15),
          AppColors.textPrimary
        ),
      MemberRole.member => (AppColors.bgTertiary, AppColors.textSecondary),
    };
    return Container(
      // 徽标内边距 2×4（规格 4.2 标签同款）。
      padding:
          const EdgeInsets.symmetric(horizontal: AppDims.space1, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppDims.radiusS),
      ),
      child: Text(role.label, style: TextStyle(fontSize: 10, color: fg)),
    );
  }
}
