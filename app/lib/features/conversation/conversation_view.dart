/// 会话视图（中栏 · 单聊 / 群聊）。
///
/// 复用 `GenerationService.runSingleChat` / `GroupService.runGroupChat` 流水线，
/// 按七类 [GenerationUpdate] 做流式渲染（穷尽 switch）：
///
/// - `RunStartedUpdate`    → 进入运行态；
/// - `StepStatusUpdate`    → 专家活动状态（思考中 / 准备发言 / 正在输入）；
/// - `DeltaUpdate`         → 流式增量追加（按 messageId 聚合）；
/// - `StepFinishedUpdate`  → 单专家完成（含跳过：Grounding 未命中 / 重复 / 跑题）；
/// - `SummaryUpdate`       → 总结已落库（重载后可见，此处仅确认）；
/// - `RunFinishedUpdate`   → 结束，**以数据库为准重载历史**；
/// - `RunFailedUpdate`     → 失败提示（可重试）；
/// - `SummaryFailedUpdate` → 总结失败提示（成员可能全成功但未产出纪要；可重试，6-B）。
///
/// **思考过程不显示**：`ReasoningDelta` 只存在于 `StreamEvent`（服务层已隔离落
/// `generation_events`，绝不进 `messages.content`），本 UI 的更新流中不存在该
/// 事件类型，天然满足「对话界面不显示思考过程」（PRD 裁定）。
///
/// 第 5 轮 B2 收尾：消息气泡 / 引用卡 / 输入栏分别下沉至 `message_bubble.dart` /
/// `citation_card.dart` / `chat_input_bar.dart`，本文件只做组装与状态逻辑；
/// 并办 #44（P2）：纪要缺失提示在 `_reload()` 成功后按数据库真值**历史重载**。
library;

import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
// 键盘事件 / 光标重组 API（`material.dart` 不导出 `services.dart`，按需显式导入）。
import 'package:flutter/services.dart';

import '../contacts/group_members_panel.dart';
import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_dims.dart';
import 'attachment_pick.dart';
import 'chat_input_bar.dart';
import 'mention_picker.dart';
import 'message_bubble.dart';

/// 流式中的消息缓冲。
class _StreamingMsg {
  // buffer 由声明处自行初始化（每条新消息缓冲各自 new 一个），
  // 构造函数不得再以参数赋值（final 声明时初始化后 Dart 禁止二次赋值）。
  _StreamingMsg({required this.expertId});

  final String expertId;
  final StringBuffer buffer = StringBuffer();

  String get text => buffer.toString();
}

/// 会话视图。
class ConversationView extends StatefulWidget {
  const ConversationView({
    super.key,
    required this.conversationId,
    required this.generation,
    required this.group,
    required this.conversations,
    required this.experts,
    required this.repos,
    required this.attachments,
    this.attachmentStore,
    required this.onBack,
  });

  final String conversationId;
  final GenerationService generation;
  final GroupService group;
  final ConversationService conversations;
  final ExpertService experts;
  final Repositories repos;

  /// 附件编排（第 8 轮：pending → save + insert）。
  final AttachmentService attachments;

  /// 附件物理存储（可选；仅用于「打开文件」判断存在性）。
  final AttachmentStore? attachmentStore;

  /// 返回会话列表。
  final VoidCallback onBack;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  List<Message> _history = const [];
  Map<String, String> _names = {}; // expertId → 展示名（备注优先）
  /// expertId → 市场包自带 emoji / 底色（第 #66 轮：气泡头像用，可为 null）。
  Map<String, String?> _avatarEmojis = {};
  Map<String, String?> _avatarColors = {};
  Conversation? _conversation;

  // -------------------------------------------------------------------------
  // 附件（第 8 轮 T04）
  // -------------------------------------------------------------------------

  /// 待发送附件（阶段① 产物：**不落盘不落库**）。
  final List<PendingAttachment> _pending = [];

  /// messageId → 附件（_reload 时**批量预载**，防 N+1）。
  final Map<String, List<Attachment>> _attachments = {};

  /// messageId → 知识库引用（B2 §4.3.3：_reload 时按 messageId 补拉，纯 UI 接线）。
  final Map<String, List<Citation>> _citations = {};

  final Map<String, _StreamingMsg> _streaming = {};
  final Map<String, String> _activities = {}; // expertId → 活动文案
  final Map<String, ({int count, bool skipped, String? reason})> _finished = {};
  String? _runError;

  /// 总结失败提示（6-B）：与 [_runError]（运行级失败）、成员气泡失败**各自独立**，可同现。
  ///
  /// 流式由 `SummaryFailedUpdate` 置位；#44 起 `_reload()` 成功后另按数据库真值
  /// （最近一次 group run 的 synthesis step == failed）**历史重载**，重进会话不丢。
  String? _summaryError;
  bool _running = false;
  bool _loading = true;
  bool _sending = false;

