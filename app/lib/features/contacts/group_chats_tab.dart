/// 通讯录 · 群聊页签：群聊按**群名首字母**分组（`#` 置顶）+ 新建群聊。
///
/// 新建群聊强制「恰好 0 或 1 名组长」（`GroupRolePolicy`）；排序键 = 群名展示。
///
/// 列表行视觉（第 5 轮 B3 规格 4.2「会话项」同规，数值不发挥）：
/// 行高 64px、群头像 36×36 圆角 12（`bgTertiary` + 群组图标）、
/// 「群聊」小字标签 + 名称 14px/500、摘要 12px `textTertiary`；
/// **展开态 = 选中态**：底色 `sessionSelected` + 左侧 2px 主色竖条；
/// 分割线 indent 58px。
library;

import 'dart:collection'; // LinkedHashMap（分组锚点容器，ContactSorter 返回类型）

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'contact_name_row.dart';
import 'group_summary_card.dart';

/// 群聊页签。
class GroupChatsTab extends StatefulWidget {
  const GroupChatsTab({
    super.key,
    required this.experts,
    required this.conversations,
    required this.group,
    required this.repos,
    required this.onOpenConversation,
  });

  final ExpertService experts;
  final ConversationService conversations;
  final GroupService group;
  final Repositories repos;
  final ValueChanged<String> onOpenConversation;

  @override
  State<GroupChatsTab> createState() => _GroupChatsTabState();
}

class _GroupChatsTabState extends State<GroupChatsTab> {
  List<InboxEntry> _chats = const [];
  LinkedHashMap<String, List<InboxEntry>> _grouped = LinkedHashMap();
  bool _loading = true;
  String? _error;

