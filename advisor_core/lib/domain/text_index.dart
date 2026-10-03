/// 中文文本索引工具：索引端与查询端**共用**的 bigram 分词与覆盖率计算。
///
/// 背景（第 2 轮根因诊断，硬规约，违反必出错）：
/// 旧实现 `bigram()` 会把**尾字符也当单字 token 追加**，而查询构造又用 `AND` 连接，
/// 于是 `query '长臂' → '长臂 高' → MATCH "长臂" AND "高"`；由于索引里 `高`
/// 从不作为独立 token 存在（只有相邻 bigram），`AND` 永不成立 → 恒 0 命中。
///
/// 因此本文件确立三条硬规约：
/// 1. **索引端与查询端必须共用同一 `tokenize`**，禁止各自实现；
/// 2. **只产出 bigram，绝不追加尾单字 unigram**（CJK 串长度 == 1 时才产出单字）；
/// 3. 查询端对多个 token 用 **`OR`** 连接召回，精度由 [coverage] 覆盖率过滤保证。
///
/// 本文件为**纯函数**，不依赖 Flutter / SQLite，可在 `advisor_core` 内独立单测。
library;

/// 中文 n-gram（bigram）分词 / 归一化 / 覆盖率工具。
///
/// 全部为静态方法，无状态，便于索引端与查询端复用。
abstract final class ChineseBigram {
  /// 文本归一化：统一小写（拉丁字母与数字不区分大小写）。
  ///
  /// 仅做**大小写归一**，不做去标点（标点在 [tokenize] 中按分隔符丢弃）。
  static String normalize(String text) => text.toLowerCase();

  /// 分词：把文本切成**可检索 token** 序列（**仅 bigram**，无尾单字）。
  ///
  /// 规则（见第 2 轮设计 §3.3）：
  /// - CJK 连续串，长度 ≥ 2：产出**所有相邻二元组**（不追加尾单字）；
  ///   如 `工程车长臂` → `工业 防车 车举 长臂`；
  /// - CJK 单字（长度 == 1）：产出该字本身，如 `泵` → `泵`；
  /// - 拉丁/数字串（含小数点，如 `MPa`、`60`、`10.5`）：小写后**整体作 1 个 token**；
  /// - 连字符 / 斜杠 / 标点 / 空白：作分隔符丢弃（`km/h` → `km`,`h`）。
  static List<String> tokenize(String text) {
    final out = <String>[];
    final cjk = StringBuffer(); // 连续 CJK 字缓冲
    final word = StringBuffer(); // 连续拉丁/数字缓冲

    // 冲刷 CJK 缓冲：只产出相邻 bigram；长度 1 时产出单字。
    void flushCjk() {
      final s = cjk.toString();
      cjk.clear();
      if (s.isEmpty) return;
      if (s.length == 1) {
        out.add(s);
        return;
      }
      for (var i = 0; i + 1 < s.length; i++) {
        out.add(s.substring(i, i + 2));
      }
    }

    // 冲刷拉丁/数字缓冲：去掉首尾小数点（如句末 `kg.` → `kg`），非空则整体成 token。
    void flushWord() {
      var s = word.toString();
      word.clear();
      while (s.startsWith('.')) {
        s = s.substring(1);
      }
      while (s.endsWith('.')) {
        s = s.substring(0, s.length - 1);
      }
      if (s.isNotEmpty) out.add(s);
    }

    for (final r in normalize(text).runes) {
      if (_isCjk(r)) {
        flushWord();
        cjk.write(String.fromCharCode(r));
      } else if (_isWordChar(r)) {
        flushCjk();
        word.write(String.fromCharCode(r));
      } else {
        flushCjk();
        flushWord();
      }
    }
    flushCjk();
    flushWord();
    return out;
  }

  /// 覆盖率：查询 bigram 在候选块 bigram 中的命中比例，值域 `[0,1]`。
  ///
  /// `coverage = |Q ∩ C| / |Q|`；查询集为空时返回 `0`。
  static double coverage(Set<String> query, Set<String> chunk) {
    if (query.isEmpty) return 0;
    var hit = 0;
    for (final q in query) {
      if (chunk.contains(q)) hit++;
    }
    return hit / query.length;
  }

  /// 是否为 CJK 表意字符（基本区 + 扩展 A + 兼容表意区）。
  ///
  /// 这些码位均为 BMP（单 UTF-16 码元），故 [tokenize] 内按 `String.length` 取子串安全。
  static bool _isCjk(int r) =>
      (r >= 0x4E00 && r <= 0x9FFF) || // CJK 统一表意（基本区）
      (r >= 0x3400 && r <= 0x4DBF) || // CJK 扩展 A
      (r >= 0xF900 && r <= 0xFAFF); // CJK 兼容表意

  /// 是否为"词字符"：拉丁字母（调用前已小写）/ 数字 / 小数点。
  ///
  /// 小数点用于把 `10.5` 一类数字串保持为 1 个 token。
  static bool _isWordChar(int r) {
    if (r >= 0x30 && r <= 0x39) return true; // 0-9
    if (r >= 0x61 && r <= 0x7A) return true; // a-z
    if (r == 0x2E) return true; // '.'
    return false;
  }
}
