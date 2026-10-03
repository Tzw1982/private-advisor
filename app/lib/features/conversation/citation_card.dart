/// 知识库引用卡片（第 5 轮 B2 · 规格 §4.3.3）。
///
/// 渲染消息的知识库引用（[Citation]，core `domain/knowledge.dart`）：
/// - 背景 [AppColors.bgSecondary]、圆角 8（[AppDims.radiusM]）、
///   1px [AppColors.divider] 边框、内边距 12（[AppDims.space3]）；
/// - 标题 = 文档文件名，13/500/[AppColors.textPrimary] 最多一行 ellipsis
///   （13px 属组件规格特例，见第 5 轮冲突裁定 #3）；
/// - 描述 = 引用片段（`Citation.text`），12/[AppColors.textTertiary] 最多两行；
/// - 元信息 = 来源位置（章节 > 页码 > 工作表/区域）+ 相关度，12 浅灰一行；
/// - 左侧文件图标 **24×24**（按扩展名取 [AttachmentFileIcon]），
///   与右侧文字间距 **10**（规格值，AppDims 无该刻度，集中定义于本文件）。
///
/// 数据源（第 5 轮架构 §1.5 已确认）：`MessageRepository.listCitations(messageId)`
/// 端口已存在——历史消息由 `conversation_view._reload` 按 messageId 补拉后传入，
/// **core/storage 零改动**。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'message_attachment_card.dart';

/// 引用卡文件图标与右侧文字的间距（规格 §4.3.3：10；AppDims 无该刻度）。
const double kCitationIconGap = 10;

/// 同一消息的引用卡列表（多条引用纵向排布，间距 8；空 → 不占位）。
class CitationCards extends StatelessWidget {
  const CitationCards({super.key, required this.citations});

  /// 引用列表（按检索相关度序，由 core 保证）。
  final List<Citation> citations;

  @override
  Widget build(BuildContext context) {
    if (citations.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < citations.length; i++) ...[
          if (i > 0) const SizedBox(height: AppDims.space2),
          CitationCard(citation: citations[i]),
        ],
      ],
    );
  }
}

/// 单条引用卡（规格 §4.3.3）。
class CitationCard extends StatelessWidget {
  const CitationCard({super.key, required this.citation});

  final Citation citation;

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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧文件图标 24×24（按扩展名）。
          Icon(
            AttachmentFileIcon.of(citation.fileName),
            size: AppDims.iconLarge,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: kCitationIconGap),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题 13/500 一行（文件名）。
                Text(
                  citation.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                    color: AppColors.textPrimary,
                  ),
                ),
                // 描述：引用片段 12/浅灰 两行。
                if (citation.text.trim().isNotEmpty) ...[
                  const SizedBox(height: AppDims.space1),
                  Text(
                    citation.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
                // 元信息：来源位置 + 相关度 12 浅灰一行。
                Padding(
                  padding: const EdgeInsets.only(top: AppDims.space1),
                  child: Text(
                    _meta(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 来源元信息：位置（章节 > 页码 > 工作表/区域）+ 相关度。
  String _meta() {
    final parts = <String>[];
    final heading = citation.headingPath?.trim() ?? '';
    if (heading.isNotEmpty) {
      parts.add(heading);
    } else if (citation.page != null) {
      parts.add('第 ${citation.page} 页');
    }
    final sheet = citation.sheet?.trim() ?? '';
    if (sheet.isNotEmpty) parts.add('工作表：$sheet');
    final range = citation.cellRange?.trim() ?? '';
    if (range.isNotEmpty) parts.add('区域：$range');
    final score = '相关度 ${citation.score.toStringAsFixed(2)}';
    return parts.isEmpty ? score : '${parts.join(' · ')} · $score';
  }
}