  /// 当前展开群卡片对应的会话 id（**单一展开原则**：父级持 id）。
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
      final all = await widget.conversations.listInbox();
      final chats = all
          .where((e) => e.conversation.type == ConversationType.group)
          .toList()
        ..sort((a, b) => a.title.compareTo(b.title));
      _chats = chats;
      _grouped = ContactSorter.groupByInitial<InboxEntry>(
        chats,
        nameOf: (e) => e.title,
        initialOf: PinyinInitial.of,
      );
    } on AppError catch (e) {
      _error = e.message;
    } catch (e) {
      _error = '加载群聊失败：$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // -------------------------------------------------------------------------
  // 新建群聊
  // -------------------------------------------------------------------------

  Future<void> _createGroupChat() async {
    final contacts =
        await loadSortedContacts(experts: widget.experts, repos: widget.repos);
    if (contacts.isEmpty) {
      _snack('还没有好友，先去「人才市场」招募专家');
      return;
    }
    final pickedEntries = await _pickMembers(contacts);
    if (pickedEntries == null || pickedEntries.isEmpty) return;
    final pickedIds = pickedEntries.map((c) => c.expert.id).toList();

    final title = await _promptText('群聊名称', '例如：投标决策群');
    if (title == null || title.trim().isEmpty) return;

    // 恰好 0 或 1 名组长：不指定则不设组长（可后续在群成员面板指定）。
    String? leaderId;
    if (pickedEntries.length > 1) {
      final leader = await _pickLeader(pickedEntries);
      leaderId = leader?.expert.id;
    }

    try {
      final conv = await widget.conversations.createGroup(
        title: title.trim(),
        expertIds: pickedIds,
        leaderExpertId: leaderId,
      );
      _snack('已创建群聊「${title.trim()}」');
      await _reload();
      widget.onOpenConversation(conv.id);
    } on AppError catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('创建群聊失败：$e');
    }
  }

  Future<List<ContactEntry>?> _pickMembers(List<ContactEntry> contacts) {
    final selected = <ContactEntry>[];
    return showDialog<List<ContactEntry>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('选择群成员'),
          content: SizedBox(
            width: 380,
            height: 360,
            child: ListView.builder(
              itemCount: contacts.length,
              itemBuilder: (_, i) {
                final c = contacts[i];
                return CheckboxListTile(
                  dense: true,
                  value: selected.contains(c),
                  title: Text(c.displayName,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onChanged: (v) => setDialogState(() {
                    if (v == true) {
                      selected.add(c);
                    } else {
                      selected.remove(c);
                    }
                  }),
                );
              },
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消')),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.of(ctx).pop(selected),
              child: Text('下一步（已选 ${selected.length}）'),
            ),
          ],
        ),
      ),
    );
  }

  Future<ContactEntry?> _pickLeader(List<ContactEntry> members) {
    return showDialog<ContactEntry>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('指定组长（可选）'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('组长负责主导讨论；不指定则先「无组长」，可随时在群成员面板设置。',
                  style:
                      TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: AppDims.space2),
              // 成员列表放入**有界可滚动容器**：成员多时不纵向溢出，标题 / 说明 /
              // 「不指定」按钮始终可见可点。未用 `AlertDialog.scrollable`——据 Flutter
              // SDK 源码（material/dialog.dart），该开关会把 title 一并卷入同一个
              // `SingleChildScrollView`，导致标题也被滚走。此处 `maxHeight + shrinkWrap`：
              // 成员少时紧凑、成员多时限高滚动（同文件 `_pickMembers` 的同类做法）。
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in members)
                      ListTile(
                        dense: true,
                        title: Text(c.displayName,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.of(ctx).pop(c),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('不指定')),
        ],
      ),
    );
  }

  Future<String?> _promptText(String title, String hint) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
              hintText: hint, border: const OutlineInputBorder()),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('创建')),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading && _chats.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
          child: Text(_error!,
              style: const TextStyle(color: AppColors.error, fontSize: 12)));
    }

    return Column(
      children: [
        _toolbar(),
        const Divider(height: 1),
        Expanded(
          child: _chats.isEmpty
              ? const Center(
                  child: Text('还没有群聊。\n点右上角「新建群聊」，把多位专家拉进同一个问题。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.textTertiary, fontSize: 12)),
                )
              : ListView.builder(
                  itemCount: _totalRows,
                  itemBuilder: (_, i) => _row(i),
                ),
        ),
      ],
    );
  }

  int get _totalRows =>
      _grouped.keys.fold(0, (n, k) => n + 1 + (_grouped[k]?.length ?? 0));

  /// 顶部工具栏行（48px）：标题（群聊数）+「新建群聊」按钮。
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
            const Icon(Icons.groups_outlined,
                size: AppDims.iconInline, color: AppColors.textSecondary),
            const SizedBox(width: AppDims.space1),
            Expanded(
              child: Text('群聊（${_chats.length}）',
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
              onPressed: _createGroupChat,
              icon: const Icon(Icons.group_add_outlined,
                  size: AppDims.iconInline),
              label: const Text('新建群聊'),
            ),
          ],
        ),
      ),
    );
  }

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
          child: Text(key,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textSecondary)),
        );
      }
      cursor++;
      if (index < cursor + items.length) {
        final e = items[index - cursor];
        final id = e.conversation.id;
        final expanded = _expandedId == id;
        return Column(
          children: [
            _chatRow(e, expanded),
            // 群项下方内联群卡片（第 6 轮 T03；与中栏会话列表同源挂点）。
            if (expanded)
              GroupSummaryCard(
                key: ValueKey('group-card-$id'),
                conversationId: id,
                group: widget.group,
                experts: widget.experts,
                conversations: widget.conversations,
                repos: widget.repos,
                onOpenConversation: widget.onOpenConversation,
              ),
            const Divider(height: 1, indent: 58),
          ],
        );
      }
      cursor += items.length;
    }
    return null;
  }

  /// 64px 群聊行（规格 4.2 会话项同规；展开态 = 选中态）。
  Widget _chatRow(InboxEntry e, bool expanded) {
    final id = e.conversation.id;
    return Stack(
      children: [
        Material(
          color: expanded ? AppColors.sessionSelected : Colors.transparent,
          child: InkWell(
            hoverColor: AppColors.bgSecondary,
            // 点群名：右栏聊天 + 中栏展开群卡片（再点收起）。
            onTap: () {
              setState(() => _expandedId = expanded ? null : id);
              if (!expanded) widget.onOpenConversation(id);
            },
            child: SizedBox(
              height: AppDims.sessionItemHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppDims.space3, vertical: 10),
                child: Row(
                  children: [
                    _groupAvatar(),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              // 群聊标签：名称前小字标签（规格 4.2）。
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: AppDims.space1, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.bgSecondary,
                                  borderRadius:
                                      BorderRadius.circular(AppDims.radiusS),
                                ),
                                child: const Text('群聊',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textTertiary)),
                              ),
                              const SizedBox(width: AppDims.space1),
                              Flexible(
                                child: Text(
                                  e.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.textPrimary),
                                ),
                              ),
                              if (e.conversation.pinned) ...[
                                const SizedBox(width: AppDims.space1),
                                const Icon(Icons.push_pin,
                                    size: 12, color: AppColors.textTertiary),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            e.snippet.isEmpty ? '（暂无消息）' : e.snippet,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppDims.space2),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: AppDims.iconInline,
                      color: AppColors.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 展开态左侧 2px 主色竖条（叠加层，不占内容宽度）。
        if (expanded)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 2,
            child: Container(color: AppColors.primary),
          ),
      ],
    );
  }

  /// 群头像（规格 4.2 / 冲突裁定 #6：方形圆角；群无对端专家 → 群组图标）。
  Widget _groupAvatar() {
    return Container(
      width: AppDims.avatarList,
      height: AppDims.avatarList,
      decoration: BoxDecoration(
        color: AppColors.bgTertiary,
        borderRadius: BorderRadius.circular(AppDims.radiusL),
      ),
      alignment: Alignment.center,
      child: const Icon(Icons.groups_outlined,
          size: AppDims.iconNav, color: AppColors.textSecondary),
    );
  }
}
