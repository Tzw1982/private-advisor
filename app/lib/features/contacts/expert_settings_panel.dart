/// 专家设置面板（通讯录 · ⚙设置 → 中栏打开）。
///
/// 小节（PRD §6.2 / 架构设计 §7）：
/// 1. 大模型下拉（覆盖全局默认；`ExpertRuntimeConfig.modelProfileId`）；
/// 2. Grounding 知识接地策略（off / preferred / strict / localOnly）；
/// 3. 专家风格：**7 预设单选 + 「不指定」**（P0；自定义风格 P2 不做），
///    走 `ExpertService.setStyle`，落 `expert_user_states.style_id`；
/// 4. 提示词多行编辑（`ExpertUserState.customPrompt`，非空时覆盖系统提示词）；
/// 5. 知识库绑定小节：绑定列表 + 每条可改 `topK` / `similarity_threshold`
///    （走既有 `ExpertService.bindKnowledge`，**端口零改动**）+ 添加 / 解绑。
///
/// UI 只调用应用层服务，不直接触碰数据库。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';

/// 专家设置面板。
class ExpertSettingsPanel extends StatefulWidget {
  const ExpertSettingsPanel({
    super.key,
    required this.expertId,
    required this.experts,
    required this.providers,
    required this.knowledge,
    required this.repos,
    required this.onBack,
  });

  final String expertId;
  final ExpertService experts;
  final ProviderService providers;
  final KnowledgeService knowledge;
  final Repositories repos;

  /// 返回通讯录空态（清除中栏选中态）。
  final VoidCallback onBack;

  @override
  State<ExpertSettingsPanel> createState() => _ExpertSettingsPanelState();
}

class _ExpertSettingsPanelState extends State<ExpertSettingsPanel> {
  Expert? _expert;
  ExpertUserState? _state;
  ExpertRuntimeConfig? _config;
  List<ExpertKnowledgeBinding> _bindings = const [];
  List<KnowledgeBase> _bases = const [];
  List<ModelProfile> _models = const [];
  String? _defaultModelId;

  // 表单暂存
  final _promptCtrl = TextEditingController();
  bool _promptDirty = false;

