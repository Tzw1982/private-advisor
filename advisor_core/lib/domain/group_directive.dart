/// 发言范围指令解析 + 群级提示词组装（第 6 轮 T01 · B1/B2）。
///
/// **根因 #2（用户原话「我说要组长一个人发言，结果每个成员又发了一通」）**：
/// 旧编排只认 `@专家名`，"组长一个人发言"不含 `@` → 手动策略返回空 ×
/// 自动策略轮流兜底 3 人 → 无关成员刷屏。本文件用**正则句式解析**补上
/// 「从用户消息识别发言范围」这条路径（硬裁定：**不做 LLM 意图分类**——
/// 正则够用、可测、零成本、零延迟；漏句回落策略不阻断）。
///
/// **根因 #3（「任命的组长没得到大家共同认可」）**：旧 `ContextManager.build`
/// 从不注入角色信号。本文件的 [GroupPromptComposer] 负责生成
/// 「群角色声明 + 群公告/共识 + 本轮发言范围」文本块，
/// 由编排层插入每位发言者（含总结者）的 system。
///
/// 本文件为**纯函数**：无 IO、无 Flutter，可 `dart run` 单测。
library;

import 'conversation.dart';
import 'generation.dart';
import 'relevance.dart';

// ---------------------------------------------------------------------------
// 发言范围指令
// ---------------------------------------------------------------------------

/// 解析结果：本轮应发言者（有序）+ 依据（可入 UI / 日志）。
class SpeakerDirective {
  const SpeakerDirective({
    required this.expertIds,
    required this.reason,
    this.isFullGroup = false,
  });

  /// 本轮应发言者（有序；调用方按此顺序执行，**覆盖**群策略选择）。
  final List<String> expertIds;

  /// 人类可读依据，如「用户要求：仅组长一人发言」。
  final String reason;

  /// 是否为「全体发言」指令（此时名单 = 当前全部可用成员）。
  final bool isFullGroup;

  bool get isEmpty => expertIds.isEmpty;

  @override
  String toString() => 'SpeakerDirective(${expertIds.join(',')} / $reason)';
}

/// 发言范围指令解析器（纯正则；不做 LLM 意图分类）。
///
/// 识别的高置信中文句式（顺序即优先级，先命中先返回）：
/// 1. 仅组长一人：`组长` + （一个人/一人/单独/自己）+ 发言动词；
/// 2. 组长发言：`组长 (发言|来|主持|说|讲|先…)`；
/// 3. 全体：`(大家|所有人|各位|全员) … (说说|发言|谈谈|看看|聊聊)`；
/// 4. 点名：`@<名>`，或 `<名>(来|发言|说说|说一下|回答|说|讲)`（含「让/请/叫」前缀）；
/// 5. 未命中 → `null`（回落持久策略）。
abstract final class GroupDirectiveResolver {
  /// 仅组长一人 的限定词。
  static const List<String> _onlyOneWords = ['一个人', '一人', '单独', '自己'];

  /// 发言动词。
  static const List<String> _speakVerbs = ['发言', '说', '回答', '来', '讲'];

  /// 解析 [userText]；命中返回指令，未命中返回 `null`。
  ///
  /// [leaderId] 为空（群内无组长）时，「仅组长」类指令**无法执行** → 返回 `null`
  /// 回落持久策略（避免产出空发言者集合导致冷场）。
  static SpeakerDirective? resolve({
    required String userText,
    required List<GroupMember> members,
    String? leaderId,
  }) {
    final text = userText.trim();
    if (text.isEmpty) return null;

    final active = List<GroupMember>.from(members)
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    if (active.isEmpty) return null;

    GroupMember? leader;
    if (leaderId != null && leaderId.isNotEmpty) {
      for (final m in active) {
        if (m.expertId == leaderId) {
          leader = m;
          break;
        }
      }
    }

    // ① 仅组长一人（最具体，先判）
    if (leader != null &&
        text.contains('组长') &&
        _onlyOneWords.any(text.contains) &&
        _speakVerbs.any(text.contains)) {
      return SpeakerDirective(
        expertIds: [leader.expertId],
        reason: '用户要求：仅组长一人发言',
      );
    }

    // ② 组长发言 / 组长来 / 组长主持 / 组长先说
    if (leader != null && RegExp('组长\\s*(来|发言|主持|说|讲|先)').hasMatch(text)) {
      return SpeakerDirective(
        expertIds: [leader.expertId],
        reason: '用户要求：由组长发言',
      );
    }

    // ③ 全体
    final allMatcher = RegExp('(大家|所有人|各位|全员|每个人)[^。！？\\n]{0,6}(说说|发言|谈谈|看看|聊聊|讲两句)');
    final eachMatcher = RegExp('(各自|每人)[^。！？\\n]{0,4}(说说|发言|谈谈|看看|聊聊|讲两句)');
    if (allMatcher.hasMatch(text) || eachMatcher.hasMatch(text)) {
      return SpeakerDirective(
        expertIds: [for (final m in active) m.expertId],
        reason: '用户要求：全员发言',
        isFullGroup: true,
      );
    }

    // ④ 点名（@<名> 或 <名>+发言动词，可带「让/请/叫/只让」前缀）
    final named = <String>[];
    final namedNames = <String>[];
    for (final m in active) {
      final name = m.name.trim();
      if (name.isEmpty) continue;
      if (text.contains('@$name')) {
        if (!named.contains(m.expertId)) {
          named.add(m.expertId);
          namedNames.add(name);
        }
        continue;
      }
      final pat = RegExp(
        '(让|请|叫|只让)?\\s*${RegExp.escape(name)}\\s*(一个人|单独|自己)?\\s*(来|发言|说说|说一下|回答|说|讲)',
      );
      if (pat.hasMatch(text)) {
        if (!named.contains(m.expertId)) {
          named.add(m.expertId);
          namedNames.add(name);
        }
      }
    }
    if (named.isNotEmpty) {
      return SpeakerDirective(
        expertIds: named,
        reason: '用户点名：${namedNames.join('、')}',
      );
    }

    // ⑤ 未命中
    return null;
  }
}

