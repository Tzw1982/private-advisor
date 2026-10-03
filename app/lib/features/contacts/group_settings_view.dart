/// 群管理表单（第 6 轮 T03）：群名称 / 组长任命 / 发言策略 / 群公告 / 单轮上限。
///
/// 供中栏内联群卡片「群管理」页签使用（[GroupSummaryCard]）。所有写入经
/// [GroupService] 新方法（`renameGroup` / `setLeader` / `updateSpeakStrategy` /
/// `updateAnnouncement` / `updateMaxSpeakers`），UI 不直接写库。
///
/// 优先级说明（第 6 轮共享约定 §2）：本表单设置的是**持久策略**；
/// 用户在消息里说「让组长一个人发言」等为**本次覆盖**，优先级更高、单次有效。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';

/// 「总裁助理」市场包 ID（`market/packages-src/executive-assistant`）。
///
/// 一键任命流程据此在**已安装专家**中定位总裁助理——`Expert.id` 是本地实例 id，
/// 不稳定；`packageId` 才与市场包对应（expert.dart 硬规则）。
const String kChiefOfStaffPackageId = 'org.private-advisor.executive-assistant';

/// 群管理表单。
class GroupSettingsView extends StatefulWidget {
  const GroupSettingsView({
    super.key,
    required this.conversationId,
    required this.group,
    required this.experts,
    required this.conversations,
    required this.repos,
    this.compact = false,
    this.onChanged,
  });

  final String conversationId;
  final GroupService group;
  final ExpertService experts;
  final ConversationService conversations;
  final Repositories repos;

  /// 紧凑版式（中栏 ~296px 卡片内使用）。
  final bool compact;

  /// 任一设置保存成功后回调（宿主可刷新）。
  final VoidCallback? onChanged;

  @override
  State<GroupSettingsView> createState() => _GroupSettingsViewState();
}

class _GroupSettingsViewState extends State<GroupSettingsView> {
  final _titleCtrl = TextEditingController();
  final _announcementCtrl = TextEditingController();

  List<ConversationMember> _members = const [];
  final Map<String, String> _names = {};