  bool _loading = true;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ExpertSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expertId != widget.expertId) _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final id = widget.expertId;
      final results = await Future.wait([
        widget.experts.get(id),
        widget.repos.experts.getUserState(id),
        widget.repos.experts.getRuntimeConfig(id),
        widget.experts.listBindings(id),
        widget.knowledge.listBases(),
        widget.providers.listModels(),
        widget.providers.defaultModelProfileId,
      ]);
      if (!mounted) return;
      setState(() {
        _expert = results[0] as Expert?;
        _state = results[1] as ExpertUserState?;
        _config = results[2] as ExpertRuntimeConfig?;
        _bindings = results[3] as List<ExpertKnowledgeBinding>;
        _bases = results[4] as List<KnowledgeBase>;
        _models = results[5] as List<ModelProfile>;
        _defaultModelId = results[6] as String?;
        final custom = _state?.customPrompt;
        final isCustom = custom != null && custom.trim().isNotEmpty;
        _promptCtrl.text = isCustom ? custom : '';
        _promptDirty = false;
        _loading = false;
      });
    } on AppError catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '加载专家设置失败：$e';
        _loading = false;
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AppError catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _displayName => _expert == null
      ? ''
      : EffectiveExpertConfig.resolveName(_expert!, _state);

  /// 生效模型：专家覆盖 ?? 全局默认。
  String? get _effectiveModelId => _config?.modelProfileId ?? _defaultModelId;

  // -------------------------------------------------------------------------
  // 动作
  // -------------------------------------------------------------------------

  Future<void> _savePrompt() async {
    final state = _state;
    if (state == null) return;
    final text = _promptCtrl.text.trim();
    await _guard(() async {
      // 与 copyWith 的 null 语义区分：空串 = 清除自定义（回退系统提示词）。
      final next = state.copyWith(
        customPrompt: text.isEmpty ? state.customPrompt : text,
        clearCustomPrompt: text.isEmpty,
      );
      await widget.experts.updateUserState(next);
      _snack(text.isEmpty ? '已清除自定义提示词（回退系统提示词）' : '已保存自定义提示词');
      await _reload();
    });
  }

  Future<void> _setModel(String? modelProfileId) async {
    final cfg = _config;
    if (cfg == null) return;
    await _guard(() async {
      // 先读既有 config 再 copyWith，避免覆盖丢失其它字段。
      await widget.experts.updateRuntimeConfig(
        cfg.copyWith(
            modelProfileId: modelProfileId, clearModel: modelProfileId == null),
      );
      _snack(modelProfileId == null ? '已恢复默认模型' : '已切换模型');
      await _reload();
    });
  }

  Future<void> _setGrounding(GroundingPolicy policy) async {
    final cfg = _config;
    if (cfg == null) return;
    await _guard(() async {
      await widget.experts
          .updateRuntimeConfig(cfg.copyWith(groundingPolicy: policy));
      _snack('知识接地策略：${policy.label}');
      await _reload();
    });
  }

  Future<void> _setStyle(String? styleId) async {
    await _guard(() async {
      await widget.experts.setStyle(widget.expertId, styleId);
      _snack(styleId == null ? '已关闭风格（不注入）' : '已设置风格');
      await _reload();
    });
  }

  Future<void> _saveBinding(
      ExpertKnowledgeBinding b, int topK, double threshold) async {
    await _guard(() async {
      await widget.experts.bindKnowledge(
        widget.expertId,
        b.knowledgeBaseId,
        topK: topK,
        threshold: threshold,
      );
      _snack('已更新「${_baseName(b.knowledgeBaseId)}」的检索参数');
      await _reload();
    });
  }

  Future<void> _unbind(ExpertKnowledgeBinding b) async {
    await _guard(() async {
      await widget.experts.unbindKnowledge(widget.expertId, b.knowledgeBaseId);
      _snack('已解绑「${_baseName(b.knowledgeBaseId)}」');
      await _reload();
    });
  }

  Future<void> _addBinding() async {
    final boundIds = _bindings.map((b) => b.knowledgeBaseId).toSet();
    final candidates = _bases.where((b) => !boundIds.contains(b.id)).toList();
    if (candidates.isEmpty) {
      _snack('没有可绑定的知识库（已全部绑定或尚未创建）');
      return;
    }
    final picked = await showDialog<KnowledgeBase>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('绑定知识库'),
        children: candidates
            .map((b) => SimpleDialogOption(
                  onPressed: () => Navigator.of(ctx).pop(b),
                  child: Text(b.name),
                ))
            .toList(),
      ),
    );
    if (picked == null) return;
    await _guard(() async {
      await widget.experts.bindKnowledge(widget.expertId, picked.id);
      _snack('已绑定「${picked.name}」');
      await _reload();
    });
  }

  String _baseName(String id) {
    for (final b in _bases) {
      if (b.id == id) return b.name;
    }
    return id;
  }

  // -------------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null || _expert == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error ?? '专家不存在',
                style: const TextStyle(color: AppColors.error, fontSize: 12)),
            const SizedBox(height: 8),
            TextButton(onPressed: widget.onBack, child: const Text('返回')),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              _sectionTitle('大模型'),
              _modelDropdown(),
              const SizedBox(height: 4),
              Text(
                '未选择时使用全局默认（设置中配置）。',
                style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
              const Divider(height: 28),
              _sectionTitle('知识接地策略（Grounding）'),
              _groundingRadios(),
              const Divider(height: 28),
              _sectionTitle('专家风格'),
              _styleRadios(),
              const Divider(height: 28),
              _sectionTitle('提示词'),
              _promptEditor(),
              const Divider(height: 28),
              _sectionTitle('知识库绑定（${_bindings.length}）'),
              _bindingsSection(),
              const SizedBox(height: 28),
              const Divider(),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: const Text('危险操作',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AppColors.error)),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '删除后该专家及其会话、消息、生成记录、附件与知识库绑定会一并移除，'
                      '且不可恢复。市场中的专家包不受影响，之后可重新添加（相当于重装）。',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error),
                    onPressed: _busy ? null : _confirmDeleteExpert,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('删除专家', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 二次确认后删除专家。
  ///
  /// 底层 `ExpertsService.delete` 早已存在（services.dart:295 → `deleteExpert`），
  /// 此前全 app 没有任何 UI 入口；第 #60 轮因 slug 缺陷需要"卸掉重装"才补上。
  Future<void> _confirmDeleteExpert() async {
    final expert = await widget.experts.get(widget.expertId);
    final name = expert?.name ?? widget.expertId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除专家？'),
        content: Text(
          '确定删除「$name」？\n\n'
          '将一并移除：该专家的会话、消息、生成记录、附件与知识库绑定。\n'
          '此操作不可恢复。市场中的专家包不受影响，之后可重新添加。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.experts.delete(widget.expertId);
      if (!mounted) return;
      _snack('已删除「$name」，可从人才市场重新添加');
      widget.onBack();
    } on AppError catch (e) {
      if (mounted) _snack(e.message);
    } catch (e) {
      if (mounted) _snack('删除失败：$e');
    }
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回通讯录',
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: widget.onBack,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '专家设置 · $_displayName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
          if (_busy)
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      );

  Widget _modelDropdown() {
    final current = _config?.modelProfileId;
    return DropdownButtonFormField<String?>(
      // 注：DropdownButtonFormField 的 `value` 自 Flutter 3.33 起弃用；
      // 语义与 `initialValue` 等价（SDK `dropdown.dart` L1794/L1871 实证：
      // `super(initialValue: initialValue ?? value)`，didUpdateWidget 中
      // initialValue 变化即 setValue）。持久化配置重建 → 显示随之刷新，
      // 与旧 `value` 行为一致。
      initialValue: current,
      decoration: InputDecoration(
        labelText:
            _effectiveModelId == null ? '生效模型：未配置' : '生效模型：$_effectiveModelId',
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child:
              Text('（跟随全局默认）', style: TextStyle(color: AppColors.textTertiary)),
        ),
        ..._models.map((m) => DropdownMenuItem<String?>(
              value: m.id,
              child: Text('${m.modelId}（${m.providerProfileId}）'),
            )),
      ],
      onChanged: _busy ? null : (v) => _setModel(v),
    );
  }

  Widget _groundingRadios() {
    final current = _config?.groundingPolicy ?? GroundingPolicy.off;
    // RadioGroup 祖先统一管理 groupValue / onChanged（Flutter 3.32+ 新 API，
    // SDK `radio_group.dart` L59：`const RadioGroup({groupValue, required
    // onChanged, required child})`）；子级 RadioListTile 只留 `value`。
    // 忙态 → 子级 `enabled: false`（旧写法以 onChanged=null 置灰，等价迁移）。
    return RadioGroup<GroundingPolicy>(
      groupValue: current,
      onChanged: (v) {
        if (v != null) _setGrounding(v);
      },
      child: Column(
        children: [
          for (final p in GroundingPolicy.values)
            RadioListTile<GroundingPolicy>(
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text('${p.label} · ${p.description}',
                  style: const TextStyle(fontSize: 12)),
              value: p,
              enabled: !_busy,
            ),
        ],
      ),
    );
  }

  Widget _styleRadios() {
    final current = _state?.styleId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RadioGroup<String?>(
          groupValue: current,
          onChanged: (v) => _setStyle(v),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RadioListTile<String?>(
                dense: true,
                visualDensity: VisualDensity.compact,
                title:
                    const Text('不指定（不注入风格指令）', style: TextStyle(fontSize: 12)),
                subtitle: const Text('关闭后该专家保持原始口吻，历史消息不受影响。',
                    style:
                        TextStyle(fontSize: 11, color: AppColors.textTertiary)),
                value: null,
                // RadioGroup 下选中态的 null 值仍需 toggleable 才能反选。
                toggleable: true,
                enabled: !_busy,
              ),
              for (final s in ExpertStyle.values)
                RadioListTile<String?>(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(s.label, style: const TextStyle(fontSize: 12)),
                  subtitle: Text(s.directive,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textTertiary)),
                  value: s.name,
                  enabled: !_busy,
                ),
            ],
          ),
        ),
        const SizedBox(height: AppDims.space1),
        const Text(
          '风格为专家级设置：生效于此后每次生成（单聊与其参与的群聊），不改历史消息；市场更新不覆盖。',
          style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  Widget _promptEditor() {
    final isCustom =
        _state?.customPrompt != null && _state!.customPrompt!.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isCustom ? '当前生效：自定义提示词（覆盖系统提示词）' : '当前生效：系统提示词（未自定义）',
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _promptCtrl,
          maxLines: 6,
          minLines: 3,
          enabled: !_busy,
          decoration: InputDecoration(
            hintText: '留空则使用系统提示词（原文见下）',
            border: const OutlineInputBorder(),
            helperMaxLines: 4,
          ),
          onChanged: (_) {
            if (!_promptDirty) setState(() => _promptDirty = true);
          },
        ),
        const SizedBox(height: 6),
        ExpansionTile(
          dense: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: const Text('查看系统提示词原文', style: TextStyle(fontSize: 12)),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: AppColors.bgSecondary,
              child: SelectableText(
                _expert!.systemPrompt,
                style: const TextStyle(fontSize: 11, height: 1.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _busy || !_promptDirty ? null : _savePrompt,
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('保存提示词'),
          ),
        ),
      ],
    );
  }

  Widget _bindingsSection() {
    final boundIds = _bindings.map((b) => b.knowledgeBaseId).toSet();
    final hasUnbound = _bases.any((b) => !boundIds.contains(b.id));
    if (_bindings.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('尚未绑定知识库。绑定后该专家作答前会先检索（按 Grounding 策略）。',
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy || _bases.isEmpty ? null : _addBinding,
            icon: const Icon(Icons.link, size: 16),
            label: const Text('添加绑定'),
          ),
        ],
      );
    }
    return Column(
      children: [
        for (final b in _bindings) _bindingTile(b),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: _busy || !hasUnbound ? null : _addBinding,
          icon: const Icon(Icons.link, size: 16),
          label: const Text('添加绑定'),
        ),
      ],
    );
  }

  Widget _bindingTile(ExpertKnowledgeBinding b) {
    final topKCtrl = TextEditingController(text: '${b.topK}');
    final thresholdCtrl =
        TextEditingController(text: b.similarityThreshold.toString());
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: AppColors.bgSecondary,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_outlined,
                    size: AppDims.iconInline, color: AppColors.success),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_baseName(b.knowledgeBaseId),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  tooltip: '解绑',
                  icon: const Icon(Icons.link_off, size: 16),
                  onPressed: _busy ? null : () => _unbind(b),
                ),
              ],
            ),
            Row(
              children: [
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: topKCtrl,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'topK',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: thresholdCtrl,
                    enabled: !_busy,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'similarity_threshold',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const Spacer(),
                FilledButton.tonal(
                  onPressed: _busy
                      ? null
                      : () {
                          final topK = int.tryParse(topKCtrl.text.trim());
                          final threshold =
                              double.tryParse(thresholdCtrl.text.trim());
                          if (topK == null || topK <= 0 || topK > 50) {
                            _snack('topK 需为 1–50 的整数');
                            return;
                          }
                          if (threshold == null ||
                              threshold < 0 ||
                              threshold > 1) {
                            _snack('similarity_threshold 需为 0–1 的小数');
                            return;
                          }
                          _saveBinding(b, topK, threshold);
                        },
                  child: const Text('保存', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
