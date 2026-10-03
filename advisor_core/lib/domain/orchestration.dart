/// 群聊编排辅助：上下文管理、去重、跑题检测、总结（V1.3 §10 / §11）。
///
/// 本文件只做**纯逻辑**（预算裁剪、相似度、提示词构造、JSON 解析）；
/// 需要 LLM 的部分通过端口在 application 层实现。
library;

import 'dart:convert';

import 'conversation.dart';
import 'generation.dart';
import 'knowledge.dart';
import 'provider.dart';

// ---------------------------------------------------------------------------
// 上下文管理（V1.3 §10）
// ---------------------------------------------------------------------------

/// 上下文管理器。
///
/// **禁止**把全部历史直接拼给所有专家；按预算裁剪后再拼。
abstract final class ContextManager {
  /// 估算 token（中文 1 字 ≈ 1 token，其它 4 字符 ≈ 1 token）。
  static int estimateTokens(String text) => KnowledgeChunk.estimateTokens(text);

  /// 构建发给模型的对话消息。
  ///
  /// system 组装顺序（第 3 轮 §3.4 写死；第 6 轮扩展 [groupBlocks]）：
  /// **风格指令 → 有效提示词 → 群级块（群角色/公告/发言范围） → 严格规则 →
  /// 知识库证据** → 近期历史(裁剪) → 用户任务。
  ///
  /// [groupBlocks] 为第 6 轮新增（可选，默认空 → 单聊/旧调用**行为零变化**）：
  /// 由 `GroupPromptComposer.block(...)` 生成，内容是「群角色声明 + 群公告 +
  /// 本轮发言范围 + 表达纪律 + 相关性自判」。群公告须**每位发言者（含总结者）**
  /// 都注入（第 6 轮共享约定 §1 硬契约）。
  ///
  /// [userImageUrls] 为第 9 轮新增（可选，默认空 → 旧调用**行为零变化**）：
  /// 本轮用户消息附带的图片 data URL，随**最后一条 user 消息**发出
  /// （`ChatMessage(ChatRole.user, userTask, imageUrls: userImageUrls)`）；
  /// 历史消息不重发图片（MVP 只送本轮图）。
  static List<ChatMessage> build({
    required String systemPrompt,
    String styleDirective = '',
    String groupBlocks = '',
    required String userTask,
    List<Message> recentMessages = const [],
    List<Citation> evidence = const [],
    TokenBudget budget = TokenBudget.defaults,
    bool strictGrounding = false,
    String Function(String expertId)? nameOf,
    List<String> userImageUrls = const [],
  }) {
    final messages = <ChatMessage>[];

    // 风格指令（可空）与有效提示词拼接；空段自动跳过。
    final head = <String>[
      if (styleDirective.trim().isNotEmpty) styleDirective.trim(),
      if (systemPrompt.trim().isNotEmpty) systemPrompt.trim(),
      if (groupBlocks.trim().isNotEmpty) groupBlocks.trim(),
    ].join('\n\n');
    var system = head;
    if (strictGrounding) {
      system = '$system\n\n${GroundingResolver.strictSystemRule}';
    }
    final evidenceBlock = GroundingResolver.buildEvidenceBlock(evidence);
    if (evidenceBlock.isNotEmpty) {
      system = '$system\n\n$evidenceBlock';
    }
    messages.add(ChatMessage(ChatRole.system, system));

    // 近期历史：从最新往前取，直到超预算
    final history = <ChatMessage>[];
    var used = estimateTokens(system) + estimateTokens(userTask);
    var count = 0;
    for (var i = recentMessages.length - 1; i >= 0; i--) {
      if (count >= budget.maxGroupHistory) break;
      final m = recentMessages[i];
      if (m.content.trim().isEmpty) continue;
      final t = estimateTokens(m.content);
      if (used + t > budget.maxContextTokens) break;
      used += t;
      count++;
      history.insert(
        0,
        ChatMessage(
          m.isFromUser ? ChatRole.user : ChatRole.assistant,
          m.isFromUser
              ? m.content
              // 历史发言者标签用**展示名**（备注优先），不用裸 expertId。
              // 根因（2026-10-02 用户走查）：原来把 `【<expertId>】` 塞进上下文，
              // 模型会模仿该格式，并**把别人的 id/身份安到自己头上**
              //（实测：长篇文档解读专家的回复以 `【<总裁助理id>】` 开头并自称组长）。
              : '【${_speakerLabel(m, nameOf)}】${m.content}',
        ),
      );
    }
    messages.addAll(history);
    messages.add(ChatMessage(ChatRole.user, userTask, imageUrls: userImageUrls));
    return messages;
  }

