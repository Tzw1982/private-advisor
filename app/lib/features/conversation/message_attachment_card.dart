/// 消息附件卡片（第 8 轮 T04；规格 §4.3.3 / 裁定 7 / 待明确 1、2）。
///
/// 两类卡片：
/// - **图片缩略卡**：圆角 8、`Image.file`（`errorBuilder` → 回退文件图标，**不崩溃不留白**）、
///   点击 → [ImageViewer] 全屏放大（`InteractiveViewer`，[ImageFit] 二期预留本期只用默认）；
///   多图用 [Wrap] 排布；缩略边长取 **120px**（规格区间 96–160，本轮定值）。
/// - **文件卡片**：严格照规格 §4.3.3 —— `#F7F8FA` 背景、1px `#E5E7EB` 边框、圆角 8、
///   内边距 12、标题 13/500 一行、元信息 12/`#9CA3AF` **两行**、左侧图标 24×24。
///
/// 「打开文件」= **资源管理器定位**（`explorer /select,<path>`）；
/// 非 Windows / 失败 → **降级「路径已复制」**（`Clipboard.setData` + SnackBar）——
/// **禁止跨平台硬调 explorer**（共享约定 10）。
///
/// 视觉事实唯一来源：色值只从 [AppColors] / [AppDims] 取。
library;

import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'image_viewer.dart';

/// 图片缩略边长（规格区间 96–160，本实现定值）。
const double kAttachmentThumbSize = 120;

/// 消息附件卡片列表（图片 Wrap + 文件卡列表）。
class MessageAttachmentCards extends StatelessWidget {
  const MessageAttachmentCards({
    super.key,
    required this.attachments,
    this.onChanged,
  });

  final List<Attachment> attachments;

  /// 附件被移除 / 操作后回调（宿主可刷新）。
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    final images = attachments.where((a) => a.kind == AttachmentKind.image).toList();
    final files = attachments.where((a) => a.kind != AttachmentKind.image).toList();

    return Padding(
      // 与气泡内容之间留 8px（同一作者的多张卡也以 8px 间距排布）。
      padding: const EdgeInsets.only(top: AppDims.space2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (images.isNotEmpty)
            Wrap(
              spacing: AppDims.space2,
              runSpacing: AppDims.space2,
              children: [
                for (final a in images) _ImageAttachmentCard(attachment: a),
              ],
            ),
          for (final a in files) ...[
            const SizedBox(height: AppDims.space2),
            _FileAttachmentCard(attachment: a, onChanged: onChanged),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 图片缩略卡
// ---------------------------------------------------------------------------

class _ImageAttachmentCard extends StatelessWidget {
  const _ImageAttachmentCard({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final file = File(attachment.storedPath);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppDims.radiusM), // 圆角 8
      child: Material(
        color: AppColors.bgSecondary,
        child: InkWell(
          onTap: () => ImageViewer.show(
            context,
            path: attachment.storedPath,
            fileName: attachment.fileName,
          ),
          child: SizedBox(
            width: kAttachmentThumbSize,
            height: kAttachmentThumbSize,
            child: file.existsSync()
                ? Image.file(
                    file,
                    fit: BoxFit.cover,
                    // 损坏 / 不可读 → 回退文件图标；**不崩溃、不留白**。
                    errorBuilder: (_, __, ___) => _fallback(),
                  )
                : _fallback(),
          ),
        ),
      ),
    );
  }

  Widget _fallback() => ColoredBox(
        color: AppColors.bgTertiary,
        child: Center(
          child: Icon(AttachmentFileIcon.of(attachment.fileName),
              size: AppDims.iconLarge, color: AppColors.textTertiary),
        ),
      );
}

// ---------------------------------------------------------------------------
// 文件卡片（规格 §4.3.3）
// ---------------------------------------------------------------------------

class _FileAttachmentCard extends StatelessWidget {
  const _FileAttachmentCard({required this.attachment, this.onChanged});

  final Attachment attachment;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppDims.space3), // 内边距 12
      decoration: BoxDecoration(
        color: AppColors.bgSecondary, // #F7F8FA
        borderRadius: BorderRadius.circular(AppDims.radiusM), // 圆角 8
        border: Border.all(color: AppColors.divider), // 1px #E5E7EB
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 左侧图标 24×24
          Icon(AttachmentFileIcon.of(attachment.fileName),
              size: AppDims.iconLarge, color: AppColors.textSecondary),
          const SizedBox(width: AppDims.space3),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题 13/500 一行（13px 属组件规格特例，见第 5 轮冲突裁定 #3）
                Text(
                  attachment.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500, height: 1.4),
                ),
                // 元信息 12/#9CA3AF 两行
                Text(
                  AttachmentFileIcon.humanSize(attachment.sizeBytes),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textTertiary, height: 1.4),
                ),
                _OpenAction(
                  path: attachment.storedPath,
                  fileName: attachment.fileName,
                  onChanged: onChanged,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OpenAction extends StatelessWidget {
  const _OpenAction({
    required this.path,
    required this.fileName,
    this.onChanged,
  });

  final String path;
  final String fileName;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(0, 0),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () => AttachmentActions.locateFile(
        context,
        path: path,
        fileName: fileName,
        onChanged: onChanged,
      ),
      child: const Text('打开文件',
          style: TextStyle(fontSize: 12, color: AppColors.primary)),
    );
  }
}

// ---------------------------------------------------------------------------
// 图标 / 体积 / 平台动作
// ---------------------------------------------------------------------------

/// 附件文件图标映射（按扩展名）。
abstract final class AttachmentFileIcon {
  static IconData of(String fileName) {
    switch (fileName.trim().toLowerCase().split('.').last) {
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'doc':
      case 'docx':
        return Icons.article_outlined;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart_outlined;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow_outlined;
      case 'txt':
      case 'md':
        return Icons.description_outlined;
      case 'zip':
        return Icons.folder_zip_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  static String humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}

/// 平台相关附件动作（共享约定 10：禁止跨平台硬调 explorer）。
abstract final class AttachmentActions {
  /// 在资源管理器中定位文件。
  ///
  /// - Windows：`explorer /select,<path>`；
  /// - 非 Windows / 执行失败：**降级为「路径已复制」**（`Clipboard.setData` + SnackBar）。
  static Future<void> locateFile(
    BuildContext context, {
    required String path,
    required String fileName,
    VoidCallback? onChanged,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final exists = File(path).existsSync();
    if (!exists) {
      messenger.showSnackBar(const SnackBar(content: Text('文件不在原位置，可能已被移动或删除')));
      onChanged?.call();
      return;
    }
    if (!Platform.isWindows) {
      await _fallbackToClipboard(path, messenger, reason: '当前系统不支持直接定位');
      return;
    }
    try {
      final r = await Process.run('explorer', ['/select,${pNormalize(path)}']);
      if (r.exitCode == 0) return;
      await _fallbackToClipboard(path, messenger, reason: '定位失败');
    } catch (_) {
      await _fallbackToClipboard(path, messenger, reason: '定位失败');
    }
  }

  static Future<void> _fallbackToClipboard(
    String path,
    ScaffoldMessengerState messenger, {
    required String reason,
  }) async {
    await Clipboard.setData(ClipboardData(text: path));
    messenger.showSnackBar(SnackBar(content: Text('$reason，路径已复制：$path')));
  }

  /// 归一化路径分隔符（Windows explorer 需要反斜杠）。
  static String pNormalize(String path) => path.replaceAll('/', r'\');
}
