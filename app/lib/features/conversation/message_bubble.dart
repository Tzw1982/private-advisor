/// 会话消息气泡（第 5 轮 B2 · 规格 §4.3.2）。
///
/// 两类气泡 + 时间分割线，视觉事实全部取 [AppColors] / [AppDims] / [ExpertAvatar]：
/// - **专家消息**（左对齐）：头像 32×32 圆角 12 在左侧间距 8；上方专家姓名
///   12/[AppColors.textSecondary]；白气泡（[AppColors.bgPrimary]、圆角 8、
///   内边距 10×12、文字 14/[AppColors.textPrimary] 行高 1.6）；
/// - **用户消息**（右对齐）：[AppColors.userBubble] 微信绿气泡、头像在右侧间距 8；
/// - **时间分割线**：居中 11/[AppColors.textTertiary]、上下间距 16。
///
/// 宽度纪律：**最大宽度 = LayoutBuilder 取内容区 70%**（替换早期固定 480/520）；
/// 消息间距：**不同人 16、同一人连续 8**（按上一条 senderType/senderId 判断，
/// 由调用方以 [MessageBubble.continuousWithPrevious] 传入）。
///
/// 失败态（`status == MessageStatus.failed`）：沿用既有「生成失败：…」提示框
/// （错误图标 + 红字 + 已生成部分内容），**绝不渲染成空白气泡**；底色/边框由
/// [AppColors.error] 派生（`withValues` 低透明度），不写裸 `Color(0x…)`
/// （与 `contacts/create_expert_dialog.dart` 的错误提示底色同款做法）。
///
/// 静默契约（`cancelled && 正文空` → 不出气泡、只出极淡系统行）**不在本组件内**，
/// 由 `conversation_view.dart` 在分派前处理（第 6 轮原样保留）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import '../../ui/widgets/expert_avatar.dart';
import 'citation_card.dart';
import 'message_attachment_card.dart';

/// 气泡内容区最大宽度占比（规格 §4.3.2：LayoutBuilder 取内容区 **70%**）。
const double kBubbleMaxWidthRatio = 0.7;

/// 气泡纵向内边距（规格 §4.3.2：内边距 **10×12**；AppDims 无 10 刻度，
/// 规格值集中定义于本文件便于走查核对，同 `mention_picker` 的 `_panelMaxHeight` 先例）。
const double kBubblePaddingV = 10;

/// 相邻消息超过该间隔 → 插入时间分割线（微信口径 5 分钟）。
const int kTimeDividerGapMs = 5 * 60 * 1000;

/// 聊天时间戳格式：当天 → `HH:mm`；更早 → `M月d日 HH:mm`（微信口径）。
String formatChatTimestamp(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  final sameDay =
      dt.year == now.year && dt.month == now.month && dt.day == now.day;
  if (sameDay) return '$hh:$mm';
  return '${dt.month}月${dt.day}日 $hh:$mm';
}

/// 时间分割线（居中、11/[AppColors.textTertiary]、上下间距 16）。
class TimeDivider extends StatelessWidget {
  const TimeDivider({super.key, required this.timestamp});

  /// 消息时间戳（毫秒 epoch）。
  final int timestamp;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDims.space4),
      child: Center(
        child: Text(
          formatChatTimestamp(timestamp),
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
      ),
    );
  }
}

