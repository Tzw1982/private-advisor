/// 群聊发言策略（V1.3 §9.1 / §24）。
///
/// 统一接口：`selectNextSpeakers(GroupContext) -> SpeakerPlan`
/// 插件式设计，便于后续扩展 RoleBased / Debate / Critic / ExpertiseMatch / BudgetAware。
library;

import 'dart:math' as math;

import 'conversation.dart';
import 'generation.dart';
import 'relevance.dart';

/// 发言策略端口。
abstract interface class SpeakingStrategy {
  /// 稳定标识：manual / round_robin / weighted / auto。
  String get id;

  /// 展示名。
  String get label;

  Future<SpeakerPlan> selectNextSpeakers(GroupContext ctx);
}

/// 策略注册表。
abstract final class SpeakingStrategies {
  static final Map<String, SpeakingStrategy> _registry = {};

  static void register(SpeakingStrategy s) => _registry[s.id] = s;

  static SpeakingStrategy? byId(String id) => _registry[id];

  static List<SpeakingStrategy> all() => _registry.values.toList();

  /// 注册内置策略（第 6 轮新增 `leader_led`）。
  static void registerBuiltins() {
    register(ManualStrategy());
    register(RoundRobinStrategy());
    register(WeightedStrategy());
    register(AutoStrategy());
    register(LeaderLedStrategy());
  }
}

// ---------------------------------------------------------------------------
// ① 手动指定
// ---------------------------------------------------------------------------

/// 手动指定：用户在消息里 `@专家名`。
class ManualStrategy implements SpeakingStrategy {
  @override
  String get id => 'manual';

  @override
  String get label => '手动指定';

  @override
  Future<SpeakerPlan> selectNextSpeakers(GroupContext ctx) async {
    final text = ctx.userMessage.content;
    final active = ctx.activeMembers;
    final picked = <String>[];
    for (final m in active) {
      if (text.contains('@${m.name}')) picked.add(m.expertId);
    }
    if (picked.isEmpty) {
      return const SpeakerPlan(
        primarySpeakers: [],
        rationale: '未识别到 @ 指定，本策略不自动发言',
      );
    }
    return SpeakerPlan(
      primarySpeakers: picked,
      maxRounds: 1,
      rationale: '用户 @ 指定：${picked.length} 位',
    );
  }
}

// ---------------------------------------------------------------------------
// ② 轮流
// ---------------------------------------------------------------------------

/// 轮流发言：从上一发言者之后按序取 [rounds] 位。
class RoundRobinStrategy implements SpeakingStrategy {
  RoundRobinStrategy({this.rounds = 3});

  final int rounds;

  @override
  String get id => 'round_robin';

  @override
  String get label => '轮流';

  @override
  Future<SpeakerPlan> selectNextSpeakers(GroupContext ctx) async {
    final active = ctx.activeMembers;
    if (active.isEmpty) return SpeakerPlan.none;

    final last = ctx.lastSpeakerId;
    final start = last == null ? 0 : (active.indexWhere((m) => m.expertId == last) + 1) % active.length;
    final n = math.min(rounds, active.length);
    final picked = <String>[];
    for (var i = 0; i < n; i++) {
      picked.add(active[(start + i) % active.length].expertId);
    }
    return SpeakerPlan(
      primarySpeakers: picked,
      maxRounds: 1,
      rationale: '轮流：从第 $start 位起取 $n 位',
    );
  }
}

// ---------------------------------------------------------------------------
// ③ 按权重随机
// ---------------------------------------------------------------------------

/// 按权重随机挑选。权重来自 `ConversationMember.weight`。
class WeightedStrategy implements SpeakingStrategy {
  WeightedStrategy({this.count = 3, this.seed});

  final int count;
  final int? seed;

  @override
  String get id => 'weighted';

  @override
  String get label => '按权重随机';