  String _strategy = 'auto';
  String? _leaderId;
  int? _maxSpeakers;
  int? _announcementUpdatedAt;

  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _announcementCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final conv = await widget.repos.conversations
          .getConversation(widget.conversationId);
      final cfg = await widget.group.config(widget.conversationId) ??
          GroupConfig(conversationId: widget.conversationId);
      final members =
          await widget.repos.conversations.listMembers(widget.conversationId);
      final names = <String, String>{};
      for (final m in members) {
        final e = await widget.experts.get(m.expertId);
        if (e == null) {
          names[m.expertId] = m.expertId;
          continue;
        }
        final state = await widget.repos.experts.getUserState(m.expertId);
        names[m.expertId] = EffectiveExpertConfig.resolveName(e, state);
      }
      final leader = await widget.group.leaderId(widget.conversationId);
      if (!mounted) return;
      _titleCtrl.text = conv?.title ?? '';
      _announcementCtrl.text = cfg.announcement ?? '';
      setState(() {
        _members = members;
        _names
          ..clear()
          ..addAll(names);
        _strategy = cfg.speakStrategy;
        _leaderId = leader;
        _maxSpeakers = cfg.maxSpeakersPerRound;
        _announcementUpdatedAt = cfg.announcementUpdatedAt;
        _loading = false;
      });
    } on AppError catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '加载群设置失败：$e';
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

  Future<void> _saveTitle() async {
    final t = _titleCtrl.text.trim();
    if (t.isEmpty) {
      _snack('群名称不能为空');
      return;
    }
    await _guard(() async {
      await widget.group.renameGroup(widget.conversationId, t);
      _snack('群名称已更新');
    });
  }

  Future<void> _changeStrategy(String? id) async {
    if (id == null || id == _strategy) return;
    await _guard(() async {
      await widget.group.updateSpeakStrategy(widget.conversationId, id);
      _snack('发言策略已更新为「${SpeakingStrategies.byId(id)?.label ?? id}」');
    });
  }

  Future<void> _changeLeader(String? expertId) async {
    if (expertId == null || expertId == _leaderId) return;
    await _guard(() async {
      await widget.group.setLeader(widget.conversationId, expertId);
      _snack('已任命「${_names[expertId] ?? expertId}」为组长');
    });
  }

  /// 一键任命「总裁助理」为组长（第 6 轮 T04）。
  ///
  /// 流程：在**已安装专家**中按 [kChiefOfStaffPackageId] 定位总裁助理 →
  /// 不在群内则先 `addMember` 入群 → `setLeader` 任命；未安装则引导去市场添加。
  Future<void> _appointChiefOfStaff() async {
    if (_busy) return;
    List<Expert> all;
    try {
      all = await widget.experts.list();
    } on AppError catch (e) {
      _snack(e.message);
      return;
    } catch (e) {
      _snack('读取专家列表失败：$e');
      return;
    }
    Expert? cos;
    for (final e in all) {
      if (e.packageId == kChiefOfStaffPackageId) {
        cos = e;
        break;
      }
    }
    if (cos == null) {
      _snack('尚未添加「总裁助理」。请到「人才市场 → 运营与人力」搜索「总裁助理」并添加后重试。');
      return;
    }
    final target = cos;
    await _guard(() async {
      final members =
          await widget.repos.conversations.listMembers(widget.conversationId);
      final isMember = members.any((m) => m.expertId == target.id);
      if (!isMember) {
        await widget.group.addMember(widget.conversationId, target.id);
      }
      await widget.group.setLeader(widget.conversationId, target.id);
      _snack('已任命「${target.name}」为组长${isMember ? '' : '（已自动加入本群）'}');
    });
  }

  Future<void> _saveAnnouncement() async {
    await _guard(() async {
      await widget.group
          .updateAnnouncement(widget.conversationId, _announcementCtrl.text);
      _snack('群公告已保存（将注入每位成员的发言上下文）');
    });
  }

  Future<void> _changeMaxSpeakers(int? n) async {
    if (n == null || n == _maxSpeakers) return;
    await _guard(() async {
      await widget.group.updateMaxSpeakers(widget.conversationId, n);
      _snack('单轮发言上限已设为 $n');
    });
  }

  /// 单轮上限是否落在 UI 可选区间（1..8）。
  bool _inRange(int? n) => n != null && n >= 1 && n <= 8;

  String _formatTs(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
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

    final compact = widget.compact;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // —— 群名称 ——
        _sectionLabel('群名称', compact),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _titleCtrl,
                enabled: !_busy,
                style: TextStyle(fontSize: compact ? 12 : 13),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy ? null : _saveTitle,
              child: const Text('保存', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // —— 组长任命 ——
        _sectionLabel('组长', compact),
        Row(
          children: [
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _leaderId,
                hint: Text('未设组长',
                    style: TextStyle(
                        fontSize: compact ? 12 : 13,
                        color: AppColors.textTertiary)),
                style: TextStyle(
                    fontSize: compact ? 12 : 13, color: AppColors.textPrimary),
                onChanged: _busy ? null : _changeLeader,
                items: [
                  for (final m in _members)
                    DropdownMenuItem(
                      value: m.expertId,
                      child: Text(_names[m.expertId] ?? m.expertId,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text('组长负责组织讨论、分派任务；「组长主持」策略下由组长主持并按相关性邀请成员发言。',
            style: TextStyle(fontSize: 10, color: AppColors.textTertiary)),
        const SizedBox(height: 4),
        // 一键任命「总裁助理」为组长（T04）：已安装 → 入群并任命；未安装 → 引导添加。
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy ? null : _appointChiefOfStaff,
            icon: const Icon(Icons.support_agent, size: 16),
            label: const Text('任命总裁助理为组长', style: TextStyle(fontSize: 12)),
          ),
        ),
        const SizedBox(height: 6),

        // —— 发言策略 ——
        _sectionLabel('发言策略', compact),
        DropdownButton<String>(
          isExpanded: true,
          // 防御：配置里的策略 id 若不在注册表（异常数据）→ 回退 null 显示 hint，避免断言崩溃。
          value: SpeakingStrategies.byId(_strategy) != null ? _strategy : null,
          hint: Text('未设置',
              style: TextStyle(
                  fontSize: compact ? 12 : 13, color: AppColors.textTertiary)),
          style: TextStyle(
              fontSize: compact ? 12 : 13, color: AppColors.textPrimary),
          onChanged: _busy ? null : _changeStrategy,
          items: [
            for (final s in SpeakingStrategies.all())
              DropdownMenuItem(value: s.id, child: Text(s.label)),
          ],
        ),
        const SizedBox(height: AppDims.space1),
        Text('持久策略；若你在消息里明确点名（如「让组长一个人发言」），本次以你的指令为准。',
            style: TextStyle(fontSize: 10, color: AppColors.textTertiary)),
        const SizedBox(height: 10),

        // —— 单轮发言上限 ——
        _sectionLabel('单轮发言上限', compact),
        Row(
          children: [
            DropdownButton<int>(
              // 仅展示 1..8；越界值回退 null（hint）避免 DropdownButton 断言崩溃。
              value: _inRange(_maxSpeakers)
                  ? _maxSpeakers
                  : (_maxSpeakers == null ? 3 : null),
              hint: Text('默认 3',
                  style: TextStyle(
                      fontSize: compact ? 12 : 13,
                      color: AppColors.textTertiary)),
              style: TextStyle(
                  fontSize: compact ? 12 : 13, color: AppColors.textPrimary),
              onChanged: _busy ? null : _changeMaxSpeakers,
              items: [
                for (var n = 1; n <= 8; n++)
                  DropdownMenuItem(value: n, child: Text('$n 位')),
              ],
            ),
            const SizedBox(width: AppDims.space2),
            Expanded(
              child: Text('防止一轮里太多人发言刷屏；未设置时默认 3。',
                  style:
                      TextStyle(fontSize: 10, color: AppColors.textTertiary)),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // —— 群公告（共识） ——
        _sectionLabel('群公告 / 共识', compact),
        TextField(
          controller: _announcementCtrl,
          enabled: !_busy,
          minLines: 2,
          maxLines: 4,
          style: TextStyle(fontSize: compact ? 12 : 13),
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            hintText: '例如：本群只服务商务合规项目，无关话题一律不参与。',
            hintStyle: TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            TextButton(
              onPressed: _busy ? null : _saveAnnouncement,
              child: const Text('保存公告', style: TextStyle(fontSize: 12)),
            ),
            if (_announcementUpdatedAt != null)
              Expanded(
                child: Text('最后更新：${_formatTs(_announcementUpdatedAt!)}',
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.textTertiary)),
              ),
          ],
        ),
        const SizedBox(height: AppDims.space1),
        Text('公告会注入每位成员（含总结者）的发言上下文，用于统一本群共识。',
            style: TextStyle(fontSize: 10, color: AppColors.textTertiary)),
      ],
    );
  }

  Widget _sectionLabel(String text, bool compact) => Padding(
        padding: const EdgeInsets.only(bottom: AppDims.space1),
        child: Text(text,
            style: TextStyle(
                fontSize: compact ? 12 : 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary)),
      );
}
