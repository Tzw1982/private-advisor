/// 思考过程剥离（第 3 轮 · A② 正文元叙述，PRD §6.2 / 架构设计 §3.5）。
///
/// 三分法：
/// - A① 模型 reasoning 通道（`reasoning_content`）→ 走 `generation_events`，**绝不进正文**
///   （由生成服务处理，不在本文件）；
/// - A② **正文中的过程性元叙述** → 本文件 [ReasoningStripper] 保守剥离；
/// - B 结论 / C 依据 → 保留。
///
/// **保守优先（借鉴 §51.4 跑题误伤教训）**：宁可漏剥一句过渡语，也绝不误删真实内容。
/// 因此仅剥离两类，且第二类需同时满足「句首 / 段首」+「长度很短」+「含思考动词」：
/// 1. **显式思考围栏**（`【思考】…【/思考】`、```thinking``` 代码块等）；
/// 2. **段首元叙述短句**（如「让我想想。」「我来分析一下。」）。
library;

/// 剥离结果。
class PresentedContent {
  const PresentedContent({required this.text, this.strippedSegments = const []});

  /// 剥离后的正文（**唯一可展示 / 入库的内容**）。
  final String text;

  /// 被剥离的片段（供调试日志；P1 可作事件记录）。
  final List<String> strippedSegments;

  /// 是否发生了剥离。
  bool get changed => strippedSegments.isNotEmpty;
}

/// 正文元叙述剥离器（纯逻辑，可 `dart run` 验证）。
abstract final class ReasoningStripper {
  /// 段首元叙述触发词（**必须出现在句首**）。
  static const List<String> _openers = [
    '让我', '我来', '我先', '我且', '那么', '现在', '好的', '嗯', '首先', '接下来', '下面我',
  ];

  /// 思考动词（元叙述特征）。
  static const List<String> _verbs = [
    '想', '思考', '分析', '梳理', '理一理', '理一下', '组织', '考虑',
    '看看', '看下', '看一下', '理解', '弄清楚', '过一遍',
  ];

  /// 显式思考围栏（成对标记；命中即剥离，属强信号）。
  static final List<RegExp> _fencePatterns = [
    RegExp(r'【思考】([\s\S]*?)【/思考】'),
    RegExp(r'\[思考\]([\s\S]*?)\[/思考\]'),
    RegExp(r'<!--\s*thinking\s*-->([\s\S]*?)<!--\s*/thinking\s*-->', caseSensitive: false),
    RegExp(r'```(?:thinking|reasoning|思考)\s*\n([\s\S]*?)```', caseSensitive: false),
  ];

  /// 句末标点（切句保留标点）。
  static const String _sentenceEnds = '。！？!?';

  /// 剥离正文中的过程性元叙述。
  static PresentedContent strip(String input) {
    if (input.trim().isEmpty) {
      return PresentedContent(text: input);
    }
    final stripped = <String>[];

    // ① 显式围栏：直接移除（强信号）。
    var text = input;
    for (final p in _fencePatterns) {
      text = text.replaceAllMapped(p, (m) {
        stripped.add(m.group(1) ?? '');
        return '';
      });
    }

    // ② 段首元叙述短句：逐行只处理「首个句子」。
    final lines = text.split('\n');
    final out = <String>[];
    for (final line in lines) {
      out.add(_stripLeadingMeta(line, stripped));
    }
    text = out.join('\n');

    // ③ 绝不清空全部内容：若剥离后为空则回退原文（防守）。
    if (text.trim().isEmpty) {
      return PresentedContent(text: input);
    }
    return PresentedContent(text: text, strippedSegments: stripped);
  }

  /// 去掉一行开头的元叙述短句（保守）。
  static String _stripLeadingMeta(String line, List<String> stripped) {
    final indent = _leadingWhitespace(line);
    final body = line.substring(indent.length);
    if (body.isEmpty) return line;

    final endIdx = _firstSentenceEnd(body);
    final firstSentence = endIdx < 0 ? body : body.substring(0, endIdx + 1);
    if (!_isMetaLead(firstSentence)) return line;

    stripped.add(firstSentence);
    final rest = endIdx < 0 ? '' : body.substring(endIdx + 1);
    // 保留原始缩进；若整行被剥空则返回空串（后续由 ③ 兜底）。
    return rest.trim().isEmpty ? '' : '$indent${rest.trimLeft()}';
  }

  /// 首个句末标点的下标（无则 -1）。
  static int _firstSentenceEnd(String s) {
    for (var i = 0; i < s.length; i++) {
      if (_sentenceEnds.contains(s[i])) return i;
    }
    return -1;
  }

  /// 是否为「段首元叙述短句」（保守三条件）。
  static bool _isMetaLead(String sentence) {
    // 去掉首尾空白与句末标点后判定。
    var s = sentence.trim();
    while (s.isNotEmpty && _sentenceEnds.contains(s[s.length - 1])) {
      s = s.substring(0, s.length - 1).trimRight();
    }
    s = s.replaceAll('，', '').replaceAll('、', '');
    if (s.isEmpty || s.length > 30) return false;

    final startsWithOpener = _openers.any(s.startsWith);
    if (!startsWithOpener) return false;
    return _verbs.any(s.contains);
  }

  static String _leadingWhitespace(String s) {
    var i = 0;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) {
      i++;
    }
    return s.substring(0, i);
  }
}
