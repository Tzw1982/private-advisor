/// 通讯录排序（第 3 轮 · 首字母分组，PRD §5.2 / 架构设计 §3.5 / §5 裁定 #3、#7）。
///
/// 设计要点：
/// - [ContactSorter]（可验证内核）**与拼音来源解耦**：注入 `String Function(String) initialOf`，
///   换拼音库不影响排序/分组逻辑；
/// - **`#` 分组置顶**（非中文 / 数字开头 / 无法映射 → `#`）；
/// - 组内二次排序键 = **展示名（备注优先）**（由调用方传入 displayName）；
/// - 默认拼音来源 [PinyinInitial.of] 优先使用纯 Dart 库 `lpinyin`（沙箱内已实测可解析
///   中文首字母，含多音字 `重庆→cq` / 英文混排 `Alpha→A` / 数字开头 `11月→#`），
///   映射不到时回退内置高频字表 [PinyinInitial.builtinOf]。
library;

import 'dart:collection';

import 'package:lpinyin/lpinyin.dart';

/// 拼音首字母来源。
abstract final class PinyinInitial {
  /// 「其它」分组锚点（置顶）。
  static const String other = '#';

  /// 取展示名的首字母（A–Z）；无法映射 → [other]。
  ///
  /// 优先 `lpinyin`（整串取首字母，可借助词组消歧，如「重庆」→ C）；
  /// 库异常或解析不到字母时回退内置表。
  static String of(String name) {
    final s = name.trim();
    if (s.isEmpty) return other;
    try {
      final short = PinyinHelper.getShortPinyin(s);
      final letter = _firstLetter(short);
      if (letter != null) return letter;
    } catch (_) {
      // 库不可用时静默回退（不抛出，保持排序可用）。
    }
    return builtinOf(s);
  }

  /// 内置高频字表兜底（无拼音库环境 / 单测用）。
  static String builtinOf(String name) {
    final s = name.trim();
    if (s.isEmpty) return other;
    final first = String.fromCharCode(s.runes.first);
    final mapped = _builtinTable[first];
    if (mapped != null) return mapped;
    return _firstLetter(first) ?? other;
  }

  /// 从字符串取首个 A–Z 字母（拉丁字母大写化）；非字母返回 null。
  static String? _firstLetter(String s) {
    if (s.isEmpty) return null;
    final c = s.codeUnitAt(0);
    if (c >= 0x41 && c <= 0x5A) return String.fromCharCode(c); // A-Z
    if (c >= 0x61 && c <= 0x7A) return String.fromCharCode(c - 0x20); // a-z
    return null;
  }

  /// 内置高频字表（姓氏 / 常用字；lpinyin 可用时仅作兜底）。
  static const Map<String, String> _builtinTable = {
    '阿': 'A', '艾': 'A', '安': 'A', '敖': 'A',
    '白': 'B', '包': 'B', '鲍': 'B', '毕': 'B', '卞': 'B', '卜': 'B',
    '蔡': 'C', '曹': 'C', '岑': 'C', '常': 'C', '陈': 'C', '成': 'C', '程': 'C', '崔': 'C',
    '戴': 'D', '邓': 'D', '狄': 'D', '丁': 'D', '董': 'D', '杜': 'D', '段': 'D',
    '范': 'F', '方': 'F', '房': 'F', '费': 'F', '冯': 'F', '傅': 'F', '付': 'F',
    '甘': 'G', '高': 'G', '葛': 'G', '耿': 'G', '龚': 'G', '古': 'G', '顾': 'G', '关': 'G', '郭': 'G',
    '韩': 'H', '郝': 'H', '何': 'H', '贺': 'H', '洪': 'H', '侯': 'H', '胡': 'H', '华': 'H', '黄': 'H', '霍': 'H',
    '姬': 'J', '纪': 'J', '贾': 'J', '江': 'J', '姜': 'J', '蒋': 'J', '焦': 'J', '金': 'J', '康': 'K', '孔': 'K',
    '赖': 'L', '蓝': 'L', '郎': 'L', '雷': 'L', '黎': 'L', '李': 'L', '梁': 'L', '廖': 'L', '林': 'L', '凌': 'L',
    '刘': 'L', '柳': 'L', '龙': 'L', '卢': 'L', '陆': 'L', '吕': 'L', '罗': 'L', '骆': 'L',
    '马': 'M', '毛': 'M', '孟': 'M', '苗': 'M', '莫': 'M', '牟': 'M', '穆': 'M',
    '倪': 'N', '聂': 'N', '宁': 'N', '牛': 'N', '农': 'N',
    '欧': 'O',
    '潘': 'P', '庞': 'P', '裴': 'P', '彭': 'P', '皮': 'P', '蒲': 'P',
    '齐': 'Q', '钱': 'Q', '乔': 'Q', '秦': 'Q', '邱': 'Q', '裘': 'Q', '屈': 'Q', '曲': 'Q',
    '任': 'R', '荣': 'R', '阮': 'R', '芮': 'R',
    '萨': 'S', '邵': 'S', '沈': 'S', '盛': 'S', '施': 'S', '石': 'S', '史': 'S', '宋': 'S', '苏': 'S', '孙': 'S',
    '谭': 'T', '汤': 'T', '唐': 'T', '陶': 'T', '田': 'T', '童': 'T', '涂': 'T',
    '万': 'W', '汪': 'W', '王': 'W', '韦': 'W', '卫': 'W', '魏': 'W', '温': 'W', '文': 'W', '翁': 'W', '吴': 'W', '伍': 'W', '武': 'W',
    '席': 'X', '夏': 'X', '项': 'X', '肖': 'X', '谢': 'X', '邢': 'X', '熊': 'X', '徐': 'X', '许': 'X', '薛': 'X',
    '严': 'Y', '言': 'Y', '阎': 'Y', '颜': 'Y', '杨': 'Y', '姚': 'Y', '叶': 'Y', '易': 'Y', '殷': 'Y', '尹': 'Y',
    '尤': 'Y', '于': 'Y', '余': 'Y', '俞': 'Y', '虞': 'Y', '袁': 'Y', '岳': 'Y', '云': 'Y',
    '臧': 'Z', '曾': 'Z', '翟': 'Z', '詹': 'Z', '张': 'Z', '章': 'Z', '赵': 'Z', '郑': 'Z', '钟': 'Z', '周': 'Z',
    '朱': 'Z', '诸': 'Z', '祝': 'Z', '庄': 'Z', '卓': 'Z', '邹': 'Z', '左': 'Z',
  };
}

