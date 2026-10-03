/// 通讯录中栏容器（第 5 轮 B3 重样式）：顶部固定「好友｜分组｜群聊」三页签 +
/// 内容路由。
///
/// 规格 4.2「Tab 切换栏」逐项（数值不发挥）：
/// - 页签栏高度 **36px**（`AppDims.tabHeight`），左右内边距 12；
/// - Tab 文字 12px，**选中态文字主色 `#2E3A8C` + 底部 2px 下划线**，
///   未选中 `textSecondary`；
/// - 一级背景 `bgPrimary`；分割线 `divider`（主题色，1px）。
///
/// 只做展示与路由；数据加载在各自页签内完成（`FutureBuilder`/`initState`）。
/// 本文件**不 import `main.dart`**（避免 app 入口与 feature 的循环依赖），
/// 所需服务全部由构造参数注入。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'contact_name_row.dart';
import 'expert_transfer_bar.dart';
import 'friends_tab.dart';
import 'group_chats_tab.dart';
import 'groups_tab.dart';

/// 通讯录容器。
class ContactsPane extends StatefulWidget {
  const ContactsPane({
    super.key,
    required this.experts,
    required this.conversations,
    required this.group,
    required this.repos,
    required this.exportService,
    required this.importService,
    required this.onSelectExpert,
    required this.onSelectConversation,
  });

  final ExpertService experts;
  final ConversationService conversations;
  final GroupService group;
  final Repositories repos;

  /// 导出服务（导入导出入口用）。
  final ExpertExportService exportService;

  /// 导入服务（导入导出入口用）。
  final ExpertImportService importService;

  /// 点「⚙设置」/ 分组里的联系人 → 中栏打开专家设置面板。
  final ValueChanged<String> onSelectExpert;

  /// 点群聊 / 「💬对话」→ 中栏打开会话。
  final ValueChanged<String> onSelectConversation;

  @override
  State<ContactsPane> createState() => _ContactsPaneState();
}

class _ContactsPaneState extends State<ContactsPane> {
  int _tab = 0;
  int _tick = 0; // 递增以强制页签重新加载数据

  // —— 导出多选态 ——
  bool _selecting = false;
  bool _busy = false;
  List<ContactEntry> _exportEntries = const [];
  final Set<String> _selected = {};

  Future<void> _openSingleChat(String expertId) async {
    try {
      final conv = await widget.conversations.createSingle(expertId);
      widget.onSelectConversation(conv.id);
    } on AppError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  /// 进入导出多选态（先加载联系人列表）。
  Future<void> _enterExportMode() async {
    setState(() => _busy = true);
    try {
      final entries = await loadSortedContacts(
          experts: widget.experts, repos: widget.repos);
      if (!mounted) return;
      setState(() {
        _exportEntries = entries;
        _selected.clear();
        _selecting = true;
      });
    } on AppError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _cancelExport() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  void _toggleSelect(String id) => setState(() {
        if (!_selected.add(id)) _selected.remove(id);
      });

  void _selectAll() => setState(() {
        if (_selected.length == _exportEntries.length) {
          _selected.clear();
        } else {
          _selected
            ..clear()
            ..addAll(_exportEntries.map((e) => e.expert.id));
        }
      });

  Future<void> _doExport() async {
    final ids = <String>[
      for (final e in _exportEntries)
        if (_selected.contains(e.expert.id)) e.expert.id,
    ];
    if (ids.isEmpty) return;
    setState(() => _busy = true);
    final ok = await runExpertExport(
      context,
      exportService: widget.exportService,
      expertIds: ids,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _selecting = false;
        _selected.clear();
      }
    });
  }

  Future<void> _doImport() async {
    setState(() => _busy = true);
    final ok = await runExpertImport(
      context,
      importService: widget.importService,
      repos: widget.repos,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _tick++; // 刷新页签数据
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bgPrimary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _tabs(),
          const Divider(height: 1),
          _transferBar(),
          const Divider(height: 1),
          Expanded(
            child: _selecting
                ? ExpertExportSelectionView(
                    entries: _exportEntries,
                    selectedIds: _selected,
                    onToggle: _toggleSelect,
                    onSelectAll: _selectAll,
                    onExport: _doExport,
                    onCancel: _cancelExport,
                    busy: _busy,
                  )
                : KeyedSubtree(
                    key: ValueKey('$_tab-$_tick'),
                    child: _body(),
                  ),
          ),
        ],
      ),
    );
  }

  /// 导入 / 导出工具栏行（多选态时改为标题行）。
  Widget _transferBar() {
    if (_selecting) {
      return SizedBox(
        height: AppDims.tabHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppDims.space3),
          child: Row(
            children: [
              const Icon(Icons.file_upload_outlined,
                  size: AppDims.iconInline, color: AppColors.textSecondary),
              const SizedBox(width: AppDims.space1),
              Expanded(
                child: Text(
                  '选择要导出的专家（已选 ${_selected.length}）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      height: AppDims.tabHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppDims.space2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            ExpertTransferBar(
              busy: _busy,
              onImport: _doImport,
              onExport: _enterExportMode,
            ),
          ],
        ),
      ),
    );
  }

  /// 三页签栏（规格 4.2：高 36、选中态主色文字 + 底部 2px 下划线）。
  Widget _tabs() {
    Widget item(int index, String label) {
      final active = _tab == index;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() {
            _tab = index;
            _tick++; // 切页签即刷新，保证分组变动后各页签数据一致
          }),
          child: Container(
            height: AppDims.tabHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: active ? AppColors.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? AppColors.primary : AppColors.textSecondary,
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: AppDims.tabHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppDims.space3),
        child: Row(
          children: [
            item(0, '好友'),
            item(1, '分组'),
            item(2, '群聊'),
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh,
                  size: AppDims.iconInline, color: AppColors.textSecondary),
              onPressed: () => setState(() => _tick++),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    switch (_tab) {
      case 1:
        return GroupsTab(
          experts: widget.experts,
          repos: widget.repos,
          onOpenSettings: widget.onSelectExpert,
          onOpenChat: _openSingleChat,
        );
      case 2:
        return GroupChatsTab(
          experts: widget.experts,
          conversations: widget.conversations,
          group: widget.group,
          repos: widget.repos,
          onOpenConversation: widget.onSelectConversation,
        );
      default:
        return FriendsTab(
          experts: widget.experts,
          repos: widget.repos,
          onOpenSettings: widget.onSelectExpert,
          onOpenChat: _openSingleChat,
        );
    }
  }
}