// ---------------------------------------------------------------------------
// 群级提示词组装
// ---------------------------------------------------------------------------

/// 群级提示词组装器（角色声明 / 群公告 / 本轮发言范围 / 表达纪律）。
///
/// 组装顺序（编排层拼接后作为一个 system 块传入 `ContextManager.build`）：
/// **角色声明 → 群公告（共识） → 本轮发言范围 → 表达纪律 → 相关性自判**。
abstract final class GroupPromptComposer {
  /// 群角色声明：让成员分得清「我是组长还是组员」（根因 #3）。
  static String roleBlock({
    required String selfName,
    required MemberRole role,
    String? leaderName,
  }) {
    if (role == MemberRole.leader) {
      return '【群角色】你是本群组长「$selfName」。职责：组织讨论、分派任务、'
          '点名邀请与话题相关的成员发言、控制节奏并收敛结论；不要替其他成员代答。';
    }
    final leaderDesc = (leaderName != null && leaderName.trim().isNotEmpty)
        ? '本群组长是「${leaderName.trim()}」'
        : '本群暂无组长';
    return '【群角色】你是本群组员「$selfName」（$leaderDesc）。'
        '专注你的专业领域，仅当本次话题与你的专业相关时发言。';
  }

  /// 群公告 / 共识块（**硬契约**：空/未设返回空串，由调用方跳过）。
  ///
  /// 公告文本**逐字**进入 system——走查断言「system 含公告文本」即验此处。
  static String consensusBlock(String? announcement) {
    final a = announcement?.trim() ?? '';
    if (a.isEmpty) return '';
    return '【本群共识/公告】（全体成员每轮均须遵守，最新优先）\n$a';
  }

  /// 本轮发言范围块（[directive] 为 null 时说明按策略自动选择）。
  static String scopeBlock(SpeakerDirective? directive, List<String> speakerNames) {
    final names = speakerNames.where((n) => n.trim().isNotEmpty).join('、');
    if (directive == null) {
      return '【本轮发言范围】未指定，按群策略自动选择与话题相关的成员发言。';
    }
    if (directive.isFullGroup) {
      return '【本轮发言范围】全员参与：$names。';
    }
    return '【本轮发言范围】本轮仅由以下成员发言：$names（其他成员请保持静默，不要发言）。';
  }

  /// 表达纪律（简洁、结论在前、不复述）。
  static const String concisionRule =
      '【表达纪律】只讲你专业判断内的关键结论，简洁直接、结论在前；'
      '不复述他人观点、不重复已给结论、不寒暄客套。';

  /// **发言格式纪律**（第 8 轮 · 根因：模型模仿历史里的 `【xxx】` 发言者标签，
  /// 把别人的身份安到自己头上——实测出现"招标文件解读专家以总裁助理身份分派任务"）。
  ///
  /// 与 [concisionRule] 互相独立：本条专治**身份冒领**，且必须出现在**每位发言者**
  /// 的 system 里（故并入 [block]），否则群聊里角色错位会反复出现。
  static const String noSpeakerLabelEchoRule =
      '【发言格式】直接以**你本人**的身份发言：不要在回复前添加任何【】包裹的'
      '姓名或编号标注（发言人由系统自动标注），不要在正文里自称他人，'
      '也不要复述或改写其他成员说过的话。';

  /// 相关性自判（B3 第 3 层：语义由成员自判，无关则静默）。
  ///
  /// ⚠️ 必须包含 [kNonParticipationToken]，编排层据此走静默契约。
  static const String nonParticipationRule =
      '【相关性自判】请先判断本次话题是否与你的专业相关：相关则专注自身业务、'
      '简洁发言；无关则**只回复「$kNonParticipationToken」**，不要强行发言或复述他人。';

  /// 便捷聚合：按固定顺序拼出完整群级块（空段自动跳过）。
  static String block({
    required String selfName,
    required MemberRole role,
    String? leaderName,
    String? announcement,
    SpeakerDirective? directive,
    List<String> speakerNames = const [],
    bool includeNonParticipation = true,
  }) {
    final parts = <String>[
      roleBlock(selfName: selfName, role: role, leaderName: leaderName),
      consensusBlock(announcement),
      scopeBlock(directive, speakerNames),
      concisionRule,
      noSpeakerLabelEchoRule,
      if (includeNonParticipation) nonParticipationRule,
    ].where((p) => p.trim().isNotEmpty);
    return parts.join('\n\n');
  }
}

// ---------------------------------------------------------------------------
// 短回执（裁定 #6：阈值初值 12 字符，走查可调）
// ---------------------------------------------------------------------------

/// 「收到」类短回执的最大字符数（含）。
const int kShortAckMaxChars = 12;

/// 「收到」类短回执关键词。
const List<String> kShortAckKeywords = ['收到', '明白', '好的', '了解', '遵命', '收到啦'];

/// 短回执判定（纯函数）：讨论中的礼节性确认**不应**被当作跑题/长度问题惩罚。
abstract final class ShortAckDetector {
  /// 是否属于「收到」类短回执（长度 ≤ [kShortAckMaxChars] 且含任一关键词）。
  static bool isShortAck(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > kShortAckMaxChars) return false;
    for (final k in kShortAckKeywords) {
      if (t.contains(k)) return true;
    }
    return false;
  }
}