  /// 历史发言者的展示标签：优先 [nameOf] 解析出的展示名（备注优先），
  /// 否则退回 senderId，再否则 `专家`。**绝不返回空串**（空标签会让模型瞎认身份）。
  static String _speakerLabel(Message m, String Function(String expertId)? nameOf) {
    final id = m.senderId;
    if (id == null || id.isEmpty) return '专家';
    if (nameOf != null) {
      final n = nameOf(id).trim();
      if (n.isNotEmpty) return n;
    }
    return id;
  }

  /// 裁剪专家输出到单次上限。
  static String clampOutput(String text, TokenBudget budget) {
    final tokens = estimateTokens(text);
    if (tokens <= budget.maxExpertOutput) return text;
    // 粗略按字符比例裁剪
    final ratio = budget.maxExpertOutput / tokens;
    final cut = (text.length * ratio).floor();
    return '${text.substring(0, cut.clamp(0, text.length))}…（已按预算截断）';
  }
}

// ---------------------------------------------------------------------------
// 内容呈现辅助（第 3 轮 §3.5 B/C：结论在前、理由紧随）
// ---------------------------------------------------------------------------

/// 结论 / 理由呈现辅助（**轻量规整，不强改 freeform**）。
abstract final class ContentPresenter {
  /// 规整正文：去首尾空白、压缩 3+ 连续空行为 1 个空行、去掉行尾多余空白。
  static String present(String text) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final out = <String>[];
    var blankRun = 0;
    for (final raw in lines) {
      final line = raw.replaceAll(RegExp(r'[ \t]+$'), '');
      if (line.trim().isEmpty) {
        blankRun++;
        if (blankRun <= 1) out.add('');
        continue;
      }
      blankRun = 0;
      out.add(line);
    }
    return out.join('\n').trim();
  }

  /// 把输出拆为「结论 / 理由」：首个非空段落作结论，其余作理由。
  static ({String conclusion, String reasons}) split(String text) {
    final normalized = present(text);
    if (normalized.isEmpty) return (conclusion: '', reasons: '');
    final blocks = normalized.split(RegExp(r'\n\s*\n'));
    final conclusion = blocks.first.trim();
    final reasons = blocks.skip(1).join('\n\n').trim();
    return (conclusion: conclusion, reasons: reasons);
  }
}

// ---------------------------------------------------------------------------
// 去重检测（V1.3 §11）
// ---------------------------------------------------------------------------

/// 去重检测结果。
class DuplicateResult {
  const DuplicateResult(this.similarity, this.isDuplicate, {this.mostSimilarTo});
  final double similarity;
  final bool isDuplicate;
  final String? mostSimilarTo;
}

/// 重复检测器：对"当前输出 vs 最近专家输出"做 token 集合 Jaccard 相似度。
class DuplicateDetector {
  DuplicateDetector({this.threshold = 0.82});

  final double threshold;

  DuplicateResult check(
    String output,
    List<ExpertOutput> recentOutputs, {
    String? currentExpertId,
  }) {
    final a = _tokens(output);
    if (a.isEmpty) return const DuplicateResult(0, false);

    var best = 0.0;
    String? bestId;
    for (final prev in recentOutputs) {
      if (prev.skipped) continue;
      if (currentExpertId != null && prev.expertId == currentExpertId) continue;
      final b = _tokens(prev.content);
      if (b.isEmpty) continue;
      final sim = _jaccard(a, b);
      if (sim > best) {
        best = sim;
        bestId = prev.expertId;
      }
    }
    return DuplicateResult(best, best >= threshold, mostSimilarTo: bestId);
  }

  static Set<String> _tokens(String text) {
    final out = <String>{};
    final cjk = <String>[];
    final buf = StringBuffer();
    for (final r in text.toLowerCase().runes) {
      final ch = String.fromCharCode(r);
      if (r >= 0x4E00 && r <= 0x9FFF) {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
        cjk.add(ch);
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
    for (var i = 0; i + 1 < cjk.length; i++) {
      out.add('${cjk[i]}${cjk[i + 1]}');
    }
    out.removeWhere((e) => e.isEmpty);
    return out;
  }

  static double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final inter = a.intersection(b).length;
    final union = a.union(b).length;
    return union == 0 ? 0 : inter / union;
  }
}

// ---------------------------------------------------------------------------
// 跑题检测（V1.3 §11）
// ---------------------------------------------------------------------------

/// 跑题检测结果。
class OffTopicResult {
  const OffTopicResult(this.isOffTopic, this.reason, this.relevance);
  final bool isOffTopic;
  final String reason;
  final double relevance;
}

/// 跑题检测器：判断"是否仍回答用户任务"。
///
/// 纯启发式（与用户任务的相关度过低 → 疑似跑题），不额外消耗 LLM。
///
/// **设计取舍**：词面重合度做启发式误判率不低（例如用户只说"继续"），
/// 因此默认 [skipEnabled] = false —— 只记录信号，**不丢弃**专家输出；
/// 需要强约束时再显式打开。
class OffTopicDetector {
  OffTopicDetector({this.threshold = 0.02, this.skipEnabled = false});