  /// 删除消息进行中（防重复点击；服务层另有 fail-closed 二次校验）。
  bool _deleting = false;

  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  /// 输入框焦点节点（保留引用：发送后需要把焦点交回输入框，支持连续发送）。
  ///
  /// `onKeyEvent` 直接挂在**输入框自身的 FocusNode** 上（而非外层 `Focus` 祖先）：
  /// 按键分发顺序为 **primaryFocus 节点 → 祖先链**（SDK `focus_manager.dart`
  /// L2263–2268），挂在自身节点上可保证在默认换行行为之前拦截，确定可控。
  /// 于 `initState` 装配（Dart 禁止在字段初始化器里隐式引用 `this` 成员）。
  late final FocusNode _inputFocus;

  // -------------------------------------------------------------------------
  // @成员选择器（第 7 轮走查 E-2 · 仅群聊）
  // -------------------------------------------------------------------------

  bool _mentionOpen = false;

  /// `@` 之后的过滤词（主输入框光标所在词 与 面板过滤框 的同一真相源）。
  String _mentionQuery = '';

  /// 当前高亮候选下标。
  int _mentionIndex = 0;

  final _mentionFilterCtrl = TextEditingController();

  /// 面板过滤框焦点：据此区分"焦点移入面板"（面板不关）与"焦点离开整个输入区"（关）。
  late final FocusNode _mentionFilterFocus;

  /// expertId → 群内角色（供角色徽标）。
  final Map<String, MemberRole> _memberRoles = {};

  StreamSubscription<GenerationUpdate>? _sub;

  bool get _isGroup => _conversation?.type == ConversationType.group;

  String? get _welcome {
    if (_isGroup || _history.isNotEmpty) return null;
    // 单聊空会话：展示首位成员的欢迎语（如已配置）。
    return _welcomeCache;
  }

  String? _welcomeCache;

  @override
  void initState() {
    super.initState();
    _inputFocus = FocusNode(onKeyEvent: _onInputKeyEvent);
    _mentionFilterFocus = FocusNode(onKeyEvent: _onMentionFilterKeyEvent);
    // FocusNode 无 onFocusChange 参数（见 SDK focus_manager.dart L455）→ 用监听 + hasFocus。
    _mentionFilterFocus.addListener(_onMentionFilterFocusChanged);
    // 监听主输入框：`@` 词出现 / 消失 / 变化 → 驱动面板开关与过滤。
    _inputCtrl.addListener(_syncMentionFromInput);
    _inputFocus.addListener(_onInputFocusChanged);
    _reload();
  }

