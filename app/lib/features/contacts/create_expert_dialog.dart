/// 新建专家对话框（走查反馈 #53：core 的 `ExpertsService.createLocal` 早已具备，
/// 缺的是 UI 入口——本文件补上，**不新增任何 core 能力**）。
///
/// 数据口径（避免"UI 校验与 core 漂移"）：
/// - 字段去向：名称 → `name`（必填）、系统提示词 → `systemPrompt`（必填）、
///   擅长业务/职业 → `profession`（选填）、分类 → `categoryId`（选填，取
///   [kMarketCategoryNames] 的 key，与人才市场同一份口径）、欢迎语 → `welcomeMessage`（选填）；
/// - 校验：空 name / 空 prompt **直接不提交**，提示文案与 core
///   `ValidationError('expert.name'/'expert.prompt')` 逐字一致；core 仍为唯一
///   权威兜底（提交后若抛错，**原文展示 `e.message`，不静默**）；
/// - `quickPrompts`（快捷提问）**本轮不做**：入口保持完整可用优先于半成品字段。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import '../market/market_card.dart'; // kMarketCategoryNames：既有分类口径，不复制

/// 打开「新建专家」对话框；**成功创建返回创建的 [Expert]**（调用方据此提示 +
/// 刷新好友列表），取消 / 失败返回 `null`。
Future<Expert?> showCreateExpertDialog(
  BuildContext context, {
  required ExpertService experts,
}) {
  return showDialog<Expert>(
    context: context,
    builder: (_) => CreateExpertDialog(experts: experts),
  );
}

/// 新建专家对话框（宽约 520，内容区可滚）。
class CreateExpertDialog extends StatefulWidget {
  const CreateExpertDialog({super.key, required this.experts});

  final ExpertService experts;

  @override
  State<CreateExpertDialog> createState() => _CreateExpertDialogState();
}

class _CreateExpertDialogState extends State<CreateExpertDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _promptCtrl = TextEditingController();
  final _professionCtrl = TextEditingController();
  final _welcomeCtrl = TextEditingController();

  /// 选中的分类 id（`kMarketCategoryNames` 的 key）；null = 不分类。
  String? _categoryId;

  bool _busy = false;

  /// 提交失败提示（**core 抛出错原文**，不包装、不静默）。
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _promptCtrl.dispose();
    _professionCtrl.dispose();
    _welcomeCtrl.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      );

  Future<void> _submit() async {
    // 提前拦击（口径与 core 逐字一致，见 library 注释）：空 name / 空 prompt
    // 直接不提交。注意 core 侧 createLocal 仍会再校验一遍并抛
    // ValidationError —— 两处同源同文，不存在 UI 放行而 core 拒绝的分歧。
    final name = _nameCtrl.text.trim();
    final prompt = _promptCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '专家名称不能为空');
      return;
    }
    if (prompt.isEmpty) {
      setState(() => _error = '系统提示词不能为空');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await widget.experts.createLocal(
        name: name,
        systemPrompt: prompt,
        profession: _professionCtrl.text.trim().isEmpty
            ? null
            : _professionCtrl.text.trim(),
        categoryId: _categoryId,
        welcomeMessage:
            _welcomeCtrl.text.trim().isEmpty ? null : _welcomeCtrl.text.trim(),
      );
      if (!mounted) return;
      // 成功：返回 Expert（调用方 SnackBar + 刷新好友列表）。
      Navigator.of(context).pop(created);
    } on AppError catch (e) {
      // 原文展示（含 ValidationError；name/prompt 已在上面拦击，这里覆盖
      // core 侧其余业务拒绝）。不静默、不包装。
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '创建失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppDims.space4),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.person_add_alt,
                        size: AppDims.iconInline, color: AppColors.primary),
                    const SizedBox(width: AppDims.space1),
                    const Expanded(
                      child: Text('新建专家',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
                const SizedBox(height: AppDims.space3),
                TextFormField(
                  controller: _nameCtrl,
                  enabled: !_busy,
                  decoration: _decoration('专家名称 *', hint: '例如：消防车选型顾问'),
                ),
                const SizedBox(height: AppDims.space3),
                TextFormField(
                  controller: _promptCtrl,
                  enabled: !_busy,
                  minLines: 4,
                  maxLines: 6,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: _decoration(
                    '系统提示词 *',
                    hint: '例如：你是消防车选型顾问，擅长根据使用场景、载水量与'
                        '整车配置给出选型建议，回答需引用国标参数。',
                  ),
                ),
                const SizedBox(height: AppDims.space3),
                TextFormField(
                  controller: _professionCtrl,
                  enabled: !_busy,
                  decoration:
                      _decoration('擅长业务 / 职业（选填）', hint: '例如：消防装备 · 车辆选型'),
                ),
                const SizedBox(height: AppDims.space3),
                DropdownButtonFormField<String>(
                  // 注：DropdownButtonFormField 的 `value` 自 Flutter 3.33 起
                  // 弃用；语义与 `initialValue` 等价（SDK `dropdown.dart`
                  // L1794/L1871 实证：`super(initialValue: initialValue ??
                  // value)`，didUpdateWidget 中 initialValue 变化即
                  // setValue）。选品类后 setState 重建 → 显示随之刷新，
                  // 与旧 `value` 行为一致。
                  initialValue: _categoryId,
                  isExpanded: true,
                  hint: const Text('选择分类（选填）', style: TextStyle(fontSize: 13)),
                  decoration: _decoration('分类（选填）'),
                  items: [
                    for (final e in kMarketCategoryNames.entries)
                      DropdownMenuItem<String>(
                        value: e.key,
                        child: Text(e.value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13)),
                      ),
                  ],
                  onChanged:
                      _busy ? null : (v) => setState(() => _categoryId = v),
                ),
                const SizedBox(height: AppDims.space3),
                TextFormField(
                  controller: _welcomeCtrl,
                  enabled: !_busy,
                  minLines: 2,
                  maxLines: 3,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: _decoration('欢迎语（选填）', hint: '新会话开始时展示给用户的第一句话'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppDims.space3),
                  Container(
                    padding: const EdgeInsets.all(AppDims.space2),
                    decoration: BoxDecoration(
                      // 错误提示底色：由 AppColors.error 派生，**不写裸 Color(0x…)**。
                      color: AppColors.error.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(AppDims.radiusS),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 14, color: AppColors.error),
                        const SizedBox(width: AppDims.space1),
                        Expanded(
                          child: Text(_error!,
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.error)),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppDims.space4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed:
                          _busy ? null : () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: AppDims.space2),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: Text(_busy ? '创建中…' : '创建'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