  final double threshold;

  /// 是否在检测到跑题时丢弃该输出。默认关闭，避免误杀有效内容。
  final bool skipEnabled;

  OffTopicResult check(String output, String userTask) {
    final a = DuplicateDetector._tokens(output);
    final b = DuplicateDetector._tokens(userTask);
    if (a.isEmpty) return const OffTopicResult(true, '输出为空', 0);
    if (b.isEmpty) return const OffTopicResult(false, '任务过短，跳过判定', 1);
    final rel = a.intersection(b).length / b.length;
    return OffTopicResult(
      rel < threshold,
      rel < threshold ? '与用户任务相关度偏低（${rel.toStringAsFixed(3)}）' : '正常',
      rel,
    );
  }
}

// ---------------------------------------------------------------------------
// 总结者（V1.3 §11）
// ---------------------------------------------------------------------------

/// 结构化总结结果。
class SummaryResult {
  const SummaryResult({
    this.consensus = const [],
    this.disagreements = const [],
    this.recommendations = const [],
    this.openQuestions = const [],
    this.citations = const [],
    this.raw = '',
  });

  final List<String> consensus;
  final List<String> disagreements;
  final List<String> recommendations;
  final List<String> openQuestions;
  final List<Citation> citations;
  final String raw;

  /// 从模型返回的 JSON 解析；解析失败时退化为纯文本。
  static SummaryResult fromModelText(String text) {
    final json = _extractJson(text);
    if (json == null) {
      return SummaryResult(recommendations: [text.trim()], raw: text);
    }
    List<String> strs(String key) {
      final v = json[key];
      if (v is List) return v.map((e) => e.toString()).toList();
      return const [];
    }

    return SummaryResult(
      consensus: strs('consensus'),
      disagreements: strs('disagreements'),
      recommendations: strs('recommendations'),
      openQuestions: strs('open_questions'),
      raw: text,
    );
  }

  static Map<String, dynamic>? _extractJson(String text) {
    var s = text.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(s);
    if (fence != null) s = fence.group(1)!.trim();
    final start = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = jsonDecode(s.substring(start, end + 1));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 渲染为 Markdown。
  String toMarkdown() {
    final b = StringBuffer();
    void section(String title, List<String> items) {
      if (items.isEmpty) return;
      b.writeln('**$title**');
      for (final i in items) {
        b.writeln('- $i');
      }
      b.writeln();
    }

    section('共识', consensus);
    section('分歧', disagreements);
    section('建议', recommendations);
    section('待确认', openQuestions);
    if (citations.isNotEmpty) {
      b.writeln('**引用来源**');
      for (var i = 0; i < citations.length; i++) {
        b.writeln('[${i + 1}] ${citations[i].toDisplay()}');
      }
    }
    return b.toString().trim();
  }
}

/// 总结者端口（LLM 调用由 application 层实现）。
abstract interface class Summarizer {
  /// 构造总结提示词。
  static List<ChatMessage> buildPrompt({
    required String userTask,
    required List<ExpertOutput> outputs,
  }) {
    final b = StringBuffer()
      ..writeln('你是本次多专家讨论的主持人。请综合以下各位专家的发言，输出结构化结论。')
      ..writeln()
      ..writeln('用户任务：$userTask')
      ..writeln()
      ..writeln('各专家发言：');
    for (final o in outputs) {
      if (o.skipped) continue;
      b.writeln('【${o.expertName}】${o.content}');
      b.writeln();
    }
    b
      ..writeln('请只输出 JSON，格式：')
      ..writeln('{"consensus":[],"disagreements":[],"recommendations":[],"open_questions":[]}');

    return [
      ChatMessage(ChatRole.system, '你是严谨的讨论主持人，只输出 JSON。'),
      ChatMessage(ChatRole.user, b.toString()),
    ];
  }

  Future<SummaryResult> summarize({
    required String userTask,
    required List<ExpertOutput> outputs,
  });
}
