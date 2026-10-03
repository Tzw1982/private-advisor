/// 导出选项对话框（规范 §10）。
///
/// 两项独立勾选，**均默认不勾**（规范待明确 #1 / #3 的倾向）：
/// - 「包含本机设置」：模型 / 知识库绑定 / 备注（写入 `profile.json`）；
/// - 「包含头像图片」：`assets/avatar.png`。
///
/// 明文 API Key **永不导出**，此处文案已作明确告知。
library;

import 'package:flutter/material.dart';

/// 导出选项。
class ExportOptions {
  const ExportOptions({
    required this.includeLocal,
    required this.includeAvatar,
  });

  /// 是否携带档案层（本机设置）。
  final bool includeLocal;

  /// 是否携带头像图片。
  final bool includeAvatar;
}

/// 弹出导出选项对话框；取消返回 null。
Future<ExportOptions?> showExportOptionsDialog(
  BuildContext context, {
  required int count,
}) {
  return showDialog<ExportOptions>(
    context: context,
    builder: (ctx) {
      var includeLocal = false;
      var includeAvatar = false;
      return StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('导出 $count 位专家'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('选择导出内容：',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 4),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: includeLocal,
                  onChanged: (v) => setState(() => includeLocal = v ?? false),
                  title: const Text('包含本机设置（模型 / 知识库绑定 / 备注）',
                      style: TextStyle(fontSize: 13)),
                  subtitle: const Text('默认不勾选：仅导出专家本体，可直接回流市场',
                      style: TextStyle(fontSize: 11)),
                ),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: includeAvatar,
                  onChanged: (v) => setState(() => includeAvatar = v ?? false),
                  title: const Text('包含头像图片',
                      style: TextStyle(fontSize: 13)),
                  subtitle: const Text('默认不勾选：图片体积较大',
                      style: TextStyle(fontSize: 11)),
                ),
                const SizedBox(height: 4),
                const Text('明文 API Key 永不导出，只保留凭据引用名。',
                    style: TextStyle(fontSize: 11, color: Colors.black54)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ExportOptions(
                includeLocal: includeLocal,
                includeAvatar: includeAvatar,
              )),
              child: const Text('下一步'),
            ),
          ],
        ),
      );
    },
  );
}
