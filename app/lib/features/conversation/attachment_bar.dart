/// pending 附件条（第 8 轮 T04；架构 §1 裁定 8：四态）。
///
/// 位于输入框**工具栏下方**（架构 §1.6 坐标约定），仅在有 pending 时出现：
/// ┌ 上传中（spinner）/ 失败（红字原因 + 重试）/ 超限（拒绝 + 明确报错）/ 可移除（✕）┐
///
/// **四态语义**（`PendingAttachmentStatus`）：
/// - `ready`：通过校验，等待发送 → 显示文件名 + 大小 + ✕ 可移除；
/// - `uploading`：正在 save + insert → spinner 替代 ✕（禁止移除半路文件）；
/// - `failed`：校验之外的 IO 失败 → 红字原因 + **重试** + ✕；
/// - `rejected`：选择阶段即被拒（超限 / 类型不符）→ 红字原因，**不静默**。
///
/// 「取消」（从输入框移除）不是状态，而是从列表移除该对象——**不预复制**
/// （共享约定 11），故移除即"什么都没发生过"。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';

/// pending 附件条。
class AttachmentBar extends StatelessWidget {
  const AttachmentBar({
    super.key,
    required this.items,
    required this.onRemove,
    this.onRetry,
  });

  /// pending 列表（含四态）。
  final List<PendingAttachment> items;

  /// 移除某条 pending（"取消"）。
  final ValueChanged<PendingAttachment> onRemove;

  /// 重试（仅 `failed` 态可用）。
  final ValueChanged<PendingAttachment>? onRetry;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: AppDims.space2),
      padding: const EdgeInsets.all(AppDims.space2),
      decoration: BoxDecoration(
        color: AppColors.bgSecondary,
        borderRadius: BorderRadius.circular(AppDims.radiusM),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.attach_file,
                  size: AppDims.iconInline, color: AppColors.textSecondary),
              const SizedBox(width: AppDims.space1),
              Text('待发送附件（${items.length}）',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: AppDims.space1),
          for (final it in items) _row(it),
        ],
      ),
    );
  }

  Widget _row(PendingAttachment it) {
    final failed = it.status == PendingAttachmentStatus.failed ||
        it.status == PendingAttachmentStatus.rejected;
    final uploading = it.status == PendingAttachmentStatus.uploading;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: AppDims.iconInline,
            height: AppDims.iconInline,
            child: uploading
                ? const CircularProgressIndicator(strokeWidth: 1.5)
                : Icon(
                    it.kind == AttachmentKind.image
                        ? Icons.image_outlined
                        : Icons.insert_drive_file_outlined,
                    size: AppDims.iconInline,
                    color: failed ? AppColors.error : AppColors.textSecondary,
                  ),
          ),
          const SizedBox(width: AppDims.space2),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  it.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: failed ? AppColors.error : AppColors.textPrimary,
                  ),
                ),
                Text(
                  (it.error == null)
                      ? _meta(it)
                      : it.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: failed ? AppColors.error : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          if (it.canRetry && onRetry != null)
            TextButton(
              onPressed: () => onRetry!(it),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: AppDims.space1),
                minimumSize: const Size(0, 0),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重试', style: TextStyle(fontSize: 12)),
            ),
          if (it.canRemove)
            IconButton(
              tooltip: '移除',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              iconSize: AppDims.iconInline,
              icon: const Icon(Icons.close, color: AppColors.textTertiary),
              onPressed: () => onRemove(it),
            ),
        ],
      ),
    );
  }

  String _meta(PendingAttachment it) {
    final size = AttachmentSizeFormat.human(it.sizeBytes);
    return '$size · ${it.kind.label}';
  }
}

/// 体积格式化（与消息卡一致口径）。
abstract final class AttachmentSizeFormat {
  static String human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}
