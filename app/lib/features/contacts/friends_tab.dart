/// 通讯录 · 好友页签：按**首字母**分组（A→Z，`#` 置顶），名称行内联展开操作。
///
/// 排序内核复用 `advisor_core` 的 `ContactSorter` + `PinyinInitial`（与拼音来源解耦）；
/// 排序键 = 展示名（备注优先）。UI 只做展示，不自行实现排序。
///
/// 顶部工具栏（走查反馈 #53：与人才市场/知识库一致的位置与高度）承载
/// 「新建专家」入口：core `ExpertsService.createLocal` 早已具备能力，此前缺 UI。
library;

import 'dart:collection'; // LinkedHashMap（分组锚点容器，ContactSorter 返回类型）

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'contact_name_row.dart';
import 'create_expert_dialog.dart';

/// 好友页签。
class FriendsTab extends StatefulWidget {
  const FriendsTab({
    super.key,
    required this.experts,
    required this.repos,
    required this.onOpenSettings,
    required this.onOpenChat,
  });

  final ExpertService experts;
  final Repositories repos;
  final ValueChanged<String> onOpenSettings;
  final ValueChanged<String> onOpenChat;

  @override
  State<FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends State<FriendsTab> {
  List<ContactEntry> _contacts = const [];
  LinkedHashMap<String, List<ContactEntry>> _grouped = LinkedHashMap();
  bool _loading = true;
  String? _error;

  /// 当前展开的联系人 id（**单一展开原则**：父级持 id，点开一行自动收起其余）。
  String? _expandedId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final contacts = await loadSortedContacts(
          experts: widget.experts, repos: widget.repos);
      _grouped = ContactSorter.groupByInitial<ContactEntry>(
        contacts,
        nameOf: (c) => c.displayName,
        initialOf: PinyinInitial.of,
      );
      _contacts = contacts;
    } on AppError catch (e) {
      _error = e.message;
    } catch (e) {
      _error = '加载联系人失败：$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  /// 新建专家（#53）：弹对话框 → core `createLocal` → 成功 SnackBar +
  /// **好友列表刷新**（`_reload` 重读 `experts.list()`，新专家即出现）。
  Future<void> _createExpert() async {
    final created = await showCreateExpertDialog(
      context,
      experts: widget.experts,
    );
    if (created == null || !mounted) return;
    _snack('已创建专家：${created.name}');
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        const Divider(height: 1),
        Expanded(child: _body()),
      ],
    );
  }

  /// 顶部工具栏行：标题（好友数）+「新建专家」按钮。
  ///
  /// 位置与高度与人才市场中栏标题行一致（`AppDims.searchBarHeight` 48px /
  /// 右侧同款 `FilledButton.icon` 32px 紧凑样式，market_page.dart L319-370）。
  Widget _toolbar() {
    return SizedBox(
      height: AppDims.searchBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppDims.space3),
        child: Row(
          children: [
            const Icon(Icons.people_outline,
                size: AppDims.iconInline, color: AppColors.textSecondary),
            const SizedBox(width: AppDims.space1),
            Expanded(
              child: Text('好友（${_contacts.length}）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: AppDims.space2),
                minimumSize: const Size(0, 32),
                textStyle: const TextStyle(fontSize: 12),
              ),
              onPressed: _createExpert,
              icon: const Icon(Icons.person_add_alt, size: AppDims.iconInline),
              label: const Text('新建专家'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading && _contacts.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                style: const TextStyle(color: AppColors.error, fontSize: 12)),
            const SizedBox(height: 8),
            TextButton(onPressed: _reload, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_contacts.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '好友列表为空。\n去「人才市场」招募专家，或点右上角「新建专家」自建一位。',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _totalRows,
        itemBuilder: (_, i) => _row(i),
      ),
    );
  }

  int get _totalRows =>
      _grouped.keys.fold(0, (n, k) => n + 1 + (_grouped[k]?.length ?? 0));

  /// 行布局：分组锚点行（A / B / … / #）后跟该组成员。
  Widget? _row(int index) {
    var cursor = 0;
    for (final key in _grouped.keys) {
      final items = _grouped[key]!;
      if (index == cursor) {
        return Container(
          width: double.infinity,
          color: AppColors.bgSecondary,
          padding: const EdgeInsets.symmetric(
              horizontal: AppDims.space4, vertical: 3),
          child: Text(
            key,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppColors.textSecondary),
          ),
        );
      }
      cursor++;
      if (index < cursor + items.length) {
        final c = items[index - cursor];
        return ContactNameRow(
          entry: c,
          expanded: _expandedId == c.expert.id,
          onToggle: () => setState(() =>
              _expandedId = _expandedId == c.expert.id ? null : c.expert.id),
          onOpenSettings: () => widget.onOpenSettings(c.expert.id),
          onOpenChat: () => widget.onOpenChat(c.expert.id),
        );
      }
      cursor += items.length;
    }
    return null;
  }
}
