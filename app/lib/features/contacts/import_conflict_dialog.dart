/// 导入冲突决策对话框（规范 §8 / §10）。
///
/// 逐项列出冲突（原名称 + 冲突类型），每项三选：新建副本（推荐）/ 覆盖 / 跳过；
/// 顶部「应用到全部」一次性切换。无冲突时不弹本框（调用方保证）。
/// 返回 `item.key → ConflictStrategy`；取消返回 null。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';

/// 弹出冲突决策对话框。
Future<Map<String, ConflictStrategy>?> showImportConflictDialog(
  BuildContext context, {
  required List<ExpertImportItem> conflicts,
}) {
  return showDialog<Map<String, ConflictStrategy>>(
    context: context,
    builder: (ctx) {
      final decisions = <String, ConflictStrategy>{
        for (final c in conflicts) c.key: ConflictStrategy.newCopy,
      };
      return StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('冲突处理'),
          content: SizedBox(
            width: 500,
            height: 380,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('应用到全部：',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    const SizedBox(width: 8),
                    DropdownButton<ConflictStrategy>(
                      value: null,
                      hint: const Text('（选择）', style: TextStyle(fontSize: 12)),
                      items: [
                        for (final s in ConflictStrategy.values)
                          DropdownMenuItem(
                              value: s,
                              child: Text(s.label,
                                  style: const TextStyle(fontSize: 12))),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          for (final c in conflicts) {
                            decisions[c.key] = v;
                          }
                        });
                      },
                    ),
                  ],
                ),
                const Divider(height: 16),
                Expanded(
                  child: ListView.builder(
                    itemCount: conflicts.length,
                    itemBuilder: (_, i) {
                      final c = conflicts[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('「${c.displayName}」已存在',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500)),
                                  Text(c.conflict?.describe() ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textTertiary)),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            DropdownButton<ConflictStrategy>(
                              value: decisions[c.key],
                              items: [
                                for (final s in ConflictStrategy.values)
                                  DropdownMenuItem(
                                      value: s,
                                      child: Text(s.label,
                                          style: const TextStyle(fontSize: 12))),
                              ],
                              onChanged: (v) => setState(() =>
                                  decisions[c.key] =
                                      v ?? ConflictStrategy.newCopy),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(decisions),
              child: const Text('开始导入'),
            ),
          ],
        ),
      );
    },
  );
}