  @override
  void didUpdateWidget(covariant ConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _closeMention();
      _sub?.cancel();
      _sub = null;
      _streaming.clear();
      _activities.clear();
      _finished.clear();
      _runError = null;
      _summaryError = null;
      _running = false;
      _welcomeCache = null;
      _reload();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _inputCtrl.removeListener(_syncMentionFromInput);
    _inputCtrl.dispose();
    _inputFocus.removeListener(_onInputFocusChanged);
    _inputFocus.dispose();
    _mentionFilterCtrl.dispose();
    _mentionFilterFocus.removeListener(_onMentionFilterFocusChanged);
    _mentionFilterFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final conv = await widget.repos.conversations
          .getConversation(widget.conversationId);
      // 批量预载消息 + 附件（一次 IN 查询，防 N+1）。
      final withAttachments = await widget.conversations
          .listMessagesWithAttachments(widget.conversationId, limit: 200);
      final msgs = withAttachments.keys.toList();
      final members =
          await widget.repos.conversations.listMembers(widget.conversationId);
      final names = <String, String>{};
      final avatarEmojis = <String, String?>{};
      final avatarColors = <String, String?>{};
      final roles = <String, MemberRole>{};
      String? welcome;
      for (final m in members) {
        roles[m.expertId] = m.role;
        final e = await widget.experts.get(m.expertId);
        if (e == null) {
          names[m.expertId] = m.expertId;
          avatarEmojis[m.expertId] = null;
          avatarColors[m.expertId] = null;
          continue;
        }
        final state = await widget.repos.experts.getUserState(m.expertId);
        names[m.expertId] = EffectiveExpertConfig.resolveName(e, state);
        // 第 #66 轮：带出专家 emoji 头像（市场包自带；未安装过为 null →
        // 气泡头像回退"首字 + 确定性色"，行为不变）。
        avatarEmojis[m.expertId] = e.avatarEmoji;
        avatarColors[m.expertId] = e.avatarColor;
        if (welcome == null && conv?.type == ConversationType.single) {
          final w = e.welcomeMessage?.trim() ?? '';
          if (w.isNotEmpty) welcome = w;
        }
      }
      // B2（规格 §4.3.3）：历史专家消息的知识库引用补拉。端口
      // （`MessageRepository.listCitations`）仅支持按 messageId 单查，core/storage
      // 零改动；本轮页内专家消息逐条拉取（均为索引查询，成本可接受）。
      final citations = <String, List<Citation>>{};
      for (final m in msgs) {
        if (!m.isFromExpert) continue;
        try {
          final cs = await widget.repos.messages.listCitations(m.id);
          if (cs.isNotEmpty) citations[m.id] = cs;
        } catch (_) {
          // 单条引用拉取失败不阻断会话加载（容错口径同 #44 纪要提示）。
        }
      }
      if (!mounted) return;
      setState(() {
        _conversation = conv;
        _history = msgs;
        _attachments
          ..clear()
          ..addAll(
              {for (final e in withAttachments.entries) e.key.id: e.value});
        _citations
          ..clear()
          ..addAll(citations);
        _names = names;
        _avatarEmojis = avatarEmojis;
        _avatarColors = avatarColors;
        _memberRoles
          ..clear()
          ..addAll(roles);
        _welcomeCache = welcome;
        // 运行结束后以数据库为准：清空流式缓冲。
        if (!_running) {
          _streaming.clear();
          _activities.clear();
          _finished.clear();
        }
        _loading = false;
      });
      // #44（P2 解冻）：纪要缺失提示的历史重载（重载成功后按数据库真值补置）。
      await _refreshSummaryErrorFromDb();
      _scrollToBottom();
    } on AppError catch (e) {
      setState(() {
        _loading = false;
        _runError = e.message;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _runError = '加载会话失败：$e';
      });
    }
  }

  /// #44（P2 解冻）：纪要缺失提示的**历史重载**。
  ///
  /// 流式 `SummaryFailedUpdate` 置位的 [_summaryError] 只是**内存态**——重进会话 /
  /// 重启后提示消失；而数据库里「最近一次 group run 的 synthesis step == failed」
  /// 仍是事实。本方法在 `_reload()` **成功后**按真值补置（文案与流式逐字一致），
  /// 使「本轮未产出会议纪要」提示可"重现有"。
  ///
  /// 判定刻意**便宜**：只取最近 1 次 run、只看它有没有 `stage == synthesis` 的
  /// failed step；查不到 / 异常 → 不显示（**不抛、不阻断加载**）；单聊会话不判
  /// （`_isGroup` 才判；synthesis 步骤本就只存在于群聊 run）。
  /// 与成员气泡失败（§2.6）各自独立、可同现。
  Future<void> _refreshSummaryErrorFromDb() async {
    if (!_isGroup) return;
    try {
      final runs =
          await widget.repos.generations.listRuns(widget.conversationId);
      if (runs.isEmpty) return;
      // SQLite 实现按 started_at 倒序（advisor_storage listRuns）→ 取最近一次。
      final latest = runs.first;
      if (latest.runType != RunType.groupChat) return;
      final steps = await widget.repos.generations.listSteps(latest.id);
      GenerationStep? failedSynth;
      for (final s in steps) {
        if (s.stage == StepStage.synthesis && s.status == RunStatus.failed) {
          failedSynth = s;
          break;
        }
      }
      if (failedSynth == null) return;
      final message =
          '本轮未产出会议纪要（总结失败：${failedSynth.errorMessage ?? '未知原因'}）。可重试。';
      if (!mounted) return;
      setState(() => _summaryError = message);
    } catch (_) {
      // 查不到 / 异常 → 不显示，不阻断加载。
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // -------------------------------------------------------------------------
  // 发送
  // -------------------------------------------------------------------------

  /// 输入框按键：**Enter 发送 / Shift(Ctrl|Alt|Meta)+Enter 换行**（微信逻辑，走查 E-1）。
  ///
  /// - 修饰键按下 → 手动把 `\n` 插入 controller 并保持光标（**不依赖 `textInputAction`**）；
  /// - 裸 Enter → 触发 [_send]（输入为空 / 运行中时不发送，也**不插空行**，见方法尾注）；
  /// - `_running` / `_sending` 期间 → 不发送但**允许继续输入**（返回 ignored，交回默认处理）。
  ///
  /// **@面板打开时本方法优先接管**（走查 E-2）：`Enter`/`Tab` = 选中而非发送，
  /// 同一按键**不会**既发送又选中。
  KeyEventResult _onInputKeyEvent(FocusNode node, KeyEvent event) {
    if (_mentionOpen) {
      final r = _handleMentionKey(event, _mentionFiltered.length);
      if (r != null) return r;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // Ctrl+V 粘贴（走查第四批 ③）：本机 Flutter SDK 无剪贴板图片 API（读不到
    // 图片字节，详见 [_onPasteKeyDown] 文档）→ 文本粘贴交回默认行为（本方法
    // 返回 ignored，TextField 自行插入，**不拦截**）；无文本（剪贴板为图片 /
    // 空）时由异步回调 SnackBar 明示（**不静默**）。
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        HardwareKeyboard.instance.isControlPressed) {
      _onPasteKeyDown();
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter)
      return KeyEventResult.ignored;

    final kb = HardwareKeyboard.instance;
    final wantNewline = kb.isShiftPressed ||
        kb.isControlPressed ||
        kb.isMetaPressed ||
        kb.isAltPressed;
    if (wantNewline) {
      _insertNewline();
      return KeyEventResult.handled;
    }

    if (_inputCtrl.text.trim().isNotEmpty && !_running && !_sending) {
      _send();
      return KeyEventResult.handled;
    }
    // 空输入 / 生成中：**吞掉这一个 Enter** —— 不发送、也不插空行（微信行为）。
    // 注意：`TextField(maxLines:4)` 且未设 textInputAction 时默认 inputAction 就是
    // `TextInputAction.newline`（SDK: editable_text.dart:5271），若此处返回 ignored，
    // 框架默认行为会插入一个空行。两个早退分支（非 KeyDown / 非 Enter）仍返回 ignored，
    // 不影响方向键、Tab 等其它按键。
    return KeyEventResult.handled;
  }

  /// 在光标处插入换行并保持光标位置（重组 `TextEditingValue`）。
  void _insertNewline() {
    final value = _inputCtrl.value;
    final text = value.text;
    // selection 可能无效（offset: -1）；此时退化为追加到末尾。
    final int start =
        value.selection.start >= 0 && value.selection.start <= text.length
            ? value.selection.start
            : text.length;
    final int end = value.selection.end >= 0 &&
            value.selection.end <= text.length &&
            value.selection.end >= start
        ? value.selection.end
        : start;
    final next = text.replaceRange(start, end, '\n');
    _inputCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  /// Ctrl+V 粘贴键的异步处理（走查第四批 ③·对话框粘贴图片）。
  ///
  /// **本机 SDK 事实（2026-10-02 grep 验证，不许假装实现）**：Flutter 3.44.6 /
  /// Dart 3.12.2 的 `services/clipboard.dart` 只有 `ClipboardData(text:)` 与
  /// `Clipboard.kTextPlain`——**没有** `kImagePlain` / `ClipboardImageData`，
  /// 也没有 `clipboard_reader.dart`（全框架 grep 零命中）；`KeyboardInsertedContent`
  /// 仅服务 Android / iOS 虚拟键盘的内容插入，Windows 桌面 Ctrl+V 不触发。
  /// **剪贴板图片字节在框架层无法取得**，故本方法做诚实降级（不静默）：
  ///
  /// 1. 剪贴板有文本 → 直接返回：默认粘贴已在同步路径插入文本（不拦截）；
  /// 2. 剪贴板无文本（图片 / 空 / 读取失败）→ SnackBar 明示原因，并指引用
  ///    输入框上方 📎 按钮选图（白名单 png/jpg/jpeg/gif/webp/bmp、单文件
  ///    ≤20MB，均由既有 `AttachmentPolicy` + `AttachmentService.draft` 把关）。
  ///
  /// 异步但无并发风险：连续多次 Ctrl+V 最多叠几条 SnackBar（各自带原因，
  /// 不会被吞）；粘贴路径本身不依赖本方法的返回值。
  Future<void> _onPasteKeyDown() async {
    String? text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text;
    } catch (_) {
      // 读取失败等同"没有可粘贴内容"：同样走明示分支，不静默。
      text = null;
    }
    if (text != null && text.trim().isNotEmpty) return;
    if (!mounted) return;
    _snack('剪贴板中没有可粘贴的文本。如需发送图片，请点输入框上方的 📎 按钮'
        '选择图片文件（支持 png / jpg / jpeg / gif / webp / bmp，单个不超过 20MB）。'
        '当前 Flutter SDK 暂不支持读取剪贴板图片。');
  }

  // -------------------------------------------------------------------------
  // @成员选择器逻辑（第 7 轮走查 E-2）
  // -------------------------------------------------------------------------

  /// 光标所在「词」是否为 @提及；返回 `(词文本, 起点)`，否则 null。
  ///
  /// 词边界 = 空白符（空格 / 换行 / Tab）。`@` 必须位于词首才视为提及。
  ({String token, int start})? _mentionTokenAt() {
    final value = _inputCtrl.value;
    final text = value.text;
    final cursor =
        value.selection.start >= 0 && value.selection.start <= text.length
            ? value.selection.start
            : text.length;
    var start = cursor;
    while (start > 0 && !_isWordBoundary(text[start - 1])) {
      start--;
    }
    final token = text.substring(start, cursor);
    if (!token.startsWith('@')) return null;
    return (token: token, start: start);
  }

  bool _isWordBoundary(String ch) => ch == ' ' || ch == '\n' || ch == '\t';

  /// 主输入框变化 → 面板开关与过滤词同步（**仅群聊**）。
  void _syncMentionFromInput() {
    if (!_isGroup) {
      if (_mentionOpen) _closeMention();
      return;
    }
    final at = _mentionTokenAt();
    if (at == null) {
      // 删掉 `@` / 词边界变化 → 关面板（requirement：删掉 @ 即关）。
      _closeMention();
      return;
    }
    final q = at.token.substring(1);
    if (!_mentionOpen) {
      setState(() {
        _mentionOpen = true;
        _mentionQuery = q;
        _mentionIndex = 0;
      });
      _mentionFilterCtrl.text = q;
      return;
    }
    if (_mentionQuery == q) return;
    setState(() {
      _mentionQuery = q;
      _mentionIndex = 0;
    });
    // 过滤框未被聚焦时才同步，避免抢用户正在过滤框里的输入。
    if (!_mentionFilterFocus.hasFocus) _mentionFilterCtrl.text = q;
  }

  /// 候选（群成员；`conversation_members` 只含专家，**天然不含用户自己**；按显示名去重）。
  List<MentionCandidate> get _mentionAll {
    final seen = <String>{};
    final out = <MentionCandidate>[];
    for (final e in _names.entries) {
      final name = e.value.trim();
      if (name.isEmpty) continue;
      if (!seen.add(name)) continue;
      out.add(MentionCandidate(
        expertId: e.key,
        name: name,
        role: _memberRoles[e.key] ?? MemberRole.member,
        // 第 #66 轮：@ 面板头像也用市场包自带 emoji（可为 null → 回退首字）。
        avatarEmoji: _avatarEmojis[e.key],
        avatarColor: _avatarColors[e.key],
      ));
    }
    return out;
  }

  /// 过滤后的候选（命中显示名子串，大小写不敏感；空词 = 全部）。
  List<MentionCandidate> get _mentionFiltered {
    final q = _mentionQuery.trim().toLowerCase();
    if (q.isEmpty) return _mentionAll;
    return _mentionAll.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  void _closeMention() {
    if (!_mentionOpen) return;
    setState(() {
      _mentionOpen = false;
      _mentionQuery = '';
      _mentionIndex = 0;
    });
  }

  /// 把光标处的 `@半截词` 替换为 `@<显示名> `（尾随空格），光标移到末尾，关闭面板。
  void _selectMention(int index) {
    final list = _mentionFiltered;
    if (index < 0 || index >= list.length) return;
    final picked = list[index];
    final at = _mentionTokenAt();
    final value = _inputCtrl.value;
    final text = value.text;
    final cursor =
        value.selection.start >= 0 && value.selection.start <= text.length
            ? value.selection.start
            : text.length;
    final start = at?.start ?? cursor;
    final replacement = '@${picked.name} ';
    final next = text.replaceRange(start, cursor, replacement);
    _inputCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
    _closeMention();
    // 选中后焦点交回输入框，可继续打字。
    _inputFocus.requestFocus();
  }

  /// @面板键位处理（主输入框持焦路径）；返回 null 表示"非面板键，交回后续默认逻辑"。
  KeyEventResult? _handleMentionKey(KeyEvent event, int count) {
    if (event is! KeyDownEvent) return null;
    if (count <= 0) {
      // 无候选：仅 Esc 可关，其余交给默认（避免 Enter 发送含 `@` 的半截消息）。
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        _closeMention();
        return KeyEventResult.handled;
      }
      return null;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        setState(() => _mentionIndex = (_mentionIndex - 1 + count) % count);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        setState(() => _mentionIndex = (_mentionIndex + 1) % count);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.tab:
        _selectMention(_mentionIndex);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        _closeMention();
        return KeyEventResult.handled;
      default:
        return null;
    }
  }

  /// @面板过滤框键位处理（过滤框持焦路径）。
  KeyEventResult _onMentionFilterKeyEvent(FocusNode node, KeyEvent event) {
    final r = _handleMentionKey(event, _mentionFiltered.length);
    if (r != null) return r;
    // 过滤框内 Enter 不上抛为发送；Esc 已由上面处理。
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// @面板变更回调（过滤词变化）。
  void _onMentionFilterChanged(String value) {
    if (_mentionQuery == value) return;
    setState(() {
      _mentionQuery = value;
      _mentionIndex = 0;
    });
  }

  /// @面板过滤框焦点变化：过滤框失焦且主输入框也未持焦 → 关闭面板。
  void _onMentionFilterFocusChanged() => _closeMentionIfFocusLeft();

  /// 主输入框焦点变化：失去焦点且过滤框也未持焦 → 关闭面板。
  void _onInputFocusChanged() => _closeMentionIfFocusLeft();

  /// 焦点**真的离开整个输入区**才关面板。
  ///
  /// 焦点转移（主输入框 ↔ 过滤框）过程中，两个节点监听回调的触发顺序**不确定**；
  /// 若立即判定会把"焦点移入面板"误判为失焦而关面板 → 延后到帧末再判一次。
  void _closeMentionIfFocusLeft() {
    if (_inputFocus.hasFocus || _mentionFilterFocus.hasFocus) return;
    if (!_mentionOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_inputFocus.hasFocus || _mentionFilterFocus.hasFocus) return;
      _closeMention();
    });
  }

  // -------------------------------------------------------------------------
  // 附件（第 8 轮 T04）：选择 / 移除 / 重试 / 发送
  // -------------------------------------------------------------------------

  /// 打开文件选择器 → 纯校验 → 进 pending（**不落盘不落库**）。
  Future<void> _pickAttachments() async {
    List<PendingAttachment> picked;
    try {
      picked = await pickAttachments();
    } on AppError catch (e) {
      _snack(e.message);
      return;
    } catch (e) {
      _snack('选择附件失败：$e');
      return;
    }
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _pending.addAll(picked);
      _runError = null;
    });
  }

  /// 移除 pending（"取消"：不预复制，故移除即什么都没发生过）。
  void _removePending(PendingAttachment p) {
    if (!p.canRemove) return;
    setState(() => _pending.remove(p));
  }

  /// 重试：把 `failed` 态复位为 `ready`（下一次发送随消息一起重试）。
  void _retryPending(PendingAttachment p) {
    final i = _pending.indexOf(p);
    if (i < 0) return;
    setState(() => _pending[i] = p.copyWith(
          status: PendingAttachmentStatus.ready,
          error: null,
        ));
  }

  /// 阶段②：对消息的每个 pending 执行 save + insert。
  ///
  /// **失败隔离（架构 §1.1 / 共享约定 4）**：单个附件失败**不抛异常、不影响消息已发出**——
  /// 该条留在 pending 列表里带红字原因（可重试 / 可移除）。
  Future<void> _sendAttachments(String messageId) async {
    if (_pending.isEmpty) return;
    final snapshot = List<PendingAttachment>.from(_pending);
    final remaining = <PendingAttachment>[];
    for (final p in snapshot) {
      if (p.status == PendingAttachmentStatus.rejected) {
        remaining.add(p); // 选择即被拒：不重试，留着明示原因。
        continue;
      }
      final outcome =
          await widget.attachments.send(messageId: messageId, pending: p);
      if (outcome.attachment != null) continue;
      remaining.add(outcome.pending);
    }
    if (!mounted) return;
    setState(() => _pending
      ..clear()
      ..addAll(remaining));
    if (remaining.isNotEmpty) {
      _snack('有 ${remaining.length} 个附件未发送成功，已在待发送列表中标记原因');
    }
  }

  Future<void> _send() async {
    var text = _inputCtrl.text.trim();
    // 微信逻辑：有文字即可发；**有待发附件时允许"纯附件发送"**（文字可空）。
    // 两者皆空 → 不发送（修 2026-10-02 走查缺陷：只选文件不打字时整条发送被拦死）。
    if ((text.isEmpty && _pending.isEmpty) || _running || _sending) return;
    if (text.isEmpty && _pending.isNotEmpty) {
      // 纯附件消息给一句占位正文：让人看得懂、也让人/模型知道本轮有附件。
      text = '（发送了 ${_pending.length} 个附件）';
    }
    setState(() => _sending = true);
    try {
      final userMsg = await widget.conversations
          .appendUserMessage(widget.conversationId, text);
      // 本地立即上屏（重载后与数据库一致）。
      setState(() {
        _history = [..._history, userMsg];
        _runError = null;
      });
      // 阶段②：附件 save + insert（**失败隔离**：附件失败不影响消息已发出）。
      await _sendAttachments(userMsg.id);
      _inputCtrl.clear();
      // 发送后焦点交回输入框（微信体验：可连续发送）。
      _inputFocus.requestFocus();
      _scrollToBottom();

      final stream = _isGroup
          ? widget.group.runGroupChat(
              conversationId: widget.conversationId,
              userMessageId: userMsg.id,
              userText: text,
            )
          : widget.generation.runSingleChat(
              conversationId: widget.conversationId,
              userMessageId: userMsg.id,
              userText: text,
            );

      setState(() => _running = true);
      await _sub?.cancel();
      _sub = stream.listen(_onUpdate, onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _running = false;
          _runError = '生成失败：$e';
        });
      }, onDone: () {
        if (mounted) setState(() => _running = false);
      });
    } on AppError catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('发送失败：$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 八类更新：穷尽 switch（漏一个都编不过，防未来扩展被静默吞掉）。
  void _onUpdate(GenerationUpdate u) {
    if (!mounted) return;
    switch (u) {
      case RunStartedUpdate(:final run):
        setState(() {
          _running = true;
          _runError = null;
          _summaryError = null;
        });
        debugPrint('运行开始：${run.id}');
      case StepStatusUpdate(:final expertId, :final activity):
        setState(() => _activities[expertId] = activity.label);
      case DeltaUpdate(:final messageId, :final expertId, :final text):
        final msg = _streaming.putIfAbsent(
          messageId,
          () => _StreamingMsg(expertId: expertId),
        );
        msg.buffer.write(text);
        setState(() => _activities[expertId] = '正在输入');
        _scrollToBottom();
      case StepFinishedUpdate(
          :final messageId,
          :final expertId,
          :final citations,
          :final skipped,
          :final skipReason,
        ):
        setState(() {
          _activities.remove(expertId);
          _streaming.remove(messageId);
          _finished[messageId] = (
            count: citations.length,
            skipped: skipped,
            reason: skipReason,
          );
        });
      case SummaryUpdate(:final messageId, :final summary):
        // 总结消息已由服务层落库；等 RunFinished 后重载历史即可见。
        debugPrint('总结已产出：$messageId（${summary.recommendations.length} 条建议）');
      case RunFinishedUpdate():
        setState(() {
          _running = false;
          _activities.clear();
          _streaming.clear();
        });
        _reload();
      case RunFailedUpdate(:final error):
        setState(() {
          _running = false;
          _runError = '生成失败：${error.message}（${error.code}）';
        });
        _reload();
      case SummaryFailedUpdate(:final error):
        // 6-B：成员可能全部成功，但本轮未产出纪要——**必须显式提示，不得静默**。
        // 与 [_runError]（运行级失败）各自独立渲染，可同现；不渲染成空白气泡。
        setState(() {
          _running = false;
          _summaryError = '本轮未产出会议纪要（总结失败：${error.message}）。可重试。';
        });
        _reload();
    }
  }

  // -------------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final title = _conversation == null
        ? '会话'
        : (_isGroup
            ? (_conversation!.title?.trim().isEmpty ?? true
                ? '未命名群聊'
                : _conversation!.title!)
            : (_names.values.isEmpty ? '单聊' : _names.values.first));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(title),
        const Divider(height: 1),
        Expanded(child: _body()),
        const Divider(height: 1),
        ChatInputBar(
          isGroup: _isGroup,
          running: _running,
          sending: _sending,
          onSend: _send,
          inputController: _inputCtrl,
          inputFocus: _inputFocus,
          onPickAttachments: _pickAttachments,
          onOpenMention: _openMentionFromButton,
          pending: _pending,
          onRemovePending: _removePending,
          onRetryPending: _retryPending,
          mentionOpen: _mentionOpen,
          mentionCandidates: _mentionFiltered,
          mentionSelectedIndex: _mentionIndex,
          mentionFilterController: _mentionFilterCtrl,
          mentionFilterFocus: _mentionFilterFocus,
          onMentionSelectedIndex: (i) => setState(() => _mentionIndex = i),
          onMentionConfirmed: () => _selectMention(_mentionIndex),
          onMentionFilterChanged: _onMentionFilterChanged,
        ),
      ],
    );
  }

  Widget _header(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回会话列表',
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: widget.onBack,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F0F0),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(_isGroup ? '群聊' : '单聊',
                      style:
                          const TextStyle(fontSize: 10, color: Colors.black45)),
                ),
              ],
            ),
          ),
          if (_isGroup)
            TextButton.icon(
              onPressed: _openMembers,
              icon: const Icon(Icons.group_outlined, size: 18),
              label: Text('群成员（${_names.length}）',
                  style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Future<void> _openMembers() async {
    await showDialog<void>(
      context: context,
      builder: (_) => GroupMembersPanel(
        conversationId: widget.conversationId,
        group: widget.group,
        experts: widget.experts,
        repos: widget.repos,
      ),
    );
    await _reload();
  }

  Widget _body() {
    if (_loading && _history.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    final children = <Widget>[];

    final w = _welcome;
    if (w != null) {
      children.add(_systemBubble(w));
    }
    // 历史消息：时间分割线（首条 / 间隔 > [kTimeDividerGapMs]）+
    // 消息气泡（同一人连续 8、不同人 16，判据 = 上一条 senderType/senderId）。
    Message? prevMsg;
    ({MessageSenderType type, String? id})? prevKey;
    for (final m in _history) {
      final gap = prevMsg == null ? null : m.createdAt - prevMsg.createdAt;
      if (prevMsg == null || gap! > kTimeDividerGapMs) {
        children.add(TimeDivider(timestamp: m.createdAt));
      }
      children.add(_messageBubble(m,
          continuousWithPrevious: prevKey == _senderKeyOf(m)));
      prevMsg = m;
      prevKey = _senderKeyOf(m);
    }
    // 流式中的消息（与上一条（历史或流式）同一人 → 连续间距）。
    for (final entry in _streaming.entries) {
      final key = (type: MessageSenderType.expert, id: entry.value.expertId);
      children.add(MessageBubble(
        isFromUser: false,
        content: entry.value.text,
        expertId: entry.value.expertId,
        expertName: _names[entry.value.expertId] ?? entry.value.expertId,
        avatarEmoji: _avatarEmojis[entry.value.expertId],
        avatarColor: _avatarColors[entry.value.expertId],
        continuousWithPrevious: prevKey == key,
      ));
      prevKey = key;
    }
    // 专家活动状态行。
    if (_activities.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Wrap(
          spacing: 12,
          children: _activities.entries
              .map((e) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5)),
                      const SizedBox(width: 6),
                      Text('${_names[e.key] ?? e.key} ${e.value}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.black45)),
                    ],
                  ))
              .toList(),
        ),
      ));
    }
    // 失败提示。
    if (_runError != null) {
      children.add(_errorBanner(_runError!));
    }
    // 总结失败提示（6-B / #44）：置于消息流末尾（输入框之上），与运行级失败各自独立、可同现。
    if (_summaryError != null) {
      children.add(_errorBanner(_summaryError!));
    }
    if (children.isEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.all(24),
        child: Text('说点什么吧 ↓',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black38)),
      ));
    }

    return ListView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: children,
    );
  }

  /// 连续性键：同一人 = senderType + senderId 均同（规格 §4.3.2 消息间距判据）。
  ({MessageSenderType type, String? id}) _senderKeyOf(Message m) =>
      (type: m.senderType, id: m.senderId);

  Widget _systemBubble(String text) {
    return Align(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F4F4),
          borderRadius: BorderRadius.circular(10),
        ),
        constraints: const BoxConstraints(maxWidth: 480),
        child: Text(text,
            style: const TextStyle(fontSize: 12, color: Colors.black54)),
      ),
    );
  }

  Widget _errorBanner(String text) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFDECEC),
        borderRadius: BorderRadius.circular(AppDims.radiusM),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Colors.redAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
          ),
          TextButton(
            onPressed: _reload,
            child: const Text('刷新', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 消息删除（第 8 轮 T04；铁律：只允许删用户自己发的消息）
  // -------------------------------------------------------------------------

  /// 打开消息菜单（复制 / 删除）。
  Future<void> _openMessageMenu(Message m) async {
    if (!m.isFromUser || _deleting) return;
    // 只有用户消息才走到这里（专家消息的 Widget 上根本没有手势）。
    final overlay = Offset.zero & MediaQuery.sizeOf(context);
    final box = context.findRenderObject();
    final anchor =
        box is RenderBox ? box.localToGlobal(Offset.zero) & box.size : overlay;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(anchor, overlay),
      items: const [
        PopupMenuItem<String>(value: 'copy', child: Text('复制消息')),
        PopupMenuItem<String>(value: 'delete', child: Text('删除消息')),
      ],
    );
    if (picked == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.content));
      _snack('已复制');
      return;
    }
    if (picked == 'delete') await _confirmDeleteMessage(m);
  }

  /// 二次确认（文案与主理人裁定逐字一致）。
  Future<void> _confirmDeleteMessage(Message m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息'),
        content: const Text('删除后不可恢复；该消息的知识库引用记录将保留（历史不可变）。'),
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
    await _deleteMessage(m);
  }

  /// 执行删除（服务层三级校验 + 双清 + 物理文件引用计数 GC）。
  Future<void> _deleteMessage(Message m) async {
    if (_deleting) return;
    setState(() => _deleting = true);
    try {
      final res =
          await widget.conversations.deleteMessage(widget.conversationId, m.id);
      _snack(res.removedAttachments > 0
          ? '已删除消息及其 ${res.removedAttachments} 个附件'
          : '已删除消息');
      await _reload();
    } on AppError catch (e) {
      // 含铁律拒绝（专家消息不可删 / 消息不存在 / 跨会话）。
      _snack(e.message);
    } catch (e) {
      _snack('删除失败：$e');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  // -------------------------------------------------------------------------
  // 消息渲染（B2：下沉 message_bubble.dart，本方法只做分派）
  // -------------------------------------------------------------------------

  Widget _messageBubble(Message m, {required bool continuousWithPrevious}) {
    // 静默契约（第 6 轮）：成员自判「与自身专业无关」→ 消息 cancelled 且正文清空，
    // **不渲染气泡**，仅以极淡系统行提示「未参与」（否则"不参与"本身又成刷屏源）。
    // **failed 优先**：失败态（含空正文）必须出明确失败提示（由 MessageBubble 内部
    // 按 status 渲染），不得落入本分支被误判为"未参与"（契约 §2.6 的既有次序）。
    if (m.status != MessageStatus.failed &&
        m.status == MessageStatus.cancelled &&
        m.content.trim().isEmpty) {
      return Align(
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text('${_names[m.senderId ?? ''] ?? m.senderId ?? ''} 未参与本次讨论',
              style: const TextStyle(fontSize: 11, color: Colors.black26)),
        ),
      );
    }

    if (m.isFromUser) {
      final atts = _attachments[m.id] ?? const <Attachment>[];
      return MessageBubble(
        isFromUser: true,
        content: m.content,
        status: m.status,
        attachments: atts,
        continuousWithPrevious: continuousWithPrevious,
        // 长按 / 右键 → 消息菜单（**仅用户自己的消息**；专家消息不传手势，
        // 服务层 deleteMessage 另有 fail-closed 二次拒绝——双保险）。
        onLongPress: _deleting ? null : () => _openMessageMenu(m),
        onSecondaryTap: _deleting ? null : () => _openMessageMenu(m),
        onAttachmentsChanged: _reload,
      );
    }

    final expertId = m.senderId ?? '';
    return MessageBubble(
      isFromUser: false,
      content: m.content,
      expertId: expertId,
      expertName: _names[expertId] ?? expertId,
      avatarEmoji: _avatarEmojis[expertId],
      avatarColor: _avatarColors[expertId],
      status: m.status,
      // B2 §4.3.3：历史引用卡（_reload 时按 messageId 补拉）。
      citations: _citations[m.id] ?? const <Citation>[],
      footer: _messageFooter(m.id),
      continuousWithPrevious: continuousWithPrevious,
    );
  }

  /// 气泡下方附加行：流式完成时的引用计数 / 未作答提示（视觉口径不变）。
  Widget? _messageFooter(String messageId) {
    final fin = _finished[messageId];
    if (fin == null || (fin.count == 0 && !fin.skipped)) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        fin.skipped
            ? '（未作答：${fin.reason ?? '已跳过'}）'
            : '📎 引用 ${fin.count} 条知识库证据',
        style: TextStyle(
          fontSize: 11,
          color: fin.skipped ? Colors.orange : Colors.black38,
        ),
      ),
    );
  }

  /// 从工具栏「@提及」按钮打开同一个 [MentionPicker]（清空过滤词、焦点交过滤框）。
  void _openMentionFromButton() {
    if (!_isGroup) return;
    setState(() {
      _mentionOpen = true;
      _mentionQuery = '';
      _mentionIndex = 0;
    });
    _mentionFilterCtrl.text = '';
    _mentionFilterFocus.requestFocus();
  }
}
