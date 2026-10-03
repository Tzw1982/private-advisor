/// 通讯录 · 分组页签：分组列表 → 进入显示组内成员；支持增删改 / 成员移入移出。
///
/// 完整性由服务层保证：`ExpertService.deleteGroup` 会先清空成员 `group_id`
/// （`expert_user_states.group_id` 为**逻辑外键**，无 DB 级 FK）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'contact_name_row.dart';

/// 分组页签。
class GroupsTab extends StatefulWidget {
  const GroupsTab({
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
  State<GroupsTab> createState() => _GroupsTabState();
}

class _GroupsTabState extends State<GroupsTab> {
  List<ExpertGroup> _groups = const [];
  List<ContactEntry> _contacts = const [];
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
      _groups = await widget.experts.listGroups();
      _contacts = await loadSortedContacts(
          experts: widget.experts, repos: widget.repos);
    } on AppError catch (e) {
      _error = e.message;
    } catch (e) {
      _error = '加载分组失败：$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on AppError catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('操作失败：$e');
    } finally {
      await _reload();
    }
  }

  // -------------------------------------------------------------------------
  // 动作
  // -------------------------------------------------------------------------

  Future<void> _createGroup() async {
    final name = await _promptText('新建分组', '分组名称', '例如：投标顾问组');
    if (name == null || name.trim().isEmpty) return;
    await _guard(() async {
      final g = await widget.experts.createGroup(name);
      _snack('已创建分组：${g.name}');
    });
  }

  Future<void> _renameGroup(ExpertGroup g) async {
    final name = await _promptText('重命名分组', '分组名称', g.name, initial: g.name);
    if (name == null || name.trim().isEmpty || name.trim() == g.name) return;
    await _guard(() async {
      await widget.experts.updateGroup(g.copyWith(name: name.trim()));
      _snack('已重命名');
    });
  }

  Future<void> _deleteGroup(ExpertGroup g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分组'),
        content: Text('确定删除分组「${g.name}」？\n组内成员不会被删除，只是移出该分组。'),
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
    await _guard(() async {
      await widget.experts.deleteGroup(g.id);
      _snack('已删除分组（成员已移出）');
    });
  }

  Future<void> _addMembers(ExpertGroup g) async {
    final candidates = _contacts
        .where((c) => (c.groupId ?? '').isEmpty || c.groupId != g.id)
        .toList();
    if (candidates.isEmpty) {
      _snack('没有可添加的联系人');
      return;
    }
    final picked = await _pickContacts('把联系人加入「${g.name}」', candidates);
    if (picked == null || picked.isEmpty) return;
    await _guard(() async {
      for (final id in picked) {
        await widget.experts.assignGroup(id, g.id);
      }
      _snack('已加入 ${picked.length} 位联系人');
    });
  }

  Future<void> _removeMember(ExpertGroup g, ContactEntry c) async {
    await _guard(() async {
      await widget.experts.assignGroup(c.expert.id, null);
      _snack('已把「${c.displayName}」移出分组');
    });
  }

  // -------------------------------------------------------------------------
  // 对话框
  // -------------------------------------------------------------------------

