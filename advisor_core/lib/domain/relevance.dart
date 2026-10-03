/// 相关性打分与**唯一分词口径**（第 6 轮 T01 · 群聊发言质量 B3）。
///
/// 背景（第 6 轮根因 #2）：旧编排在用户「不带 @ 的发言范围指令」下退化为
/// 轮流取 3 人 → 无关成员刷屏。本轮以「相关性驱动」取代点名制：
/// 用专家能力标签（`profession` / `tags`）与用户消息的**词面重合度**做粗筛，
/// 只把候选集压到 `max_speakers_per_round` 量级，语义由成员自判兜底。
///
/// **单一分词口径（硬约束）**：[ExpertiseTokenizer] 是本工程里
/// 「能力标签 ↔ 用户消息」重合度计算的**唯一**分词实现，
/// `AutoStrategy.tokenize` 委托本实现（第 6 轮 refactor），
/// 因此自动策略与组长主持策略的分词结果**逐字相同**，不存在两套分词器漂移。
///
/// 本文件为**纯函数**：无 IO、无 Flutter，可 `dart run` 单测。
library;

import 'generation.dart';

/// 相关性命中阈值默认值（与 `AutoStrategy.minScore` 同口径）。
///
/// 走查可调（架构设计待明确 #8）：过低 → 人多、过高 → 冷场。常量集中于此，便于调参。
const double kDefaultMinRelevance = 0.01;

/// 成员自判「本次话题与自身专业无关」的**静默哨兵**。
///
/// 编排识别到该输出后：step 记 `skipped`、对应消息置 `cancelled` 且正文清空、
/// **UI 不渲染气泡**（第 6 轮共享约定 §2.2 静默契约）——否则"我无关"本身
/// 又会变成一条可见消息，自判反成新的刷屏源。
const String kNonParticipationToken = '【不参与】';

/// 能力标签 / 用户消息的分词实现（**唯一实现**，勿另写第二套）。
///
/// 规则：
/// - 中文（CJK）：逐字 + 相邻 2-gram（提升匹配质量）；
/// - 拉丁/数字：按非字母数字分隔切分后小写；
/// - 其它字符作分隔符。
abstract final class ExpertiseTokenizer {
  /// 分词：返回去重后的 token 集合。
  static Set<String> tokenize(String text) {
    final out = <String>{};
    final lower = text.toLowerCase();
    final chars = lower.runes.toList();
    final buf = StringBuffer();
    for (final r in chars) {
      final ch = String.fromCharCode(r);
      final isCjk = r >= 0x4E00 && r <= 0x9FFF;
      if (isCjk) {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
        out.add(ch);
      } else if (RegExp(r'[a-z0-9]').hasMatch(ch)) {
        buf.write(ch);
      } else {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());

    // 中文 2-gram，提升匹配质量
    final cjk = chars
        .where((r) => r >= 0x4E00 && r <= 0x9FFF)
        .map(String.fromCharCode)
        .toList();
    for (var i = 0; i + 1 < cjk.length; i++) {
      out.add('${cjk[i]}${cjk[i + 1]}');
    }
    out.removeWhere((e) => e.isEmpty);
    return out;
  }
}

/// 成员相关性打分（纯函数）。
abstract final class MemberRelevanceScorer {
  /// 专家能力标签（[GroupMember.expertise]，即 tags ?? profession）
  /// 与 [userText] 的词集重合度之和。
  ///
  /// 逐标签计算 `命中 token 数 / 标签 token 数` 后累加——与 `AutoStrategy`
  /// 的打分**完全同口径**（含「总结者 0.5 折扣」以避免总结者抢话）。
  static double score(String userText, GroupMember member) {
    final query = ExpertiseTokenizer.tokenize(userText);
    if (query.isEmpty) return 0;
    var score = 0.0;
    for (final tag in member.expertise) {
      final t = ExpertiseTokenizer.tokenize(tag);
      if (t.isEmpty) continue;
      final hit = t.where(query.contains).length;
      score += hit / t.length;
    }
    if (member.isSummarizer) score *= 0.5;
    return score;
  }

  /// 按相关度降序排序（同分按 `sortOrder` 升序，保证可复现）。
  static List<GroupMember> rank(String userText, List<GroupMember> members) {
    final scored = <({GroupMember m, double s})>[
      for (final m in members) (m: m, s: score(userText, m)),
    ]..sort((a, b) {
        final c = b.s.compareTo(a.s);
        return c != 0 ? c : a.m.sortOrder.compareTo(b.m.sortOrder);
      });
    return [for (final e in scored) e.m];
  }

  /// 相关度 ≥ [minRelevance] 的成员（按相关度降序）。
  static List<GroupMember> relevantAbove(
    String userText,
    List<GroupMember> members, {
    double minRelevance = kDefaultMinRelevance,
  }) =>
      [
        for (final m in rank(userText, members))
          if (score(userText, m) >= minRelevance) m,
      ];
}
