/// 全局尺寸常量（第 5 轮 UI 改版 · 规格表 §三/§四/§五 逐项）。
///
/// **全 app 唯一尺寸事实来源**：栅格宽度、组件高度、圆角、间距刻度
/// 只从 [AppDims] 取，任何页面不得新写魔法数。
///
/// 圆角 4/8/12 为体系值；`radiusSend = 6` 是规格 4.4 发送按钮的组件规格
/// 特例（架构设计冲突裁定 #4：组件规格优先于全局体系，不自行改值）。
library;

/// 尺寸 / 圆角 / 间距常量集。
abstract final class AppDims {
  // ---------------------------------------------------------------------
  // 整体布局栅格（规格 §五：以 1280×800 桌面窗口为基准）
  // ---------------------------------------------------------------------

  /// 左侧全局导航宽度（固定，不随窗口缩放）。
  static const double navWidth = 180;

  /// 中间列表栏宽度。
  static const double listWidth = 320;

  /// 中间列表栏最小宽度（窗口 <1000px 时收窄至此；架构设计待明确 #3）。
  static const double listMinWidth = 280;

  // ---------------------------------------------------------------------
  // 组件高度（规格 §4.1 / §4.2 / §4.3.1 / §4.4）
  // ---------------------------------------------------------------------

  /// 右栏标题栏高度（4.3.1）。
  static const double titleBarHeight = 56;

  /// 导航顶部 Logo 区高度（4.1）。
  static const double logoAreaHeight = 56;

  /// 导航项高度（4.1）。
  static const double navItemHeight = 40;

  /// 会话项高度（4.2）。
  static const double sessionItemHeight = 64;

  /// 中栏顶部搜索栏高度（4.2）。
  static const double searchBarHeight = 48;

  /// 搜索框高度（4.2）。
  static const double searchFieldHeight = 32;

  /// Tab 切换栏高度（4.2；B1 中栏省略 Tab，常量保留供 B3 页签复用）。
  static const double tabHeight = 36;

  /// 输入框顶部工具栏高度（4.4）。
  static const double toolbarHeight = 36;

  // ---------------------------------------------------------------------
  // 头像 / 图标
  // ---------------------------------------------------------------------

  /// 列表头像尺寸（4.2：36×36 圆角 12）。
  static const double avatarList = 36;

  /// 气泡头像尺寸（4.3.2：32×32）。
  static const double avatarBubble = 32;

  /// 导航 / 工具栏线性图标（4.1 / 4.4：18×18）。
  static const double iconNav = 18;

  /// 行内操作图标（4.5：16×16）。
  static const double iconInline = 16;

  /// 大图标（空态等：24×24）。
  static const double iconLarge = 24;

  // ---------------------------------------------------------------------
  // 圆角（规格 §3.1：4/8/12 体系 + 6px 发送按钮特例）
  // ---------------------------------------------------------------------

  /// 小圆角：复选框、按钮、标签、未读红点。
  static const double radiusS = 4;

  /// 中圆角：输入框、卡片、气泡、导航选中块。
  static const double radiusM = 8;

  /// 大圆角：头像、大卡片、弹窗。
  static const double radiusL = 12;

  /// 发送按钮圆角（4.4 组件规格特例 6px，冲突裁定 #4）。
  static const double radiusSend = 6;

  // ---------------------------------------------------------------------
  // 间距刻度（规格 §3.2：基于 8px 网格）
  // ---------------------------------------------------------------------

  /// 图标与文字间距、内边距微调。
  static const double space1 = 4;

  /// 小型内边距、元素间距。
  static const double space2 = 8;

  /// 卡片内边距、列表项内边距。
  static const double space3 = 12;

  /// 区域内边距、模块间距。
  static const double space4 = 16;

  /// 大区块外边距。
  static const double space5 = 20;

  /// 页面左右边距、顶部底部留白。
  static const double space6 = 24;

  // ---------------------------------------------------------------------
  // 卡片阴影几何（规格 4.5：`0 1px 2px` → 悬停 `0 2px 8px`）
  // ---------------------------------------------------------------------

  /// 卡片静态阴影纵向偏移。
  static const double cardShadowRestOffsetY = 1;

  /// 卡片静态阴影模糊半径。
  static const double cardShadowRestBlur = 2;

  /// 卡片悬停阴影纵向偏移。
  static const double cardShadowHoverOffsetY = 2;

  /// 卡片悬停阴影模糊半径。
  static const double cardShadowHoverBlur = 8;
}