/// 通讯录排序 / 分组内核（纯逻辑）。
abstract final class ContactSorter {
  /// 「其它」分组锚点（与 [PinyinInitial.other] 一致）。
  static const String otherInitial = PinyinInitial.other;

  /// 初始分组的排序权重：`#` 置顶（-1），A→Z 依次 0..25，其余（不应出现）排最后。
  static int rankOf(String initial) {
    if (initial == otherInitial) return -1;
    if (initial.length == 1) {
      final c = initial.codeUnitAt(0);
      if (c >= 0x41 && c <= 0x5A) return c - 0x41;
    }
    return 100;
  }

  /// 按首字母分组排序（`#` 置顶，A→Z）。
  ///
  /// - [nameOf]：取用于排序的**展示名（备注优先）**；
  /// - [initialOf]：取首字母（解耦拼音来源）；
  /// - [sortKeyOf]：组内二次排序键（默认取 [nameOf] 本身；可传全拼）。
  static List<T> sortByName<T>(
    List<T> items, {
    required String Function(T) nameOf,
    required String Function(String) initialOf,
    String Function(String)? sortKeyOf,
    bool descending = false,
  }) {
    final keyOf = sortKeyOf ?? (String s) => s;
    final out = List<T>.from(items);
    out.sort((a, b) {
      final na = nameOf(a);
      final nb = nameOf(b);
      final ra = rankOf(initialOf(na));
      final rb = rankOf(initialOf(nb));
      if (ra != rb) return ra.compareTo(rb);
      final ka = keyOf(na).toLowerCase();
      final kb = keyOf(nb).toLowerCase();
      final keyCmp = ka.compareTo(kb);
      if (keyCmp != 0) return descending ? -keyCmp : keyCmp;
      // 稳定兜底：按原展示名比较，避免同键抖动。
      final rawCmp = na.compareTo(nb);
      return descending ? -rawCmp : rawCmp;
    });
    return out;
  }

  /// 按首字母分组：返回 `LinkedHashMap`，键序为 `#`（若有）→ A→Z，
  /// 组内保持 [sortByName] 的顺序。
  static LinkedHashMap<String, List<T>> groupByInitial<T>(
    List<T> items, {
    required String Function(T) nameOf,
    required String Function(String) initialOf,
    String Function(String)? sortKeyOf,
  }) {
    final sorted = sortByName(
      items,
      nameOf: nameOf,
      initialOf: initialOf,
      sortKeyOf: sortKeyOf,
    );
    final map = LinkedHashMap<String, List<T>>();
    for (final it in sorted) {
      final initial = initialOf(nameOf(it));
      map.putIfAbsent(initial, () => <T>[]).add(it);
    }
    final orderedKeys = map.keys.toList()
      ..sort((a, b) => rankOf(a).compareTo(rankOf(b)));
    final result = LinkedHashMap<String, List<T>>();
    for (final k in orderedKeys) {
      result[k] = map[k]!;
    }
    return result;
  }
}
