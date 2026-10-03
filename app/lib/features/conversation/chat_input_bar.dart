/// 会话输入栏（第 5 轮 B2 · 规格 §4.4；由 `conversation_view._inputBar()` 原样抽出）。
///
/// 结构（规格 §4.4 三条，逐字沿用）：
/// 1. **顶部工具栏 36px**：[📎 附件]（左1）· [@ 提及]（左2，仅群聊）+ 弹性空间；
/// 2. **输入区**：pending 附件条（四态）+ 多行输入框（Enter 发送 / Shift+Enter 换行，
///    键位挂在输入框自身 FocusNode 的 `onKeyEvent` 上，焦点节点由宿主持有）；
/// 3. **底部按钮栏**：发送按钮**右对齐**（微信「发送键在输入区下方右侧」）。
///
/// ⚠️ 发送按钮位于**底部按钮栏**是既定裁定（`Padding(top:12) + Row(mainAxisAlignment: End)`），
/// **不搬回顶部工具栏**；@ 插槽固定左 2（架构 §1.6 坐标约定）。
///
/// 本组件为**纯展示**：所有控制器 / 焦点 / 状态 / 回调均由宿主
/// （`conversation_view.dart`）传入并持有，内部零状态——Enter/Shift+Enter 发送逻辑、
/// @面板与键位、附件挑选/四态、删除菜单**一行未改**（随焦点节点与控制器留在宿主）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'attachment_bar.dart';
import 'mention_picker.dart';

/// 会话输入栏（无状态：状态与回调全部来自宿主）。
class ChatInputBar extends StatelessWidget {
  const ChatInputBar({
    super.key,
    required this.isGroup,
    required this.running,
    required this.sending,
    required this.onSend,
    required this.inputController,
    required this.inputFocus,
    required this.onPickAttachments,
    required this.onOpenMention,
    required this.pending,
    required this.onRemovePending,
    required this.onRetryPending,
    required this.mentionOpen,
    required this.mentionCandidates,
    required this.mentionSelectedIndex,
    required this.mentionFilterController,
    required this.mentionFilterFocus,
    required this.onMentionSelectedIndex,
    required this.onMentionConfirmed,
    required this.onMentionFilterChanged,
  });

  /// 是否群聊（决定 @ 插槽是否出现）。
  final bool isGroup;

  /// 生成中（禁发送、仍可输入；占位文案切换）。
  final bool running;

  /// 发送中（消息落库 + 附件阶段②）。
  final bool sending;

  /// 发送（宿主 `_send`）。
  final VoidCallback onSend;

  /// 主输入框控制器 / 焦点（宿主持有；焦点自带 `onKeyEvent`）。
  final TextEditingController inputController;
  final FocusNode inputFocus;

  /// 打开文件选择器（附件挑选）。
  final VoidCallback onPickAttachments;

  /// 从工具栏「@提及」按钮打开面板。
  final VoidCallback onOpenMention;

  /// pending 附件列表（四态）。
  final List<PendingAttachment> pending;

  /// 移除 / 重试 pending。
  final ValueChanged<PendingAttachment> onRemovePending;
  final ValueChanged<PendingAttachment> onRetryPending;

  /// @面板开关 / 候选 / 高亮下标 / 过滤框控制器与焦点 / 三回调。
  final bool mentionOpen;
  final List<MentionCandidate> mentionCandidates;
  final int mentionSelectedIndex;
  final TextEditingController mentionFilterController;
  final FocusNode mentionFilterFocus;
  final ValueChanged<int> onMentionSelectedIndex;
  final VoidCallback onMentionConfirmed;
  final ValueChanged<String> onMentionFilterChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppDims.space3, AppDims.space2, AppDims.space3, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // @成员候选面板（仅群聊；弹出于输入框上方）。
          if (mentionOpen)
            MentionPicker(
              candidates: mentionCandidates,
              selectedIndex:
                  mentionSelectedIndex >= 0 ? mentionSelectedIndex : 0,
              filterController: mentionFilterController,
              filterFocus: mentionFilterFocus,
              onSelectedIndex: onMentionSelectedIndex,
              onConfirmed: onMentionConfirmed,
              onFilterChanged: onMentionFilterChanged,
            ),
          // 顶部工具栏 36px（规格 §4.4）：
          // [📎 附件]（左1）[@ 提及]（左2，仅群聊）+ 弹性空间。
          // 注意：**发送按钮在底部按钮栏**（见本方法末尾），不放在工具栏——
          // 规格 §4.4 为「顶部工具栏(图标)/输入区/底部按钮栏」三条，且微信发送键在输入区下方右侧。
          // @ 插槽固定左 2（架构 §1.6 坐标约定，本轮不得占用）。
          SizedBox(
            height: AppDims.toolbarHeight,
            child: Row(
              children: [
                IconButton(
                  tooltip: '添加附件',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  iconSize: AppDims.iconNav,
                  icon: const Icon(Icons.attach_file,
                      size: AppDims.iconNav, color: AppColors.textSecondary),
                  onPressed: onPickAttachments,
                ),
                const SizedBox(width: AppDims.space1),
                if (isGroup)
                  IconButton(
                    tooltip: '提及成员',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                    iconSize: AppDims.iconNav,
                    icon: const Icon(Icons.alternate_email,
                        size: AppDims.iconNav, color: AppColors.textSecondary),
                    onPressed: onOpenMention,
                  ),
                // 弹性空间：把左侧图标留在最左（规格 §4.4 顶部工具栏只放图标）。
                const Spacer(),
              ],
            ),
          ),
          // pending 附件条（仅本轮：有 pending 时出现于工具栏下方；四态）。
          AttachmentBar(
            items: pending,
            onRemove: onRemovePending,
            onRetry: onRetryPending,
          ),
          TextField(
            // 焦点节点自带 onKeyEvent（Enter 发送 / Shift+Enter 换行）。
            focusNode: inputFocus,
            controller: inputController,
            // 生成中仍可继续输入（微信逻辑）：只禁发送，不禁打字。
            enabled: true,
            minLines: 1,
            maxLines: 4,
            // 不再依赖 textInputAction（Windows 桌面语义混乱，已删除）；
            // 换行由宿主 `_onInputKeyEvent` 手动插入。
            decoration: InputDecoration(
              hintText: running
                  ? '专家正在回应…'
                  : '输入消息（Enter 发送，Shift+Enter 换行；群聊可 @ 成员）',
              isDense: true,
              border: const OutlineInputBorder(),
              // 规格 §4.4：输入框边框色（三级背景）+ 圆角 8；色值只从 AppColors/AppDims 取。
              enabledBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: AppColors.bgTertiary),
                borderRadius:
                    BorderRadius.all(Radius.circular(AppDims.radiusM)),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: AppColors.bgTertiary),
                borderRadius:
                    BorderRadius.all(Radius.circular(AppDims.radiusM)),
              ),
            ),
          ),
          // 底部按钮栏（规格 §4.4：输入区底部距离按钮栏 12px；发送按钮右对齐，
          // 与微信"发送键在输入区下方右侧"一致）。视觉逐字沿用 §4.4。
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: running || sending
                        ? AppColors.sendDisabled
                        : AppColors.primary,
                  ),
                  onPressed: running || sending ? null : onSend,
                  child: Text(sending ? '发送中' : '发送'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
