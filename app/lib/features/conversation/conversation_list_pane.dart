/// 会话列表（中栏 320px · 会话页签 · 规格 4.2 重样式，第 5 轮 B1）。
///
/// 数据来自 `ConversationService.listInbox()`（PRD §6.4）：
/// 排序 = **置顶优先 → 时间倒序**（`last_message_at ?? created_at`）；
/// 单聊标题 = 专家备注名（优先）?? 专家名；群聊标题 = `conversations.title`。
/// 点击列表项**直接续聊**（右栏打开 [会话视图]）。
///
/// 右键交互（用户 2026-10-02 走查）：单聊与群聊项均支持**鼠标右键菜单**
/// （`InkWell.onSecondaryTapDown`）——置顶 / 取消置顶、清空聊天记录、
/// 删除会话（后两项均有二次确认，文案写明不可恢复）；长按保留「一键置顶」。
/// 置顶项排最前（`listInbox`：置顶优先 → 时间倒序）并带 `Icons.push_pin` 标记。
///
/// 视觉（规格 4.2 逐项，数值不发挥）：
/// - 搜索栏 48px（左右内边距 12），搜索框 32px、圆角 8、背景 `#F7F8FA`、
///   无边框、占位符 12px/`#9CA3AF`；
/// - 会话项 64px（左右内边距 12、上下 10）：头像 36×36 圆角 12、
///   名称 14px/500 + 时间 11px/`#9CA3AF` 右对齐、摘要 12px 一行、
///   群聊标签（名称前 11px/`#9CA3AF` 底 `#F7F8FA` 圆角 4 内边距 2×4）；
/// - 选中态 背景 `#F0F2F8` + 左侧 2px 竖条 `#2E3A8C`；悬停态背景 `#F7F8FA`；
/// - 分割线 1px `#E5E7EB`，左边距 58px（对齐文字）。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import '../../ui/widgets/expert_avatar.dart';
import '../contacts/group_summary_card.dart';

/// 会话变更类型（删除 / 清空）——骨架层据此决定右栏如何处理。
enum ConversationMutation { cleared, deleted }

/// 会话变更回调：携带 [ConversationMutation] 区分「清空消息」与「删除会话」。
typedef ConversationMutated = void Function(
    String conversationId, ConversationMutation kind);

/// 会话列表。
class ConversationListPane extends StatefulWidget {
  const ConversationListPane({
    super.key,
    required this.conversations,
    required this.group,
    required this.experts,
    required this.repos,
    required this.onOpenConversation,
    this.selectedId,
    this.onConversationMutated,
  });

  final ConversationService conversations;
  final GroupService group;
  final ExpertService experts;
  final Repositories repos;

  /// 点击列表项 → 右栏打开该会话（续聊）。
  final ValueChanged<String> onOpenConversation;

  /// 当前选中的会话 id（骨架层传入，渲染 4.2 选中态；null = 无选中）。
  final String? selectedId;

  /// 会话被**删除 / 清空**后的回调（骨架层据此刷新右栏）。
  ///
  /// 走查修复 #66：此前删除/清空"当前正打开"的会话时，左栏刷新了，
  /// 右栏仍停在已删除会话上（或显示已清空的消息）。
  final ConversationMutated? onConversationMutated;

  @override
  State<ConversationListPane> createState() => _ConversationListPaneState();
}

class _ConversationListPaneState extends State<ConversationListPane> {
  List<InboxEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// 当前展开群卡片对应的会话 id（**单一展开原则**：父级持 id）。
  String? _expandedId;

  /// 单聊会话 id → 对端专家 id（供头像拟人化解析，第 6 轮 T05）。
  Map<String, String> _singlePeer = const {};