  Future<String?> _promptText(String title, String label, String hint,
      {String? initial}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              border: const OutlineInputBorder()),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('确定')),
        ],
      ),
    );
  }

  Future<Set<String>?> _pickContacts(
      String title, List<ContactEntry> candidates) {
    final selected = <String>{};
    return showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 380,
            height: 360,
            child: ListView.builder(
              itemCount: candidates.length,
              itemBuilder: (_, i) {
                final c = candidates[i];
                return CheckboxListTile(
                  dense: true,
                  value: selected.contains(c.expert.id),
                  title: Text(c.displayName,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onChanged: (v) => setDialogState(() => v == true
                      ? selected.add(c.expert.id)
                      : selected.remove(c.expert.id)),
                );
              },
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(selected),
              child: Text(selected.isEmpty ? '确定' : '加入 ${selected.length} 位'),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading && _groups.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
          child: Text(_error!,
              style: const TextStyle(color: AppColors.error, fontSize: 12)));
    }

    final ungrouped =
        _contacts.where((c) => (c.groupId ?? '').isEmpty).toList();

    // 单一滚动容器：`_toolbar()` + `Divider` 固定，其余全部（分组列表、未分组
    // 标题、未分组好友、空态提示）放进同一个 `ListView`——避免把数量不定的
    // 未分组好友直接铺进 `Column` 造成纵向溢出（且溢出时无法滚动）。
    return Column(
      children: [
        _toolbar(),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              if (_groups.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: AppDims.space3, vertical: AppDims.space4),
                  child: Text('还没有分组。\n点右上角「新建分组」把好友归类。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.textTertiary, fontSize: 12)),
                )
              else
                ..._groups.map(_groupTile),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.folder_off_outlined,
                    size: AppDims.iconNav, color: AppColors.textTertiary),
                title: Text('未分组（${ungrouped.length}）',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ),
              ...ungrouped.map((c) => ContactNameRow(
                    entry: c,
                    subtitle: '未分组',
                    expanded: _expandedId == c.expert.id,
                    onToggle: () => setState(() => _expandedId =
                        _expandedId == c.expert.id ? null : c.expert.id),
                    onOpenSettings: () => widget.onOpenSettings(c.expert.id),
                    onOpenChat: () => widget.onOpenChat(c.expert.id),
                  )),
            ],
          ),
        ),
      ],
    );
  }

  /// 顶部工具栏行（48px）：标题（分组数）+「新建分组」按钮。
  ///
  /// 位置与高度与好友页签 / 人才市场中栏标题行一致（`AppDims.searchBarHeight`
  /// 48px + 右侧同款 `FilledButton.icon` 32px 紧凑样式）。
  Widget _toolbar() {
    return SizedBox(
      height: AppDims.searchBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppDims.space3),
        child: Row(
          children: [
            const Icon(Icons.folder_outlined,
                size: AppDims.iconInline, color: AppColors.textSecondary),
            const SizedBox(width: AppDims.space1),
            Expanded(
              child: Text('分组（${_groups.length}）',
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
              onPressed: _createGroup,
              icon: const Icon(Icons.create_new_folder_outlined,
                  size: AppDims.iconInline),
              label: const Text('新建分组'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupTile(ExpertGroup g) {
    final members = _contacts.where((c) => c.groupId == g.id).toList();
    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: AppDims.space3),
      childrenPadding: const EdgeInsets.only(bottom: AppDims.space1),
      leading: const Icon(Icons.folder_outlined,
          size: AppDims.iconNav, color: AppColors.textSecondary),
      title: Text(g.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary)),
      subtitle: Text('${members.length} 位成员',
          style: const TextStyle(fontSize: 12, color: AppColors.textTertiary)),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'add':
              _addMembers(g);
            case 'rename':
              _renameGroup(g);
            case 'delete':
              _deleteGroup(g);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'add', child: Text('添加成员')),
          PopupMenuItem(value: 'rename', child: Text('重命名')),
          PopupMenuItem(value: 'delete', child: Text('删除分组')),
        ],
      ),
      children: [
        if (members.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppDims.space2),
            child: Text('暂无成员，点右上菜单「添加成员」',
                style: TextStyle(fontSize: 11, color: AppColors.textTertiary)),
          )
        else
          ...members.map((c) => Row(
                children: [
                  Expanded(
                    child: ContactNameRow(
                      entry: c,
                      subtitle: g.name,
                      expanded: _expandedId == c.expert.id,
                      onToggle: () => setState(() => _expandedId =
                          _expandedId == c.expert.id ? null : c.expert.id),
                      onOpenSettings: () => widget.onOpenSettings(c.expert.id),
                      onOpenChat: () => widget.onOpenChat(c.expert.id),
                    ),
                  ),
                  IconButton(
                    tooltip: '移出分组',
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                    onPressed: () => _removeMember(g, c),
                  ),
                ],
              )),
      ],
    );
  }
}
