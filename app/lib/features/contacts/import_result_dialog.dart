/// 导入结果报告对话框（规范 §9 / §10）。
///
/// 汇总「新增 N / 覆盖 M / 跳过 K / 失败 J」+ 逐条明细（含失败步骤与原因原文、
/// 引用回落提示），落实「结果必须逐条可见」。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';

/// 弹出导入结果对话框。
Future<void> showImportResultDialog(
  BuildContext context, {
  required ExpertImportReport report,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('导入完成'),
      content: SizedBox(
        width: 540,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(report.summary(),
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
              '成功 ${report.success}（新增 ${report.added} / 覆盖 ${report.overwritten}）'
              '，跳过 ${report.skipped}，失败 ${report.failed}',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary),
            ),
            const Divider(height: 16),
            const Text('明细：',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(height: 4),
            Expanded(
              child: ListView.builder(
                itemCount: report.results.length,
                itemBuilder: (_, i) {
                  final r = report.results[i];
                  final line = StringBuffer()
                    ..write('· [${r.outcome.label}] ${r.displayName}');
                  if ((r.reason ?? '').isNotEmpty) {
                    line.write('（${r.reason}）');
                  }
                  for (final n in r.notes) {
                    line.write('\n    · $n');
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      line.toString(),
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: r.outcome == ImportOutcome.failed
                            ? AppColors.error
                            : AppColors.textPrimary,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