  /// 单聊会话 id → 对端专家的 emoji / 底色（第 #66 轮：市场包自带，可为 null）。
  Map<String, String?> _peerEmoji = const {};
  Map<String, String?> _peerColor = const {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.conversations.listInbox();
      // 单聊 → 对端专家 id（首名成员）；群聊无对端，跳过。
      final peers = <String, String>{};
      final emojis = <String, String?>{};
      final colors = <String, String?>{};
      for (final e in entries) {
        if (e.conversation.type == ConversationType.group) continue;
        final members =
            await widget.repos.conversations.listMembers(e.conversation.id);
        if (members.isEmpty) continue;
        final peerId = members.first.expertId;
        peers[e.conversation.id] = peerId;
        // 第 #66 轮：带出对端专家的 emoji 头像（市场包自带，可为 null →
        // ExpertAvatar 回退"首字 + 确定性色"，行为不变）。
        final peer = await widget.experts.get(peerId);
        emojis[e.conversation.id] = peer?.avatarEmoji;
        colors[e.conversation.id] = peer?.avatarColor;
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _singlePeer = peers;
        _peerEmoji = emojis;
        _peerColor = colors;
        _loading = false;
      });
    } on AppError catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '加载会话列表失败：$e';
        _loading = false;
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 置顶 / 取消置顶（服务层 `ConversationService.setPinned`；幂等）。
  ///
  /// 排序由 `listInbox` 保证：置顶优先 → 时间倒序；成功后整表重载。
  Future<void> _togglePin(InboxEntry e) async {
    try {
      await widget.conversations
          .setPinned(e.conversation.id, !e.conversation.pinned);
      await _reload();
    } on AppError catch (err) {
      _snack(err.message);
    } catch (err) {
      _snack('操作失败：$err');
    }
  }

  /// 右键（鼠标副键）会话项 → 会话菜单：置顶 / 取消置顶 · 清空聊天记录 · 删除会话。
  ///
  /// 单聊与群聊项共用；菜单位置跟随右键落点（[globalPosition]）。
  Future<void> _openSessionMenu(InboxEntry e, Offset globalPosition) async {
    final overlay = Offset.zero & MediaQuery.sizeOf(context);
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(globalPosition & Size.zero, overlay),
      items: [
        PopupMenuItem<String>(
          value: 'pin',
          child: Text(e.conversation.pinned ? '取消置顶' : '置顶'),
        ),
        const PopupMenuItem<String>(value: 'clear', child: Text('清空聊天记录')),
        PopupMenuItem<String>(
          value: 'delete',
          child: const Text('删除会话', style: TextStyle(color: AppColors.error)),
        ),
      ],
    );
    switch (picked) {
      case 'pin':
        await _togglePin(e);
      case 'clear':
        await _confirmClearMessages(e);
      case 'delete':
        await _confirmDeleteConversation(e);
      default:
        break; // 点空白处关闭菜单 → 无操作。
    }
  }

  /// 清空聊天记录（二次确认 → 服务层 → 列表刷新）。
  ///
  /// 确认文案写清后果：消息与附件一并删除且不可恢复，会话本身保留。
  Future<void> _confirmClearMessages(InboxEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空聊天记录'),
        content: const Text('将删除该会话的全部消息（含图片、文件附件），删除后不可恢复；'
            '会话本身会保留。确定要清空吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.conversations.clearMessages(e.conversation.id);
      _snack('已清空聊天记录');
      await _reload();
      widget.onConversationMutated
          ?.call(e.conversation.id, ConversationMutation.cleared);
    } on AppError catch (err) {
      _snack(err.message);
    } catch (err) {
      _snack('清空失败：$err');
    }
  }

  /// 删除会话（二次确认，文案明确不可恢复 → 服务层 → 列表刷新）。
  ///
  /// 连带消息 / 成员 / 群设置一并删除（DB 外键级联）；若右栏正打开该会话，
  /// 经 [ConversationListPane.onConversationMutated] 通知骨架层回空态。
  Future<void> _confirmDeleteConversation(InboxEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: const Text('将删除该会话及其全部消息、成员和群设置，删除后不可恢复。'
            '确定要删除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
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
      await widget.conversations.delete(e.conversation.id);
      _snack('已删除会话');
      await _reload();
      widget.onConversationMutated
          ?.call(e.conversation.id, ConversationMutation.deleted);
    } on AppError catch (err) {
      _snack(err.message);
    } catch (err) {
      _snack('删除失败：$err');
    }
  }

  String _formatTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final sameDay =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (sameDay) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }

  /// 前端过滤（搜索框关键词 → 标题 / 摘要；纯 UI，不动数据层）。
  List<InboxEntry> get _filtered {
    final k = _query.toLowerCase();
    if (k.isEmpty) return _entries;
    return _entries
        .where((e) =>
            e.title.toLowerCase().contains(k) ||
            e.snippet.toLowerCase().contains(k))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bgPrimary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _searchBar(),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  /// 顶部搜索栏：48px、左右内边距 12、搜索框 32px 圆角 8 背景 `#F7F8FA` 无边框。
  Widget _searchBar() {
    return SizedBox(
      height: AppDims.searchBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppDims.space3),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: AppDims.searchFieldHeight,
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v.trim()),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    filled: true,
                    fillColor: AppColors.bgSecondary,
                    hintText: '搜索会话、专家、内容…',
                    hintStyle: const TextStyle(
                        fontSize: 12, color: AppColors.textTertiary),
                    prefixIcon: const Icon(Icons.search,
                        size: AppDims.iconInline,
                        color: AppColors.textTertiary),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                    // 规格 4.2：搜索框边框无。
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppDims.radiusM),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppDims.radiusM),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppDims.radiusM),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh,
                  size: AppDims.iconNav, color: AppColors.textSecondary),
              onPressed: _reload,
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                style: const TextStyle(color: AppColors.error, fontSize: 12)),
            const SizedBox(height: AppDims.space2),
            TextButton(onPressed: _reload, child: const Text('重试')),
          ],
        ),
      );
    }
    final visible = _filtered;
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppDims.space6),
          child: Text(
            _query.isEmpty
                ? '还没有会话。\n\n去「通讯录」选择一位好友点「💬对话」，\n或在「群聊」页签新建群聊，让多位专家协作。'
                : '没有匹配「$_query」的会话。',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.textTertiary, height: 1.8, fontSize: 12),
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, indent: 58), // 分割线左边距 58px（对齐文字，规格 4.2）。
      itemBuilder: (_, i) {
        final e = visible[i];
        final isGroup = e.conversation.type == ConversationType.group;
        final expanded = isGroup && _expandedId == e.conversation.id;
        return Column(
          children: [
            _sessionItem(e),
            // 群项下方内联群卡片（第 6 轮 T03；保留挂点，B2 重样式不得移除）。
            if (expanded)
              GroupSummaryCard(
                key: ValueKey('group-card-${e.conversation.id}'),
                conversationId: e.conversation.id,
                group: widget.group,
                experts: widget.experts,
                conversations: widget.conversations,
                repos: widget.repos,
                onOpenConversation: widget.onOpenConversation,
              ),
          ],
        );
      },
    );
  }

  /// 64px 会话项（规格 4.2 逐项）。
  Widget _sessionItem(InboxEntry e) {
    final isGroup = e.conversation.type == ConversationType.group;
    final selected = widget.selectedId == e.conversation.id;
    return Stack(
      children: [
        Material(
          color: selected ? AppColors.sessionSelected : Colors.transparent,
          child: InkWell(
            hoverColor: AppColors.bgSecondary,
            // 点群项：右栏续聊 + 中栏展开群卡片（再点收起）；单聊直接续聊。
            // 「单一展开」：点另一好友/另一群时，前一张已展开的群卡片自动收回。
            onTap: () {
              widget.onOpenConversation(e.conversation.id);
              setState(() {
                if (isGroup) {
                  _expandedId = _expandedId == e.conversation.id
                      ? null
                      : e.conversation.id;
                } else {
                  _expandedId = null; // 点单聊好友 → 收回已展开的群卡片
                }
              });
            },
            // 右键（鼠标副键）→ 会话菜单（置顶 / 清空 / 删除）；单聊与群聊共用。
            onSecondaryTapDown: (d) => _openSessionMenu(e, d.globalPosition),
            onLongPress: () => _togglePin(e),
            child: SizedBox(
              height: AppDims.sessionItemHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppDims.space3, vertical: 10),
                child: Row(
                  children: [
                    _avatar(e, isGroup),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              // 群聊标签：名称前小字标签（规格 4.2）。
                              if (isGroup) ...[
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
                              ],
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
                            e.snippet.isEmpty ? '（暂无消息，点开即可开始）' : e.snippet,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppDims.space2),
                    Text(
                      _formatTime(e.sortAt),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 选中态左侧 2px 竖条 #2E3A8C（叠加层，不占内容宽度 → 内边距保持 12px）。
        if (selected)
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

  /// 头像（规格 4.2 / 冲突裁定 #6：方形圆角；第 6 轮 T05 拟人化）。
  ///
  /// 单聊 → [ExpertAvatar]（图片优先，缺图回退首字），**保持 B1 规格**：
  /// 36×36、圆角 12、底色 `bgTertiary`、字色 `textSecondary`；
  /// 群聊 → 维持群组图标（群无对端专家，无头像来源）。
  Widget _avatar(InboxEntry e, bool isGroup) {
    final size = AppDims.avatarList;
    if (isGroup) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.bgTertiary,
          borderRadius: BorderRadius.circular(AppDims.radiusL),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.groups_outlined,
            size: AppDims.iconNav, color: AppColors.textSecondary),
      );
    }
    final peerId = _singlePeer[e.conversation.id] ?? '';
    return ExpertAvatar(
      expertId: peerId,
      name: e.title,
      // 第 #66 轮：市场包自带 emoji 头像（本地图片 > emoji > 首字）。
      avatarEmoji: _peerEmoji[e.conversation.id],
      avatarColor: _peerColor[e.conversation.id],
      radius: size / 2,
      borderRadius: BorderRadius.circular(AppDims.radiusL),
      backgroundColor: AppColors.bgTertiary,
      foregroundColor: AppColors.textSecondary,
      fontSize: 15,
    );
  }
}
