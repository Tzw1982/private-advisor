/// 模型「支持视觉」开关（第 9 轮 · 图片多模态 · 设置入口）。
///
/// 背景：会话里的图片附件只有在模型档案 `supports_vision = true` 时才会
/// 随消息发给大模型（OpenAI content-parts）；未开启时发图会被 core 的
/// 视觉门控**明确拦下**（`provider.vision_unsupported`，不静默丢图），
/// 用户按错误提示来这里打开开关即可。
///
/// ⚠️ **挂载状态（重要，交接给 main.dart 归属方）**：
/// 应用现有的「设置」对话框（`SettingsDialog`，含默认 API Key + 默认模型
/// 下拉）实现在 `main.dart`，本轮改动边界**不含 main.dart**，故本文件先以
/// **自包含、可直接挂载**的组件交付。接入只需两步（都在 `main.dart`）：
///
/// 1. import：`import 'features/settings/model_vision_settings.dart';`
/// 2. 在 `_SettingsDialogState.build` 的 `content: SizedBox(... Column(children: [...]))`
///    中、默认模型下拉之后追加一个入口（二选一）：
///    ```dart
///    TextButton.icon(
///      onPressed: () => showModelVisionSettings(context,
///          repos: widget.boot.repos, providers: widget.boot.providers),
///      icon: const Icon(Icons.image_outlined),
///      label: const Text('模型视觉能力（图片识别）'),
///    ),
///    ```
///    或在 `_openSettings()` 里直接 `await showModelVisionSettings(context, ...)`。
///
/// 保存口径：逐条 `repos.providers.upsertModel(model.copyWith(supportsVision: v))`
/// （`ModelProfile.copyWith` 为第 9 轮新增；即时生效，无需重启）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';

/// 打开「模型视觉能力」设置对话框。
Future<void> showModelVisionSettings(
  BuildContext context, {
  required Repositories repos,
  required ProviderService providers,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ModelVisionSettingsDialog(repos: repos, providers: providers),
  );
}

/// 模型视觉能力设置对话框：列出全部模型档案，逐条切换「支持视觉」。
class ModelVisionSettingsDialog extends StatefulWidget {
  const ModelVisionSettingsDialog({
    super.key,
    required this.repos,
    required this.providers,
  });

  final Repositories repos;
  final ProviderService providers;

  @override
  State<ModelVisionSettingsDialog> createState() =>
      _ModelVisionSettingsDialogState();
}

class _ModelVisionSettingsDialogState extends State<ModelVisionSettingsDialog> {
  List<ModelProfile> _models = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final models = await widget.providers.listModels();
      if (!mounted) return;
      setState(() {
        _models = models;
        _loading = false;
        _error = null;
      });
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：${e.message}';
      });
    }
  }

  Future<void> _toggle(ModelProfile model, bool value) async {
    // 乐观更新：失败即回滚，并说明原因（不静默）。
    setState(() {
      _models = [
        for (final m in _models)
          m.id == model.id ? m.copyWith(supportsVision: value) : m,
      ];
    });
    try {
      await widget.repos.providers.upsertModel(
          model.copyWith(supportsVision: value));
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() {
        _models = [
          for (final m in _models)
            m.id == model.id ? m.copyWith(supportsVision: model.supportsVision) : m,
        ];
        _error = '保存失败：${e.message}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('模型视觉能力'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '开启后，会话中发送的图片会随消息一起送给该模型识别。\n'
              '未开启时发送图片会被明确拦截并提示——不会静默丢弃。\n'
              '单张图片上限 4MB（base64 会放大约 1/3，超出易被服务端拒绝）。',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Text(_error!,
                  style: const TextStyle(
                      color: AppColors.error, fontSize: 12))
            else if (_models.isEmpty)
              const Text('尚未配置任何模型档案。',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.textTertiary)),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final m in _models)
                    SwitchListTile(
                      value: m.supportsVision,
                      onChanged: (v) => _toggle(m, v),
                      title: Text(m.modelId),
                      subtitle: Text(
                        '${m.providerProfileId} · ${m.id}'
                        '${m.supportsVision ? '' : '（未开启）'}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      secondary: const Icon(Icons.image_outlined),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
