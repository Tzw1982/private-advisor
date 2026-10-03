/// 风格库（第 3 轮 · 专家级风格预设）。
///
/// 设计要点（架构设计 §3.4，写死）：
/// - 风格为**代码内置枚举**（Q2：自定义风格 P2 不做）；
/// - 落点 `expert_user_states.style_id`（专家级，市场更新**不覆盖**，与 `custom_prompt` 同级）；
/// - 生效范围：该专家**此后每次生成**（单聊 + 其参与群聊），**不改历史消息**；
/// - 关闭：`style_id = null` → 不注入；
/// - **注入顺序固定**：风格指令 → 有效提示词 → 严格规则 → 知识库证据。
library;

/// 专家风格预设（7 项，代码内置）。
enum ExpertStyle {
  professional('专业严谨', '请以专业严谨的口吻作答：先给结论，再给依据；用词准确、克制，避免口语化与夸张表述，必要时分点列出。'),
  amiable('亲和友善', '请以亲和友善的口吻作答：语气温暖、平等，多用共情与鼓励的表达，避免生硬术语。'),
  blunt('直言不讳', '请以直言不讳的口吻作答：不绕弯子，直接指出问题与风险，结论明确、态度坦率。'),
  imaginative('天马行空', '请以天马行空的口吻作答：鼓励发散联想与跨领域类比，大胆提出非常规思路。'),
  efficient('高效务实', '请以高效务实的口吻作答：直击要点、短句为主，优先给出可执行步骤，省略铺垫与客套。'),
  sharp('毒舌吐槽', '请以毒舌吐槽的口吻作答：幽默犀利、一针见血地点出明显问题，但保持善意，不进行人身攻击。'),
  heuristic('启发引导', '请以启发引导的口吻作答：多用提问引导对方思考，帮助其自行得出结论，不一次性给出全部答案。');

  const ExpertStyle(this.label, this.directive);

  /// 中文标签（UI 显示）。
  final String label;

  /// 注入 system 的风格指令正文（不含围栏头）。
  final String directive;

  /// 解析（`style_id` 存枚举 `name`）；非法 / 空 → null（不注入）。
  static ExpertStyle? parse(String? value) {
    if (value == null) return null;
    final v = value.trim();
    if (v.isEmpty) return null;
    for (final e in ExpertStyle.values) {
      if (e.name == v) return e;
    }
    return null;
  }
}

/// 风格指令构造工具。
abstract final class StyleLibrary {
  /// 全部预设（UI 下拉数据源）。
  static const List<ExpertStyle> all = ExpertStyle.values;

  /// 按 `style_id` 取风格；未知 / 空返回 null。
  static ExpertStyle? byId(String? id) => ExpertStyle.parse(id);

  /// 构造注入用的风格指令串；无风格（null / 空 / 未知）返回空串。
  ///
  /// 前缀 `【风格要求·<标签>】` 便于模型与人工排查定位。
  static String directiveFor(String? id) {
    final style = byId(id);
    if (style == null) return '';
    return buildStyleDirective(style);
  }

  /// 由枚举直接构造风格指令串。
  static String buildStyleDirective(ExpertStyle style) =>
      '【风格要求·${style.label}】${style.directive}';
}
