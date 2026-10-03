/// 大模型管理（用户走查反馈 #15-B：设置栏大模型可设置多个 + 全局默认）。
///
/// 能力范围（MVP）：
/// - **列出全部已登记模型**（按 provider 分组）：`modelId`（加粗）+ provider
///   显示名 + 上下文长度（未标注时明示）+ 视觉支持图标 + 「默认」标签；
///   「设为默认」经 `ProviderService.setDefaultModel` 即时生效。
/// - **＋ 添加模型**：注册自定义 OpenAI 兼容端点——三件套一次落齐：
///   `ProviderProfile`（providerId='custom'）→ 凭据（`CredentialService
///   .saveForProvider`，id 取 `cred_<providerProfileId>`，与默认单例
///   `cred_default` 并存）→ `ModelProfile`。写入 `repos.providers`。
/// - **暂不提供删除**：仓储端口（`ProviderRepository`）没有 deleteProvider /
///   deleteModel，本任务不改端口；内置模型与已登记自定义模型都不可删，
///   入口处明示，避免用户误以为能清理。
///
/// 语义说明：新增专家默认用全局默认模型，每个专家仍可单独覆盖（与「默认
/// API Key」同款口径）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';

/// 打开「大模型管理」对话框。
Future<void> showModelManager(
  BuildContext context, {
  required Repositories repos,
  required ProviderService providers,
  required CredentialService credentials,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ModelManagerDialog(
      repos: repos,
      providers: providers,
      credentials: credentials,
    ),
  );
}

/// 大模型管理对话框：模型列表（按 provider 分组）+ 设为默认 + 添加自定义模型。
class ModelManagerDialog extends StatefulWidget {
  const ModelManagerDialog({
    super.key,
    required this.repos,
    required this.providers,
    required this.credentials,
  });

  final Repositories repos;
  final ProviderService providers;
  final CredentialService credentials;

  @override
  State<ModelManagerDialog> createState() => _ModelManagerDialogState();
}

