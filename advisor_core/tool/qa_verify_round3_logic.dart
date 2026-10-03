/// QA 独立验证脚本（严过关）——第 3 轮「#35 缺口」补验：风格注入顺序 / 思考剥离
/// 保守性 / 发言范围边界 / **思考剥离是否真正接线**。
///
/// 运行：`cd advisor_core && dart run tool/qa_verify_round3_logic.dart`
///
/// 与工程师 `verify_round3.dart` 相互独立：直接调用生产 API 断言**行为**，并额外做
/// **静态接线检查**（纯函数被测通过 ≠ 生产链路真正调用它）。
library;

import 'dart:io';

import 'package:advisor_core/advisor_core.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架
// ---------------------------------------------------------------------------

class C {
  C(this.id, this.name, this.expected, this.actual, this.pass, [this.note]);
  final String id, name, expected, actual;
  final bool pass;
  final String? note;
}

final List<C> _res = [];
int _pass = 0, _fail = 0;

void t(String id, String name, Object? expected, Object? actual, {String? note}) {
  final ok = expected == actual;
  if (ok) {
    _pass++;
  } else {
    _fail++;
  }
  _res.add(C(id, name, '$expected', '$actual', ok, note));
  stdout.writeln('  ${ok ? '✓' : '✗'} [$id] $name  (期望=$expected 实际=$actual)');
}

void section(String s) => stdout.writeln('\n── $s ──────────────────────────');

// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('严过关 · 独立 QA 验证（第 3 轮缺口：风格顺序 / 思考剥离 / 接线）');
  stdout.writeln('=' * 62);

  _t_styleOrder();
  _t_reasoningConservative();
  _t_directiveBoundary();
  _t_wiring();

  _print();
  exitCode = _fail == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// L. 风格注入顺序：风格 → 有效提示词 → 群级块 → 严格规则 → 知识库证据
// ---------------------------------------------------------------------------

void _t_styleOrder() {
  section('L 风格注入顺序（严格下标递增，非仅"存在")');

  const promptMark = 'SYS_PROMPT_MARK_有效提示词';
  const groupMark = 'GROUP_BLOCK_MARK_群级块';
  final evidence = [
    const Citation(
        chunkId: 'c1', documentId: 'd1', fileName: '规格书.md', text: '水罐容积6000升', score: 0.9),
  ];
  final style = StyleLibrary.directiveFor('professional'); // 【风格要求·专业严谨】…
  final msgs = ContextManager.build(
    systemPrompt: promptMark,
    styleDirective: style,
    groupBlocks: groupMark,
    userTask: '用户任务',
    evidence: evidence,
    strictGrounding: true,
  );
  final system = msgs.first.content;

  final iStyle = system.indexOf('【风格要求·');
  final iPrompt = system.indexOf(promptMark);
  final iGroup = system.indexOf(groupMark);
  final iStrict = system.indexOf(GroundingResolver.strictSystemRule);
  final iEv = system.indexOf('以下是可引用的知识库片段');

  t('L1', '五段全部出现', true,
      iStyle >= 0 && iPrompt >= 0 && iGroup >= 0 && iStrict >= 0 && iEv >= 0);
  t('L2', '风格 在 提示词 之前', true, iStyle < iPrompt, note: 'idx $iStyle < $iPrompt');
  t('L3', '提示词 在 群级块 之前', true, iPrompt < iGroup, note: 'idx $iPrompt < $iGroup');
  t('L4', '群级块 在 严格规则 之前', true, iGroup < iStrict, note: 'idx $iGroup < $iStrict');
  t('L5', '严格规则 在 知识库证据 之前', true, iStrict < iEv, note: 'idx $iStrict < $iEv');
  t('L6', '下标严格递增（完整序）', true,
      iStyle < iPrompt && iPrompt < iGroup && iGroup < iStrict && iStrict < iEv,
      note: '[$iStyle,$iPrompt,$iGroup,$iStrict,$iEv]');

  // 关闭风格（null / ''）→ 不注入
  final noStyle = ContextManager.build(
    systemPrompt: promptMark,
    styleDirective: StyleLibrary.directiveFor(null),
    userTask: 't',
  ).first.content;
  t('L7', 'style=null → 不注入风格头', false, noStyle.contains('【风格要求·'));
  t('L8', 'style=null → directiveFor 返回空串', '', StyleLibrary.directiveFor(null));
  t('L9', '未知 style_id → 不注入（parse=null）', null, ExpertStyle.parse('no_such_style'));
  t('L10', '空 groupBlocks → 不产生多余空段', false,
      ContextManager.build(systemPrompt: 'p', styleDirective: '', userTask: 't')
          .first
          .content
          .contains('GROUP_BLOCK_MARK_群级块'));
}

// ---------------------------------------------------------------------------
// R. 思考剥离保守性：**不该删的绝不删**
// ---------------------------------------------------------------------------

