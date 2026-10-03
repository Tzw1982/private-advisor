/// 群成员管理面板（群聊会话 → 头部「群成员」按钮打开的对话框）。
///
/// **第 6 轮 T03 重构**：成员列表逻辑抽取为共享组件 [GroupMemberList]
/// （`group_member_list.dart`），本文件退化为**对话框宿主**——与中栏内联
/// 群卡片的「群成员」页签**共用同一实现**，避免两份逻辑漂移。
///
/// 交互规则（PRD §6.1.5 / §6.5）见 [GroupMemberList] 文档。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import 'group_member_list.dart';

/// 群成员管理对话框（宿主）。
class GroupMembersPanel extends StatelessWidget {
  const GroupMembersPanel({
    super.key,
    required this.conversationId,
    required this.group,
    required this.experts,
    required this.repos,
  });

  final String conversationId;
  final GroupService group;
  final ExpertService experts;
  final Repositories repos;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('群成员'),
      content: SizedBox(
        width: 420,
        // 成员多时对话框内可滚动（避免超出弹窗高度溢出）。
        child: SingleChildScrollView(
          child: GroupMemberList(
            conversationId: conversationId,
            group: group,
            experts: experts,
            repos: repos,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