  @override
  Future<SpeakerPlan> selectNextSpeakers(GroupContext ctx) async {
    final pool = ctx.activeMembers.where((m) => m.weight > 0).toList();
    if (pool.isEmpty) return SpeakerPlan.none;

    final rng = math.Random(seed);
    final remaining = List<GroupMember>.from(pool);
    final picked = <String>[];
    final n = math.min(count, remaining.length);

    for (var i = 0; i < n; i++) {
      final total = remaining.fold<double>(0, (a, m) => a + m.weight);
      var r = rng.nextDouble() * total;
      var idx = 0;
      for (; idx < remaining.length; idx++) {
        r -= remaining[idx].weight;
        if (r <= 0) break;
      }
      if (idx >= remaining.length) idx = remaining.length - 1;
      picked.add(remaining.removeAt(idx).expertId);
    }

    return SpeakerPlan(
      primarySpeakers: picked,
      maxRounds: 1,
      rationale: '按权重随机取 $n 位',
    );
  }
}

// ---------------------------------------------------------------------------
// ④ 自动（默认）
// ---------------------------------------------------------------------------

/// 自动策略：按"用户问题关键词 ↔ 专家能力标签"的重合度打分，
/// 命中者优先发言；若全部无命中，退化为轮流（保证群聊不冷场）。
class AutoStrategy implements SpeakingStrategy {
  AutoStrategy({this.maxSpeakers = 3, this.minScore = 0.01});

  final int maxSpeakers;
  final double minScore;

  @override
  String get id => 'auto';

  @override
  String get label => '自动（推荐）';

  @override
  Future<SpeakerPlan> selectNextSpeakers(GroupContext ctx) async {
    final active = ctx.activeMembers;
    if (active.isEmpty) return SpeakerPlan.none;

    final query = ExpertiseTokenizer.tokenize(ctx.userMessage.content);
    final scored = <({GroupMember m, double score})>[];

    for (final m in active) {
      var score = 0.0;
      for (final tag in m.expertise) {
        final t = ExpertiseTokenizer.tokenize(tag);
        if (t.isEmpty) continue;
        final hit = t.where(query.contains).length;
        score += hit / t.length;
      }
      if (m.isSummarizer) score *= 0.5; // 总结者少抢话
      scored.add((m: m, score: score));
    }

    scored.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : a.m.sortOrder.compareTo(b.m.sortOrder);
    });

    final picked = scored
        .where((e) => e.score > minScore)
        .take(maxSpeakers)
        .map((e) => e.m.expertId)
        .toList();

    if (picked.isEmpty) {
      // 退化为轮流，避免冷场
      final fallback = RoundRobinStrategy(rounds: math.min(2, active.length));
      final plan = await fallback.selectNextSpeakers(ctx);
      return SpeakerPlan(
        primarySpeakers: plan.primarySpeakers,
        maxRounds: plan.maxRounds,
        rationale: '无标签命中，退化为轮流',
      );
    }

    return SpeakerPlan(
      primarySpeakers: picked,
      maxRounds: 1,
      rationale: '按能力标签匹配取 ${picked.length} 位',
    );
  }

  /// 分词：**委托** [ExpertiseTokenizer]（唯一实现，勿另写第二套）。
  ///
  /// 第 6 轮 refactor：实现体迁至 `relevance.dart` 的 [ExpertiseTokenizer]，
  /// 使自动策略与组长主持策略（相关性粗筛）共用同一分词口径，**输出逐字不变**。
  static Set<String> tokenize(String text) => ExpertiseTokenizer.tokenize(text);
}

// ---------------------------------------------------------------------------
// ⑤ 组长主持（第 6 轮新增，建议设为群聊默认策略）
// ---------------------------------------------------------------------------

/// 组长主持策略的稳定 id（集中定义，避免字面量漂移；编排层据此构造带 cap 的实例）。
const String kLeaderLedStrategyId = 'leader_led';

