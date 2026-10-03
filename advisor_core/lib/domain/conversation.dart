/// Conversation 领域：单聊 / 群聊会话、成员、消息（V1.3 §5.2 / §8 / §9 / §11）。
library;

import 'common.dart';

/// 会话类型。
enum ConversationType {
  single('单聊'),
  group('群聊');

  const ConversationType(this.label);
  final String label;

  static ConversationType parse(String? v) => ConversationType.values
      .firstWhere((e) => e.name == v, orElse: () => ConversationType.single);
}

/// 会话。
class Conversation {
  const Conversation({
    required this.id,
    required this.type,
    this.title,
    this.pinned = false,
    this.lastMessageAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final ConversationType type;
  final String? title;
  final bool pinned;
  final int? lastMessageAt;
  final int createdAt;
  final int updatedAt;

  Conversation copyWith({
    String? title,
    bool? pinned,
    int? lastMessageAt,
    int? updatedAt,
  }) =>
      Conversation(
        id: id,
        type: type,
        title: title ?? this.title,
        pinned: pinned ?? this.pinned,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 会话成员角色。
///
/// 第 3 轮扩展 `leader`（组长，恰好 0 或 1 名）；`summarizer` 保留以兼容既有数据。
/// DDL 零改动（`conversation_members.role` 为 TEXT）。
enum MemberRole {
  member('成员'),
  leader('组长'),
  summarizer('总结者');

  const MemberRole(this.label);
  final String label;

  static MemberRole parse(String? v) => MemberRole.values
      .firstWhere((e) => e.name == v, orElse: () => MemberRole.member);
}

/// 会话成员（替代 V1.2 的 `member_ids[]`）。
class ConversationMember {
  const ConversationMember({
    required this.conversationId,
    required this.expertId,
    this.role = MemberRole.member,
    this.weight = 1.0,
    this.enabled = true,
    this.sortOrder = 0,
  });

  final String conversationId;
  final String expertId;
  final MemberRole role;

  /// 群聊发言权重（WeightedStrategy 使用）。
  final double weight;
  final bool enabled;
  final int sortOrder;

  ConversationMember copyWith({
    MemberRole? role,
    double? weight,
    bool? enabled,
    int? sortOrder,
  }) =>
      ConversationMember(
        conversationId: conversationId,
        expertId: expertId,
        role: role ?? this.role,
        weight: weight ?? this.weight,
        enabled: enabled ?? this.enabled,
        sortOrder: sortOrder ?? this.sortOrder,
      );
}

/// 消息发送方。
enum MessageSenderType {
  user('用户'),
  expert('专家'),
  system('系统');

  const MessageSenderType(this.label);
  final String label;

  static MessageSenderType parse(String? v) => MessageSenderType.values
      .firstWhere((e) => e.name == v, orElse: () => MessageSenderType.system);
}

/// 消息状态。
enum MessageStatus {
  queued('排队中'),
  streaming('生成中'),
  completed('完成'),
  cancelled('已取消'),
  failed('失败'),
  partial('部分完成');

  const MessageStatus(this.label);
  final String label;

  static MessageStatus parse(String? v) => MessageStatus.values
      .firstWhere((e) => e.name == v, orElse: () => MessageStatus.completed);
}

/// 消息。
class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.senderType,
    this.senderId,
    this.parentMessageId,
    required this.content,
    this.status = MessageStatus.completed,
    this.promptTokens,
    this.completionTokens,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String conversationId;
  final MessageSenderType senderType;

  /// 专家消息时为 expertId；用户消息时为 null。
  final String? senderId;

  /// 引用 / 回复的父消息。
  final String? parentMessageId;

  final String content;
  final MessageStatus status;
  final int? promptTokens;
  final int? completionTokens;
  final int createdAt;
  final int updatedAt;

  bool get isFromUser => senderType == MessageSenderType.user;
  bool get isFromExpert => senderType == MessageSenderType.expert;
  /// 该消息是否已停止变化（不可能再有新内容）——终态 = 完成 / 部分完成 / 已取消 / 失败。
  bool get isFinal =>
      status == MessageStatus.completed ||
      status == MessageStatus.partial ||
      status == MessageStatus.cancelled ||
      status == MessageStatus.failed;

  Message copyWith({
    String? content,
    MessageStatus? status,
    int? promptTokens,
    int? completionTokens,
    int? updatedAt,
  }) =>
      Message(
        id: id,
        conversationId: conversationId,
        senderType: senderType,
        senderId: senderId,
        parentMessageId: parentMessageId,
        content: content ?? this.content,
        status: status ?? this.status,
        promptTokens: promptTokens ?? this.promptTokens,
        completionTokens: completionTokens ?? this.completionTokens,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 新建一条用户消息。
  static Message user(String conversationId, String content, {int? now}) {
    final t = now ?? DateTime.now().millisecondsSinceEpoch;
    return Message(
      id: Ids.next('msg'),
      conversationId: conversationId,
      senderType: MessageSenderType.user,
      content: content,
      createdAt: t,
      updatedAt: t,
    );
  }

  /// 新建一条（流式中的）专家消息。
  static Message expert(
    String conversationId,
    String expertId, {
    String content = '',
    MessageStatus status = MessageStatus.streaming,
    String? parentMessageId,
    int? now,
  }) {
    final t = now ?? DateTime.now().millisecondsSinceEpoch;
    return Message(
      id: Ids.next('msg'),
      conversationId: conversationId,
      senderType: MessageSenderType.expert,
      senderId: expertId,
      parentMessageId: parentMessageId,
      content: content,
      status: status,
      createdAt: t,
      updatedAt: t,
    );
  }
}