void _t_reasoningConservative() {
  section('R 思考剥离保守性（重点：不该删的没被删）');

  // R1 正文中间的元叙述（非句首）→ 不动
  const mid = '该方案成本偏高。让我想想还有没有别的办法。';
  t('R1', '句中"让我想想"不被删（非句首）', mid, ReasoningStripper.strip(mid).text);

  // R2 正常内容含"我认为" → 不动
  const opinion = '我认为该方案可行，建议尽快推进。';
  t('R2', '"我认为…"正常内容不被误删', opinion, ReasoningStripper.strip(opinion).text);

  // R3 段首且含思考动词 → 剥离首句，保留正文
  final r3 = ReasoningStripper.strip('让我分析一下。该方案成本偏高，建议改用方案B。');
  t('R3a', '段首"让我分析一下。"被剥离', false, r3.text.contains('让我分析一下'));
  t('R3b', '正文得以保留', true, r3.text.contains('该方案成本偏高'));

  // R4 段首但**无思考动词**（只有句首词）→ 不剥离（保守）
  const noVerb = '让我给你三点建议：一是快，二是稳，三是省。';
  t('R4', '段首无思考动词 → 不剥离', noVerb, ReasoningStripper.strip(noVerb).text);

  // R5 显式围栏【思考】→ 剥离
  final r5 = ReasoningStripper.strip('【思考】内部推理草稿【/思考】结论：建议选 A。');
  t('R5a', '围栏内容被剥离', false, r5.text.contains('内部推理草稿'));
  t('R5b', '围栏外正文保留', true, r5.text.contains('结论：建议选 A'));

  // R6 全 meta 输入 → 防守回退原文（绝不清空）
  const allMeta = '让我想想。';
  t('R6', '纯 meta 输入不清空（回退原文）', allMeta, ReasoningStripper.strip(allMeta).text);

  // R7 超长句（>30 字）段首 → 长度守卫，不剥离
  final longLead =
      '让我分析一下这段很长的补充说明文字用于超过三十个字符从而触发长度守卫以避免误删而保留整段。';
  t('R7', '超长段首句不剥离（>30 字守卫）', longLead, ReasoningStripper.strip(longLead).text);

  // R8 空串 → 原样返回
  t('R8', '空串原样返回', '', ReasoningStripper.strip('').text);
}

// ---------------------------------------------------------------------------
// B. 发言范围边界（空 / 纯标点 / 零成员）
// ---------------------------------------------------------------------------

void _t_directiveBoundary() {
  section('B 发言范围边界（空 / 纯标点 / 零成员）');
  GroupMember m(String id, String name, {int sort = 0}) =>
      GroupMember(expertId: id, name: name, sortOrder: sort);
  final members = [m('eL', '李组'), m('eM1', '张工')];

  t('B1', '空文本 → null', null,
      GroupDirectiveResolver.resolve(userText: '', members: members, leaderId: 'eL'));
  t('B2', '纯空白 → null', null,
      GroupDirectiveResolver.resolve(userText: '   \n\t ', members: members, leaderId: 'eL'));
  t('B3', '纯标点 → null', null,
      GroupDirectiveResolver.resolve(userText: '。。。！？、、', members: members, leaderId: 'eL'));
  t('B4', '零成员 → null', null,
      GroupDirectiveResolver.resolve(userText: '大家都说说', members: const [], leaderId: 'x'));
  t('B5', '正常指令仍可解析（对照）', 'eL,eM1',
      GroupDirectiveResolver.resolve(userText: '大家都说说', members: members, leaderId: 'eL')
          ?.expertIds
          .join(','));
}

// ---------------------------------------------------------------------------
// W. 静态接线检查：纯函数被测通过 ≠ 生产链路真正调用它
// ---------------------------------------------------------------------------

void _t_wiring() {
  section('W 接线检查：ReasoningStripper 是否被生产代码调用');
  final root = File.fromUri(Platform.script).parent.parent.parent; // 仓库根
  final dirs = [
    Directory('${root.path}${Platform.pathSeparator}advisor_core'
        '${Platform.pathSeparator}lib'),
    Directory('${root.path}${Platform.pathSeparator}app${Platform.pathSeparator}lib'),
  ];
  final hits = <String>[];
  for (final d in dirs) {
    if (!d.existsSync()) continue;
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('reasoning.dart')) continue; // 定义处本身
      final src = f.readAsStringSync();
      if (src.contains('ReasoningStripper') || src.contains('PresentedContent')) {
        hits.add(f.path);
      }
    }
  }
  t('W1', '生产代码中存在 ReasoningStripper/PresentedContent 调用点（已真实接线）', true,
      hits.isNotEmpty,
      note: '调用点=${hits.join(", ")}'
          '（原为症状记录式断言：接线前 hits=0；T03 起已在 services.dart 接线，改为正向断言）');
}

// ---------------------------------------------------------------------------

void _print() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('# QA 用例表（第3轮缺口补验）');
  stdout.writeln('| ID | 用例 | 期望 | 实际 | 结论 |');
  stdout.writeln('|----|------|------|------|------|');
  for (final r in _res) {
    stdout.writeln(
        '| ${r.id} | ${r.name} | ${r.expected.replaceAll('|', r'\|')} | ${r.actual.replaceAll('|', r'\|')} | ${r.pass ? 'PASS' : 'FAIL'} |');
  }
  stdout.writeln('\n合计：通过 $_pass ／ 失败 $_fail');
  if (_fail > 0) {
    stdout.writeln('\n失败明细：');
    for (final r in _res.where((r) => !r.pass)) {
      stdout.writeln('  - [${r.id}] ${r.name}：期望=${r.expected} 实际=${r.actual}'
          '${r.note == null ? '' : '  （${r.note}）'}');
    }
  }
}