/// 消息气泡（专家 / 用户；含失败态与引用卡挂载点）。
///
/// 本组件只负责「渲染」：状态、附件、引用、手势回调全部由调用方传入，
/// 不在内部持有任何状态（`conversation_view.dart` 仍是唯一状态源）。
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.isFromUser,
    required this.content,
    this.expertId,
    this.expertName,
    this.avatarEmoji,
    this.avatarColor,
    this.status = MessageStatus.completed,
    this.attachments = const [],
    this.citations = const [],
    this.footer,
    this.onLongPress,
    this.onSecondaryTap,
    this.onAttachmentsChanged,
    this.continuousWithPrevious = false,
  });

  /// 是否用户消息（决定对齐、底色、头像侧）。
  final bool isFromUser;

  /// 消息正文（专家流式气泡传流式缓冲文本）。
  final String content;

  /// 专家消息的 expertId（头像数据源；用户消息为 null）。
  final String? expertId;

  /// 专家展示名（备注优先；由调用方从 `_names` 解析后传入）。
  final String? expertName;

  /// 市场包自带 emoji 头像（第 #66 轮；可为 null → 回退首字）。
  final String? avatarEmoji;

  /// emoji 底色（市场包 `color`；可为 null → 回退确定性色板）。
  final String? avatarColor;

  /// 消息状态（失败态渲染失败提示框；已取消非空消息置灰斜体）。
  final MessageStatus status;

  /// 用户消息的附件（图片缩略 Wrap + 文件卡）。
  final List<Attachment> attachments;

  /// 专家消息的知识库引用（§4.3.3 引用卡；`_reload` 时按 messageId 补拉）。
  final List<Citation> citations;

  /// 气泡下方附加行（如流式完成时的「引用 N 条 / 未作答」提示）。
  final Widget? footer;

  /// 长按 / 右键手势（仅用户消息的删除菜单入口）。
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  /// 附件卡内「打开文件」失败后的刷新回调。
  final VoidCallback? onAttachmentsChanged;

  /// 与上一条消息同一人（senderType/senderId 均同）→ 间距 8；否则 16。
  final bool continuousWithPrevious;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth * kBubbleMaxWidthRatio
            : double.infinity;
        return Align(
          alignment: isFromUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            // 左右留 16；上下按连续性 8（同一人连续）/ 16（不同人）。
            padding: EdgeInsets.symmetric(
              horizontal: AppDims.space4,
              vertical:
                  continuousWithPrevious ? AppDims.space1 : AppDims.space2,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: isFromUser ? _userMessage() : _expertMessage(),
            ),
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // 用户消息（右对齐 · 微信绿 · 头像在右）
  // -------------------------------------------------------------------------

  Widget _userMessage() {
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppDims.space3, vertical: kBubblePaddingV),
            decoration: BoxDecoration(
              // 规格 §1.1：用户气泡色（唯一用途 = 当前用户消息气泡背景）。
              color: AppColors.userBubble,
              borderRadius: BorderRadius.circular(AppDims.radiusM),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 附件卡（图片缩略 Wrap + 文件卡）在气泡内、正文之上。
                MessageAttachmentCards(
                  attachments: attachments,
                  onChanged: onAttachmentsChanged,
                ),
                if (content.trim().isNotEmpty)
                  SelectableText(
                    content,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: AppColors.textPrimary,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppDims.space2),
        // 用户头像：无用户资料图，用「人形线性图标 + 二级背景」占位（同侧右置）。
        const _UserAvatar(),
      ],
    );
    if (onLongPress == null && onSecondaryTap == null) return row;
    // 长按 / 右键 → 消息菜单（仅用户自己的消息；专家消息不传手势）。
    return GestureDetector(
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap,
      child: row,
    );
  }

  // -------------------------------------------------------------------------
  // 专家消息（左对齐 · 白底 · 头像 + 姓名在左）
  // -------------------------------------------------------------------------

  Widget _expertMessage() {
    final name = expertName ?? expertId ?? '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExpertAvatar(
          expertId: expertId ?? '',
          name: name,
          // 图片优先；无图看 emoji；都无才回退 AvatarPalette 确定性底色 + 首字。
          avatarEmoji: avatarEmoji,
          avatarColor: avatarColor,
          radius: AppDims.avatarBubble / 2,
          borderRadius: BorderRadius.circular(AppDims.radiusL),
          // 图片优先；缺失回退 AvatarPalette 确定性底色 + 首字（白字）。
          seed: expertId,
          fontSize: 13,
        ),
        const SizedBox(width: AppDims.space2),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppDims.space1),
              if (status == MessageStatus.failed)
                _failedBubble()
              else
                _expertBubble(),
              if (citations.isNotEmpty) ...[
                const SizedBox(height: AppDims.space2),
                CitationCards(citations: citations),
              ],
              if (footer != null) footer!,
            ],
          ),
        ),
      ],
    );
  }

  Widget _expertBubble() {
    final cancelled = status == MessageStatus.cancelled;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppDims.space3, vertical: kBubblePaddingV),
      decoration: BoxDecoration(
        // 规格 §4.3.2：专家气泡白底（bgPrimary）；聊天区同为白底，
        // 保留 1px bgTertiary 描边以保证气泡可辨（既有口径）。
        color: AppColors.bgPrimary,
        borderRadius: BorderRadius.circular(AppDims.radiusM),
        border: Border.all(color: AppColors.bgTertiary),
      ),
      child: SelectableText(
        content.isEmpty ? '…' : content,
        style: TextStyle(
          fontSize: 14,
          height: 1.6,
          // 已取消（有正文）：置灰 + 斜体（第 6 轮口径）。
          color: cancelled ? AppColors.textTertiary : AppColors.textPrimary,
          fontStyle: cancelled ? FontStyle.italic : null,
        ),
      ),
    );
  }

  /// 失败态提示框：错误图标 + 红字（正文空 → 明确文案；非空 → 已生成部分内容）。
  Widget _failedBubble() {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppDims.space3, vertical: kBubblePaddingV),
      decoration: BoxDecoration(
        // 由 AppColors.error 派生的浅色底 / 描边（不写裸 Color(0x…)）。
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppDims.radiusM),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 14, color: AppColors.error),
          const SizedBox(width: 6),
          Flexible(
            child: SelectableText(
              content.trim().isEmpty
                  ? '生成失败（未产出内容），请检查模型与 API Key 后重试。'
                  : '生成失败，以下为已生成的部分内容：\n$content',
              style: const TextStyle(
                  fontSize: 13, height: 1.5, color: AppColors.error),
            ),
          ),
        ],
      ),
    );
  }
}

/// 用户头像（32×32 圆角 12；无用户资料图 → 人形线性图标占位）。
class _UserAvatar extends StatelessWidget {
  const _UserAvatar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppDims.avatarBubble,
      height: AppDims.avatarBubble,
      decoration: BoxDecoration(
        color: AppColors.bgSecondary,
        borderRadius: BorderRadius.circular(AppDims.radiusL),
        border: Border.all(color: AppColors.divider),
      ),
      alignment: Alignment.center,
      child: const Icon(Icons.person_outline,
          size: AppDims.iconNav, color: AppColors.textSecondary),
    );
  }
}
