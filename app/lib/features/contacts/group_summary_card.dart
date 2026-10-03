/// 中栏内联群卡片（第 6 轮 T03 · A 组：群卡片与群管理）。
///
/// 在会话列表（会话页签）与群聊页签（通讯录页签）的群项**下方展开**：
/// 顶部两个导航「群成员 ｜ 群管理」（默认群成员），内容区随导航切换。
///
/// - 「群成员」复用共享组件 [GroupMemberList]；
/// - 「群管理」复用 [GroupSettingsView]（群名称 / 组长 / 策略 / 公告 / 上限）。
///
/// **单一展开原则**：卡片的展开/收起由**父级**（列表）持 `_expandedId` 控制，
/// 本组件只负责渲染内容——与通讯录好友卡的收回**同源**（父级单一展开）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'group_member_list.dart';
import 'group_settings_view.dart';

/// 中栏内联群卡片。
class GroupSummaryCard extends StatefulWidget {
  const GroupSummaryCard({
    super.key,
    required this.conversationId,
    required this.group,
    required this.experts,
    required this.conversations,
    required this.repos,
    this.onOpenConversation,
  });

  final String conversationId;
  final GroupService group;
  final ExpertService experts;
  final ConversationService conversations;
  final Repositories repos;

  /// 「进入群聊」→ 右栏打开会话（可选）。
  final ValueChanged<String>? onOpenConversation;

  @override
  State<GroupSummaryCard> createState() => _GroupSummaryCardState();
}

class _GroupSummaryCardState extends State<GroupSummaryCard> {
  int _tab = 0; // 0=群成员 1=群管理

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
          AppDims.space3, 0, AppDims.space3, AppDims.space2),
      decoration: BoxDecoration(
        color: AppColors.bgSecondary,
        borderRadius: BorderRadius.circular(AppDims.radiusM),
        border: Border.all(color: AppColors.divider),
      ),
      padding: const EdgeInsets.all(AppDims.space2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _nav(),
          const Divider(height: AppDims.space4),
          // 切页签即换 key → 内容区重载（保证两页签数据一致）。
          KeyedSubtree(
            key: ValueKey('group-card-$_tab'),
            child: _content(),
          ),
        ],
      ),
    );
  }

  /// 顶部两导航：「群成员 ｜ 群管理」（默认群成员）。
  Widget _nav() {
    Widget item(int index, IconData icon, String label) {
      final active = _tab == index;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(AppDims.radiusS),
          onTap: () => setState(() => _tab = index),
          child: Container(
            height: AppDims.tabHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? AppColors.bgPrimary : Colors.transparent,
              borderRadius: BorderRadius.circular(AppDims.radiusS),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: AppDims.iconInline,
                    color:
                        active ? AppColors.primary : AppColors.textSecondary),
                const SizedBox(width: AppDims.space1),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                        color: active
                            ? AppColors.primary
                            : AppColors.textSecondary)),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        item(0, Icons.group_outlined, '群成员'),
        item(1, Icons.tune, '群管理'),
        if (widget.onOpenConversation != null)
          IconButton(
            tooltip: '进入群聊',
            iconSize: AppDims.iconInline,
            visualDensity: VisualDensity.compact,
            icon:
                const Icon(Icons.arrow_forward, color: AppColors.textSecondary),
            onPressed: () => widget.onOpenConversation!(widget.conversationId),
          ),
      ],
    );
  }

  Widget _content() {
    if (_tab == 1) {
      return GroupSettingsView(
        conversationId: widget.conversationId,
        group: widget.group,
        experts: widget.experts,
        conversations: widget.conversations,
        repos: widget.repos,
        compact: true,
      );
    }
    return GroupMemberList(
      conversationId: widget.conversationId,
      group: widget.group,
      experts: widget.experts,
      repos: widget.repos,
      compact: true,
    );
  }
}