class _ModelManagerDialogState extends State<ModelManagerDialog> {
  List<ProviderProfile> _providers = const [];
  List<ModelProfile> _models = const [];
  String? _defaultModelId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final providers = await widget.providers.listProviders();
      final models = await widget.providers.listModels();
      final def = await widget.providers.defaultModelProfileId;
      if (!mounted) return;
      setState(() {
        _providers = providers;
        _models = models;
        _defaultModelId = def;
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

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 设为全局默认（即时生效——`defaultModelProfileId` 设置键）。
  Future<void> _setDefault(ModelProfile m) async {
    try {
      await widget.providers.setDefaultModel(m.id);
      if (!mounted) return;
      setState(() => _defaultModelId = m.id);
      _snack('已设为默认模型：${m.modelId}');
    } on AppError catch (e) {
      if (!mounted) return;
      _snack('设置失败：${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('大模型管理'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '可注册多个模型（含自定义 OpenAI 兼容端点），其中一个是全局默认；\n'
              '新增专家默认用全局默认模型，每个专家仍可单独覆盖。\n'
              '内置模型与已登记自定义模型暂不支持删除，可在后续版本清理。',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Text(_error!,
                  style:
                      const TextStyle(color: AppColors.error, fontSize: 12))
            else if (_models.isEmpty)
              const Text('尚未配置任何模型档案，点右下角「添加模型」登记第一个。',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.textTertiary))
            else
              Flexible(
                child: ListView(shrinkWrap: true, children: _modelRows()),
              ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _showAddDialog,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加模型'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// 模型列表行：按 provider 分组（显示名为小节头），孤儿模型兜底直铺。
  List<Widget> _modelRows() {
    final rows = <Widget>[];
    void addProviderSection(ProviderProfile? provider,
        List<ModelProfile> models) {
      if (models.isEmpty) return;
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text(
          provider?.displayName ?? '未知 provider',
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: AppColors.textSecondary),
        ),
      ));
      for (final m in models) {
        rows.add(_modelTile(provider, m));
      }
    }

    for (final p in _providers) {
      addProviderSection(
          p, _models.where((m) => m.providerProfileId == p.id).toList());
    }
    // 兜底：provider 档案缺失的模型（数据异常时也可见，不静默丢）。
    addProviderSection(
        null,
        _models
            .where((m) =>
                !_providers.any((p) => p.id == m.providerProfileId))
            .toList());
    return rows;
  }

  Widget _modelTile(ProviderProfile? provider, ModelProfile m) {
    final providerName = provider?.displayName ?? m.providerProfileId;
    final isDefault = m.id == _defaultModelId;
    final ctx = m.contextWindow;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: m.supportsVision
          ? const Icon(Icons.visibility_outlined,
              size: 18, color: AppColors.textTertiary)
          : null,
      title: Text(m.modelId,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '$providerName · 上下文${ctx == null ? '未标注' : ' $ctx tokens'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isDefault)
            Container(
              margin: const EdgeInsets.only(right: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('默认',
                  style: TextStyle(fontSize: 10, color: AppColors.primary)),
            ),
          TextButton(
            onPressed: isDefault ? null : () => _setDefault(m),
            child: const Text('设为默认'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 添加自定义模型（表单对话框）
  // -------------------------------------------------------------------------

  Future<void> _showAddDialog() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    final modelCtrl = TextEditingController();
    final ctxCtrl = TextEditingController();
    var vision = false;
    String? formError;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('添加自定义模型'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '支持任意 OpenAI 兼容端点（/chat/completions）。\n'
                    'API Key 按此提供商单独存放本机凭据库，不写入数据库。',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '显示名称 *',
                      hintText: '例如：我的中转服务',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Base URL *',
                      hintText: 'https://api.deepseek.com/v1',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: keyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'API Key *',
                      hintText: 'sk-...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: modelCtrl,
                    decoration: const InputDecoration(
                      labelText: '模型 ID *',
                      hintText: 'deepseek-chat',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ctxCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '上下文长度（选填）',
                      hintText: '例如：128000',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: vision,
                    onChanged: (v) => setLocal(() => vision = v),
                    title: const Text('支持视觉（图片识别）'),
                  ),
                  if (formError != null) ...[
                    const SizedBox(height: 8),
                    Text(formError!,
                        style: const TextStyle(
                            color: AppColors.error, fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  _submitAdd(nameCtrl, urlCtrl, keyCtrl, modelCtrl, ctxCtrl,
                      vision, (err) => setLocal(() => formError = err),
                      () => Navigator.of(ctx).pop()),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );

    nameCtrl.dispose();
    urlCtrl.dispose();
    keyCtrl.dispose();
    modelCtrl.dispose();
    ctxCtrl.dispose();
  }

  /// 提交添加：校验 → 三件套落库（provider / 凭据 / 模型）→ 刷新列表。
  Future<void> _submitAdd(
    TextEditingController nameCtrl,
    TextEditingController urlCtrl,
    TextEditingController keyCtrl,
    TextEditingController modelCtrl,
    TextEditingController ctxCtrl,
    bool vision,
    void Function(String?) setError,
    void Function() closeDialog,
  ) async {
    final name = nameCtrl.text.trim();
    final url = urlCtrl.text.trim();
    final key = keyCtrl.text.trim();
    final modelId = modelCtrl.text.trim();
    final ctxRaw = ctxCtrl.text.trim();

    if (name.isEmpty || url.isEmpty || key.isEmpty || modelId.isEmpty) {
      setError('显示名称、Base URL、API Key、模型 ID 均为必填');
      return;
    }
    int? contextWindow;
    if (ctxRaw.isNotEmpty) {
      contextWindow = int.tryParse(ctxRaw);
      if (contextWindow == null || contextWindow <= 0) {
        setError('上下文长度须为正整数（或留空）');
        return;
      }
    }

    try {
      final profile = ProviderProfile(
        id: Ids.next('pp'),
        providerId: 'custom',
        displayName: name,
        baseUrl: url,
      );
      await widget.repos.providers.upsertProvider(profile);
      await widget.credentials.saveForProvider(
        providerProfileId: profile.id,
        apiKey: key,
        name: '凭据（$name）',
      );
      await widget.repos.providers.upsertModel(ModelProfile(
        id: Ids.next('mp'),
        providerProfileId: profile.id,
        modelId: modelId,
        contextWindow: contextWindow,
        supportsVision: vision,
      ));
      closeDialog();
      await _load();
      _snack('已添加模型：$modelId');
    } on AppError catch (e) {
      setError('添加失败：${e.message}');
    } catch (e) {
      setError('添加失败：$e');
    }
  }
}