/// 组长主持：**强制入选 + 相关性粗筛 + 兜底仅组长**（防刷屏）。
///
/// 发言选择（优先级从高到低，第 6 轮共享约定 §2.1）：
/// 1. **强制入选**：用户 `@成员`；组长上一轮正文 `@成员`（组长「分派/点名」机制）；
/// 2. **组长先行**：组长总在本轮首位发言（主持位）；
/// 3. **相关性粗筛**：[MemberRelevanceScorer] 打分 ≥ [minRelevance] 者按相关度
///    降序补齐，直至达到 [maxSpeakers]（**上限 = 本轮总发言人数**，含强制入选者）；
/// 4. **不冷场兜底**：相关性全员不命中 → **仅组长**发言（不退化全员）。
///
/// 输入侧始终被 `group_configs.max_speakers_per_round` 约束（编排层传入）。
class LeaderLedStrategy implements SpeakingStrategy {
  LeaderLedStrategy({this.maxSpeakers = 3, this.minRelevance = kDefaultMinRelevance});

  /// 单轮发言者上限（含强制入选者）。
  final int maxSpeakers;

  /// 相关性命中阈值（常量集中在 `relevance.dart`，便于走查调参）。
  final double minRelevance;

  @override
  String get id => kLeaderLedStrategyId;

  @override
  String get label => '组长主持（推荐）';

  @override
  Future<SpeakerPlan> selectNextSpeakers(GroupContext ctx) async {
    final active = ctx.activeMembers;
    if (active.isEmpty) return SpeakerPlan.none;

    GroupMember? leader;
    for (final m in active) {
      if (m.role == MemberRole.leader) {
        leader = m;
        break;
      }
    }

    final text = ctx.userMessage.content;
    final selected = <String>[];
    final notes = <String>[];

    void pick(GroupMember m, String why) {
      if (selected.contains(m.expertId)) return;
      selected.add(m.expertId);
      notes.add('${m.name}:$why');
    }

    // ① 强制入选：用户 @成员
    for (final m in active) {
      if (m.name.trim().isEmpty) continue;
      if (text.contains('@${m.name}')) pick(m, '用户@');
    }

    // ① 强制入选：组长上一轮 @提名（组长分派任务 / 点名）
    if (leader != null) {
      final leaderId = leader.expertId;
      final leaderText = ctx.previousSpeakerOutputs
          .where((o) => o.expertId == leaderId && !o.skipped)
          .map((o) => o.content)
          .join('\n');
      if (leaderText.isNotEmpty) {
        for (final m in active) {
          if (m.expertId == leaderId || m.name.trim().isEmpty) continue;
          if (leaderText.contains('@${m.name}')) pick(m, '组长@提名');
        }
      }
    }

    // 强制入选数量（用户 @ ∪ 组长 @ 提名）：用于判定「不冷场兜底」是否成立——
    // 只要存在强制入选者（无论相关性是否命中），**绝不能**折叠为「仅组长」，
    // 否则会把被点名的成员挤掉（违反 B3 断言 3/4「@ 必选」）。
    final forcedCount = selected.length;

    // ② 组长先行（主持位；占一个名额）
    if (leader != null && selected.length < maxSpeakers) {
      if (!selected.contains(leader.expertId)) {
        selected.insert(0, leader.expertId);
        notes.insert(0, '${leader.name}:组长先行');
      }
    }

    // ③ 相关性粗筛：Top-N 补齐至上限
    var relevantPicked = 0;
    if (selected.length < maxSpeakers) {
      for (final m in MemberRelevanceScorer.rank(text, active)) {
        if (selected.length >= maxSpeakers) break;
        if (selected.contains(m.expertId)) continue;
        if (MemberRelevanceScorer.score(text, m) < minRelevance) continue;
        pick(m, '相关性');
        relevantPicked++;
      }
    }

    // ④ 兜底：**既无强制入选、也无相关性命中** → 仅组长（不冷场、不退化全员）。
    //    有强制入选者时**绝不**走兜底，保证 @ 必选。
    if (forcedCount == 0 && relevantPicked == 0 && leader != null) {
      return SpeakerPlan(
        primarySpeakers: [leader.expertId],
        maxRounds: 1,
        rationale: '组长主持：相关性无命中 → 仅组长发言（不冷场）',
      );
    }

    if (selected.isEmpty) return SpeakerPlan.none;
    final capped = selected.take(maxSpeakers).toList();
    return SpeakerPlan(
      primarySpeakers: capped,
      maxRounds: 1,
      rationale: '组长主持：${notes.join('；')} → 入选 ${capped.length} 位',
    );
  }
}
