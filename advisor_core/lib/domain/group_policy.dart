/// 组长 / 组员约束（第 3 轮 · PRD §6.1.4 / §6.1.5，纯策略）。
///
/// 规则（架构设计 §3.6，写死）：
/// - 恰好 0 或 1 名组长：`>1` → 校验报错；提升新组长时**自动把旧组长降为 member**；
/// - 最少 1 名成员：删到 0 → 拒绝并返回提示；
/// - 删组长 → 允许，进入「无组长」态（不强制补选）；
/// - 默认总结者：`summarizerExpertId ?? 组长`。
///
/// DDL **零改动**：`conversation_members.role` 为 TEXT，仅扩展 Dart 侧 [MemberRole] 枚举。
library;

import 'common.dart';
import 'conversation.dart';

/// 成员移除结果。
class MemberRemovalResult {
  const MemberRemovalResult({
    required this.applied,
    required this.members,
    this.message,
  });

  /// 是否真的移除了（false = 被策略拒绝，[members] 为原集合）。
  final bool applied;

  /// 移除后的成员集合（拒绝时为原集合）。
  final List<ConversationMember> members;

  /// 面向用户的提示（拒绝原因 / 删组长提示）；无需提示时为 null。
  final String? message;
}

/// 组长 / 组员纯策略。
abstract final class GroupRolePolicy {
  /// 当前组长 expertId（无则 null）。
  static String? leaderId(List<ConversationMember> members) {
    for (final m in members) {
      if (m.role == MemberRole.leader) return m.expertId;
    }
    return null;
  }

  /// 校验成员集合：>1 名组长 → 返回错误信息；合法 → null。
  static String? validateMembers(List<ConversationMember> members) {
    final leaders = members.where((m) => m.role == MemberRole.leader).length;
    if (leaders > 1) {
      return '群聊最多只能有 1 名组长（当前 $leaders 名）';
    }
    return null;
  }

  /// 提升 [expertId] 为组长：把任何其它组长**自动降为 member**。
  ///
  /// [expertId] 不在集合中 → 抛 [ValidationError]。
  static List<ConversationMember> promoteToLeader(
    List<ConversationMember> members,
    String expertId,
  ) {
    if (!members.any((m) => m.expertId == expertId)) {
      throw ValidationError('group.member_missing', '成员不在群聊中：$expertId');
    }
    return members
        .map((m) => m.expertId == expertId
            ? m.copyWith(role: MemberRole.leader)
            : (m.role == MemberRole.leader ? m.copyWith(role: MemberRole.member) : m))
        .toList();
  }

  /// 移除成员（含边界处理）。
  ///
  /// - 删到 0 → 拒绝，`applied=false`，[MemberRemovalResult.message] 为提示；
  /// - 删除组长 → 允许，返回提示「已移除组长…」；
  /// - 其余 → 允许，无提示。
  static MemberRemovalResult removeMember(
    List<ConversationMember> members,
    String expertId,
  ) {
    if (members.length <= 1) {
      return MemberRemovalResult(
        applied: false,
        members: members,
        message: '群聊至少保留 1 名成员',
      );
    }
    final target = members.where((m) => m.expertId == expertId).toList();
    if (target.isEmpty) {
      return MemberRemovalResult(applied: false, members: members, message: '成员不在群聊中：$expertId');
    }
    final wasLeader = target.first.role == MemberRole.leader;
    final next = members.where((m) => m.expertId != expertId).toList();
    return MemberRemovalResult(
      applied: true,
      members: next,
      message: wasLeader ? '已移除组长，当前群聊处于无组长状态' : null,
    );
  }

  /// 默认总结者：配置的 `summarizerExpertId` 优先，否则回退到当前组长。
  static String? effectiveSummarizerId(
    String? configuredSummarizerId,
    List<ConversationMember> members,
  ) {
    if (configuredSummarizerId != null && configuredSummarizerId.trim().isNotEmpty) {
      return configuredSummarizerId;
    }
    return leaderId(members);
  }
}
