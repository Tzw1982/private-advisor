/// 右栏空态 / 引导通用组件（第 5 轮 UI 改版 · 架构设计文件清单）。
///
/// 右侧详情区无选中内容时显示（会话/通讯录等页签共用）；
/// 背景 = 二级背景 `#F7F8FA`（规格 §五 右栏底色）。
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dims.dart';

/// 右栏空态面板。
class EmptyPane extends StatelessWidget {
  const EmptyPane({
    super.key,
    this.icon = Icons.chat_bubble_outline,
    required this.title,
    this.hint,
  });

  /// 空态图标（线性风格，置灰）。
  final IconData icon;

  /// 空态标题（14/500）。
  final String title;

  /// 引导文案（12/400，可多行，居中）。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bgSecondary,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: AppColors.textTertiary),
          const SizedBox(height: AppDims.space3),
          Text(
            title,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary),
          ),
          if (hint != null) ...[
            const SizedBox(height: AppDims.space2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppDims.space6),
              child: Text(
                hint!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textTertiary, height: 1.8),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
