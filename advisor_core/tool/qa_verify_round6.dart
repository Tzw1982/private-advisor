/// QA 独立验证脚本（严过关）——第 6 轮「群聊体验改造」T01–T04 纯逻辑层。
///
/// 运行：`cd advisor_core && dart run tool/qa_verify_round6.dart`
///
/// 设计原则（与工程师的 verify_round6*.dart **相互独立**）：
/// - 自行构造成员 / 指令 / 语料，直接断言**行为**，不复制工程师断言的措辞；
/// - 覆盖四条用户根因：①组长说了算（发言范围）②无关成员刷屏（相关性粗筛）
///   ③组长没被认可（角色声明注入）④@ 必选不被挤掉；
/// - E2E：用 `inMemoryRepositories` + `ScriptedLlmProvider` 真跑 `runGroupChat`，
///   验证**静默契约**（`【不参与】` → 消息 cancelled 且正文清空、绝不产生可见气泡）。
/// - 只读取 / 调用生产代码，不修改任何生产代码。
library;

import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架
// ---------------------------------------------------------------------------

class Case {
  Case(this.id, this.name, this.expected, this.actual, this.pass, [this.note]);
  final String id, name, expected, actual;
  final bool pass;
  final String? note;
}

final List<Case> _res = [];
int _pass = 0, _fail = 0;

void t(String id, String name, Object? expected, Object? actual, {String? note}) {
  final ok = expected == actual;
  if (ok) {
    _pass++;
  } else {
    _fail++;
  }
  _res.add(Case(id, name, '$expected', '$actual', ok, note));
  stdout.writeln('  ${ok ? '✓' : '✗'} [$id] $name  (期望=$expected 实际=$actual)');
}

void section(String s) => stdout.writeln('\n── $s ──────────────────────────');

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// **async\* 惰性护栏**：`runGroupChat` / `runSingleChat` 等是 `async*`
/// （惰性 Stream），`await stream` 只是拿到 Stream 对象，**函数体（含编排、
/// 落库、静默契约判断）根本不会执行**。必须消费它（`await for`/`toList`/
/// `forEach`）才会真正跑，错误也才在此处抛出。所有此类调用点统一走本 helper，
/// 杜绝“未消费 → 断言得到假 Null（假绿/假红）”。
Future<void> _drain(Stream<dynamic> stream) => stream.forEach((_) {});

// ---------------------------------------------------------------------------
// 成员夹具（全脚本复用；名称/标签为自造，非工程师样本）
// ---------------------------------------------------------------------------

GroupMember _m(String id, String name, List<String> tags,
        {MemberRole role = MemberRole.member, int sort = 0}) =>
    GroupMember(expertId: id, name: name, expertise: tags, role: role, sortOrder: sort);

final _leader = _m('eL', '李组', ['消防车'], role: MemberRole.leader, sort: 0);
final _zhang = _m('eM1', '张工', ['消防车泵'], sort: 1);
final _wang = _m('eM2', '王律', ['合同法'], sort: 2);

Message _user(String text) => Message(
      id: 'um',
      conversationId: 'c6',
      senderType: MessageSenderType.user,
      content: text,
      createdAt: 0,
      updatedAt: 0,
    );

GroupContext _ctx(String userText,
        {List<GroupMember>? members, List<ExpertOutput> prev = const []}) =>
    GroupContext(
      conversationId: 'c6',
      userMessage: _user(userText),
      members: members ?? [_leader, _zhang, _wang],
      previousSpeakerOutputs: prev,
    );

Future<void> main() async {
  stdout.writeln('严过关 · 独立 QA 验证（第 6 轮 群聊体验改造）');
  stdout.writeln('=' * 62);
  stdout.writeln('dart = ${Platform.version}');

  _t_relevance();
  _t_directive();
  _t_composer();
  await _t_leaderLed();
  _t_shortAck();
  _t_contactSort();
  await _t_e2eRunGroupChat();

  _print();
  exitCode = _fail == 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------
// A. 相关性 / 唯一分词口径（T01 · B3）
// ---------------------------------------------------------------------------

void _t_relevance() {
  section('A 相关性 & 唯一分词口径（T01 · B3）');

  // A1 中文：逐字 + 相邻 2-gram，去重
  final fire = ExpertiseTokenizer.tokenize('消防车');
  t('A1', 'tokenize("消防车") 恰好 5 个 token', 5, fire.length,
      note: '实际=${fire.toList()}');
  t('A1a', '含单字 消/防/车', true,
      fire.containsAll(<String>['消', '防', '车']));
  t('A1b', '含 bigram 消防/防车', true, fire.containsAll(<String>['消防', '防车']));
  t('A1c', '无 3-gram（如 消防车）', false, fire.contains('消防车'));

  // A2 拉丁/数字整体小写成 token
  final mpa = ExpertiseTokenizer.tokenize('MPa 60').toList()..sort();
  t('A2', 'tokenize("MPa 60") = {60, mpa}', '[60, mpa]', '$mpa');

  // A3 唯一口径：AutoStrategy.tokenize 必须与 ExpertiseTokenizer 逐字相同
  const probe = '举高喷射臂架系统 60m MPa';
  t('A3', 'AutoStrategy.tokenize == ExpertiseTokenizer.tokenize', true,
      _setEq(AutoStrategy.tokenize(probe), ExpertiseTokenizer.tokenize(probe)));

  // A4 score：命中 token / 标签 token 数（标签 ['消防车'] vs 查询含全部 → 1.0）
  final s1 = MemberRelevanceScorer.score('消防车举高', _leader);
  t('A4', 'score(消防车举高, 标签[消防车]) = 1.0', 1.0, s1);

  // A5 总结者 0.5 折扣
  final summ = _m('eS', '总结员', ['消防车'], role: MemberRole.summarizer);
  t('A5', '总结者同标签 score 打折 = 0.5', 0.5, MemberRelevanceScorer.score('消防车举高', summ));

  // A6 rank：相关度降序；同分按 sortOrder 升序
  final ranked = MemberRelevanceScorer.rank('消防车泵', [_wang, _zhang, _leader]);
  t('A6', 'rank 首位为高相关成员（张工/李组 同为满分）', true,
      ranked.first.expertId == 'eM1' || ranked.first.expertId == 'eL',
      note: '实际序=${ranked.map((m) => m.expertId).toList()}');
  t('A6b', 'rank 末位为不相关成员（王律）', 'eM2', ranked.last.expertId);

  // A7 relevantAbove：0 相关者被过滤
  final rel = MemberRelevanceScorer.relevantAbove('消防车泵', [_leader, _zhang, _wang]);
  t('A7', 'relevantAbove 仅保留相关成员（王律被滤）', 'eL,eM1',
      (rel.map((m) => m.expertId).toList()..sort()).join(','));

  // A8 空查询 → 全部 0
  t('A8', '空查询 score=0', 0.0, MemberRelevanceScorer.score('   ', _leader));
}

bool _setEq(Set<String> a, Set<String> b) =>
    a.length == b.length && a.difference(b).isEmpty;

// ---------------------------------------------------------------------------
// B. 发言范围指令解析（T03）
// ---------------------------------------------------------------------------

void _t_directive() {
  section('B 发言范围指令解析（T03）');
  final members = [_leader, _zhang, _wang];
  SpeakerDirective? r(String s) =>
      GroupDirectiveResolver.resolve(userText: s, members: members, leaderId: 'eL');

  // ① 仅组长一人
  final b1 = r('请组长一个人发言');
  t('B1', '“请组长一个人发言” → 仅组长', 'eL', b1?.expertIds.join(','));
  t('B1b', 'isFullGroup=false', false, b1?.isFullGroup);
  t('B1c', '依据含“仅组长”', true, b1?.reason.contains('仅组长'));

  // ② 组长发言
  final b2 = r('组长来说两句');
  t('B2', '“组长来说两句” → 仅组长', 'eL', b2?.expertIds.join(','));

  // ③ 全体
  final b3 = r('大家都说说看法');
  t('B3', '“大家都说说” → 全员（按 sortOrder）', 'eL,eM1,eM2', b3?.expertIds.join(','));
  t('B3b', 'isFullGroup=true', true, b3?.isFullGroup);

  // ④ 点名：@
  final b4 = r('@张工 你怎么看');
  t('B4', '“@张工” → 张工', 'eM1', b4?.expertIds.join(','));

  // ④ 点名：名称 + 发言动词（含“让/请/叫/只让”前缀）
  final b5 = r('让张工说说');
  t('B5', '“让张工说说” → 张工', 'eM1', b5?.expertIds.join(','));
  final b5b = r('只让王律来回答');
  t('B5b', '“只让王律来回答” → 王律', 'eM2', b5b?.expertIds.join(','));

  // ⑤ 未命中 → null
  t('B6', '“随便聊聊天气” → null（回落策略）', null, r('随便聊聊天气'));
  t('B7', '空文本 → null', null, r('   '));

  // 边界：无组长时“仅组长”无法执行 → null
  final noLeader =
      GroupDirectiveResolver.resolve(userText: '请组长一个人发言', members: members, leaderId: null);
  t('B8', '无组长时“仅组长” → null', null, noLeader);

  // 边界：空成员 → null
  final empty = GroupDirectiveResolver.resolve(userText: '组长发言', members: const [], leaderId: 'x');
  t('B9', '空成员 → null', null, empty);

  // 优先级：同时含“组长一人”与点名 → 先命中①（更具体）
  final prio = r('组长一个人发言就行，别叫张工了');
  t('B10', '①仅组长 优先于 ④点名', 'eL', prio?.expertIds.join(','));
}

// ---------------------------------------------------------------------------
// C. 群级提示词组装（T03）
// ---------------------------------------------------------------------------

void _t_composer() {
  section('C 群级提示词组装（T03）');

  // C1 公告块逐字携带
  final c1 = GroupPromptComposer.consensusBlock('本群共识：先给结论再展开');
  t('C1', 'consensusBlock 含公告原文', true, c1.contains('本群共识：先给结论再展开'));
  t('C1b', '含“共识/公告”抬头', true, c1.contains('共识'));

  // C2 空 / null / 空白 → 空串（硬契约）
  t('C2', 'consensusBlock(null)==""', '', GroupPromptComposer.consensusBlock(null));
  t('C2b', 'consensusBlock("  ")==""', '', GroupPromptComposer.consensusBlock('   '));
  t('C2c', 'consensusBlock("")==""', '', GroupPromptComposer.consensusBlock(''));

  // C3 角色声明区分组长/组员
  final cL = GroupPromptComposer.roleBlock(selfName: '李组', role: MemberRole.leader);
  final cM = GroupPromptComposer.roleBlock(
      selfName: '张工', role: MemberRole.member, leaderName: '李组');
  t('C3', '组长块含“组长”+姓名', true, cL.contains('组长') && cL.contains('李组'));
  t('C3b', '组员块含“组员”+组长姓名', true, cM.contains('组员') && cM.contains('李组'));

  // C4 相关性自判须含静默哨兵
  t('C4', 'nonParticipationRule 含【不参与】', true,
      GroupPromptComposer.nonParticipationRule.contains(kNonParticipationToken));

  // C5 block() 聚合：公告 + 角色 + 范围 + 纪律 + 自判 全含（system 注入契约）
  final blk = GroupPromptComposer.block(
    selfName: '张工',
    role: MemberRole.member,
    leaderName: '李组',
    announcement: '共识ABC',
    directive: SpeakerDirective(expertIds: ['eM1'], reason: 'x'),
    speakerNames: ['张工'],
  );
  t('C5', 'block() 含公告文本', true, blk.contains('共识ABC'));
  t('C5b', 'block() 含角色声明', true, blk.contains('【群角色】'));
  t('C5c', 'block() 含发言范围', true, blk.contains('【本轮发言范围】'));
  t('C5d', 'block() 含表达纪律', true, blk.contains('【表达纪律】'));
  t('C5e', 'block() 含相关性自判哨兵', true, blk.contains(kNonParticipationToken));

  // C6 includeNonParticipation=false 时不注入
  final blk2 = GroupPromptComposer.block(
    selfName: '张工',
    role: MemberRole.member,
    includeNonParticipation: false,
  );
  t('C6', 'includeNonParticipation=false 时不含哨兵', false,
      blk2.contains(kNonParticipationToken));

  // C7 scopeBlock 分支
  t('C7', 'scopeBlock(null) 提示按策略自动', true,
      GroupPromptComposer.scopeBlock(null, const []).contains('自动选择'));
  t('C7b', 'scopeBlock(全員) 提示全员参与', true,
      GroupPromptComposer.scopeBlock(
              SpeakerDirective(expertIds: ['a'], reason: 'x', isFullGroup: true), ['A'])
          .contains('全员参与'));
  t('C7c', 'scopeBlock(指定) 提示其余静默', true,
      GroupPromptComposer.scopeBlock(
              SpeakerDirective(expertIds: ['a'], reason: 'x'), ['A'])
          .contains('静默'));
}

// ---------------------------------------------------------------------------
// D. 组长主持策略（T03 · B3）
// ---------------------------------------------------------------------------

Future<void> _t_leaderLed() async {
  section('D 组长主持策略 LeaderLedStrategy（T03 · B3）');

  // D1 @必选 + 组长先行
  final d1 = await LeaderLedStrategy(maxSpeakers: 3)
      .selectNextSpeakers(_ctx('@王律 麻烦说下合同风险'));
  t('D1', '@王律 必选', true, d1.primarySpeakers.contains('eM2'),
      note: 'speakers=${d1.primarySpeakers}');
  t('D1b', '组长先行（首位=李组）', 'eL', d1.primarySpeakers.first);

  // D2 相关性粗筛：消防车泵 → 李组 + 张工；王律被滤
  final d2 = await LeaderLedStrategy(maxSpeakers: 3)
      .selectNextSpeakers(_ctx('消防车泵的流量怎么算'));
  t('D2', '相关成员上位（含张工）', true, d2.primarySpeakers.contains('eM1'));
  t('D2b', '不相关成员被滤（无王律）', false, d2.primarySpeakers.contains('eM2'));
  t('D2c', '命中人数 = 2', 2, d2.primarySpeakers.length);

  // D3 @必选不被“仅组长”兜底挤掉：点名但话题与所有人无关
  final d3 = await LeaderLedStrategy(maxSpeakers: 3)
      .selectNextSpeakers(_ctx('@王律 今天天气不错'));
  t('D3', '@必选者在场（forcedCount>0 不触发兜底）', true,
      d3.primarySpeakers.contains('eM2'),
      note: 'speakers=${d3.primarySpeakers}');
  t('D3b', '兜底未触发：不止组长一人', true, d3.primarySpeakers.length >= 2);

  // D4 不冷场兜底：无 @ 且全员不相关 → 仅组长
  //    注：用于触发兜底的文本必须与**所有**标签 token 无交集。此前用「今天天气不错适合钓鱼」
  //    因含「合」与「合同法」重合而被正确判为相关（实现无误，是测试用例选词不当）。
  final d4 = await LeaderLedStrategy(maxSpeakers: 3)
      .selectNextSpeakers(_ctx('今天天气真好啊'));
  t('D4', '全员不相关 → 仅组长（不冷场、不退化全员）', 'eL', d4.primarySpeakers.join(','));
  t('D4b', '且未退化全员（长度=1）', 1, d4.primarySpeakers.length);

  // D5 maxSpeakers=1 时 @必选优先于组长占位
  final d5 = await LeaderLedStrategy(maxSpeakers: 1)
      .selectNextSpeakers(_ctx('@王律 说说'));
  t('D5', 'maxSpeakers=1 时 @必选优先（王律）', 'eM2', d5.primarySpeakers.join(','));

  // D6 maxSpeakers=1 无 @ → 组长占唯一名额
  final d6 = await LeaderLedStrategy(maxSpeakers: 1)
      .selectNextSpeakers(_ctx('消防车泵'));
  t('D6', 'maxSpeakers=1 无@ → 仅组长', 'eL', d6.primarySpeakers.join(','));

  // D7 组长上一轮 @提名 → 被点名者强制入选
  final prev = [
    ExpertOutput(expertId: 'eL', expertName: '李组', content: '请 @王律 从合同角度补充'),
  ];
  final d7 = await LeaderLedStrategy(maxSpeakers: 3)
      .selectNextSpeakers(_ctx('继续', prev: prev));
  t('D7', '组长上轮 @提名 → 被提名者入选', true, d7.primarySpeakers.contains('eM2'),
      note: 'speakers=${d7.primarySpeakers}');

  // D8 空成员 → none
  final d8 = await LeaderLedStrategy().selectNextSpeakers(_ctx('随便', members: const []));
  t('D8', '空成员 → SpeakerPlan.none', true, d8.isEmpty);

  // D9 无组长时：不冷场兜底不成立 → 退化为相关性选择（避免返回空）
  final noLeaderCtx = GroupContext(
    conversationId: 'c6',
    userMessage: _user('消防车泵'),
    members: [_zhang, _wang],
  );
  final d9 = await LeaderLedStrategy(maxSpeakers: 3).selectNextSpeakers(noLeaderCtx);
  t('D9', '无组长 + 有相关成员 → 仍选出张工', true, d9.primarySpeakers.contains('eM1'));
}

// ---------------------------------------------------------------------------
// E. 短回执 + 组长策略（T02/T03）
// ---------------------------------------------------------------------------

void _t_shortAck() {
  section('E 短回执判定 & 组长策略（T02/T03）');

  t('E1', '“收到”=短回执', true, ShortAckDetector.isShortAck('收到'));
  t('E2', '“好的，明白了”=短回执', true, ShortAckDetector.isShortAck('好的，明白了'));
  t('E3', '“了解”=短回执', true, ShortAckDetector.isShortAck('了解'));
  t('E4', '超 12 字实质发言 ≠ 短回执', false,
      ShortAckDetector.isShortAck('收到，但我认为这个方案还需要进一步讨论'));
  t('E5', '长句无“收到”类词 ≠ 短回执', false,
      ShortAckDetector.isShortAck('这是一个很长的正常回复内容'));
  t('E6', '空串 ≠ 短回执', false, ShortAckDetector.isShortAck('   '));
  t('E7', '阈值常量 = 12', 12, kShortAckMaxChars);

  // 组长策略
  final members = [
    const ConversationMember(conversationId: 'c6', expertId: 'a'),
    const ConversationMember(conversationId: 'c6', expertId: 'b'),
    const ConversationMember(conversationId: 'c6', expertId: 'c', role: MemberRole.leader),
  ];
  final promoted = GroupRolePolicy.promoteToLeader(members, 'a');
  t('E8', '提升 a 为组长后组长数=1', 1,
      promoted.where((m) => m.role == MemberRole.leader).length);
  t('E8b', '原组长 c 自动降为 member', MemberRole.member,
      promoted.firstWhere((m) => m.expertId == 'c').role);
  t('E9', 'validateMembers 两组长 → 报错', true,
      GroupRolePolicy.validateMembers([
        const ConversationMember(conversationId: 'x', expertId: '1', role: MemberRole.leader),
        const ConversationMember(conversationId: 'x', expertId: '2', role: MemberRole.leader),
      ]) != null);
  t('E10', '删到 0 成员被拒', false,
      GroupRolePolicy.removeMember(
              [const ConversationMember(conversationId: 'x', expertId: '1')], '1')
          .applied);
  t('E10b', 'effectiveSummarizerId(null) 回退组长', 'c',
      GroupRolePolicy.effectiveSummarizerId(null, members));
  t('E10c', 'effectiveSummarizerId(配置值) 优先', 'zzz',
      GroupRolePolicy.effectiveSummarizerId('zzz', members));
}

// ---------------------------------------------------------------------------
// G. 通讯录排序内核（T02，纯逻辑）
// ---------------------------------------------------------------------------

void _t_contactSort() {
  section('G 通讯录排序内核（T02）');

  t('G1', 'PinyinInitial.of("张")=Z', 'Z', PinyinInitial.of('张'));
  t('G2', 'PinyinInitial.of("王")=W', 'W', PinyinInitial.of('王'));
  t('G3', 'PinyinInitial.of("alice")=A', 'A', PinyinInitial.of('alice'));
  t('G4', 'PinyinInitial.of("")=#', '#', PinyinInitial.of('   '));
  t('G5', 'rankOf(#) 置顶 = -1', -1, ContactSorter.rankOf('#'));
  t('G6', 'rankOf(A)=0', 0, ContactSorter.rankOf('A'));

  final names = ['张三', '李四', 'alice', '9号', '王五'];
  final sorted = ContactSorter.sortByName<String>(names,
      nameOf: (s) => s, initialOf: PinyinInitial.of);
  // # 置顶（9号），随后 A(alice)，再 L(李四)，再 W(王五)，最后 Z(张三)
  t('G7', '排序：#置顶 → A → L → W → Z', true,
      sorted.indexOf('9号') == 0 && sorted.indexOf('alice') < sorted.indexOf('李四'),
      note: 'sorted=$sorted');
  t('G7b', '组内 A 在前、Z 在后', true,
      sorted.indexOf('alice') < sorted.indexOf('张三'));
}

// ---------------------------------------------------------------------------
// F. E2E：runGroupChat 静默契约（T04）
// ---------------------------------------------------------------------------

Future<void> _t_e2eRunGroupChat() async {
  section('F E2E runGroupChat 静默契约（T04）');

  // —— F1：全静默：所有发言者返回【不参与】 → 绝不产生可见气泡 ——
  final f1 = await _runGroup(
    replies: ['【不参与】'],
    userText: '消防车泵的流量怎么算',
    strategy: 'leader_led',
  );
  final expertMsgs1 = f1.msgs.where((m) => m.isFromExpert).toList();
  t('F1.1', '静默场景：存在专家消息记录（step 已记）', true, expertMsgs1.isNotEmpty,
      note: 'count=${expertMsgs1.length}');
  t('F1.2', '静默场景：全部专家消息被置 cancelled', true,
      expertMsgs1.every((m) => m.status == MessageStatus.cancelled));
  t('F1.3', '静默场景：正文全部清空（UI 不渲染气泡）', true,
      expertMsgs1.every((m) => m.content.isEmpty));
  t('F1.4', '静默场景：无 accepted 输出 → run 状态 completed', RunStatus.completed, f1.runStatus);

  // —— F2：正常：返回正常文本 → 产生已完成气泡 ——
  final f2 = await _runGroup(
    replies: ['这是基于消防车泵流量的专业结论。'],
    userText: '消防车泵的流量怎么算',
    strategy: 'leader_led',
  );
  final expertMsgs2 = f2.msgs.where((m) => m.isFromExpert).toList();
  t('F2.1', '正常场景：有专家消息', true, expertMsgs2.isNotEmpty);
  t('F2.2', '正常场景：无空正文（未被误判为静默）', 0,
      expertMsgs2.where((m) => m.content.trim().isEmpty).length);
  t('F2.3', '正常场景：存在 completed 气泡', true,
      expertMsgs2.any((m) => m.status == MessageStatus.completed));

  // —— F3：精确判定不误杀：含哨兵但后续有实质发言 → 不得静默 ——
  final f3 = await _runGroup(
    replies: ['【不参与】，但我补充一点：泵流量需大于 60L/s。'],
    userText: '@李组 补充下',
    strategy: 'manual',
  );
  final expertMsgs3 = f3.msgs.where((m) => m.isFromExpert).toList();
  t('F3.1', '含哨兵+实质发言 → 不静默（保留正文）', true,
      expertMsgs3.any((m) => m.content.isNotEmpty),
      note: 'contents=${expertMsgs3.map((m) => m.content).toList()}');
  t('F3.2', '该消息状态非 cancelled', true,
      expertMsgs3.any((m) => m.status == MessageStatus.completed));

  // —— F4：容错：markdown 强调 + 空白包裹的纯哨兵 → 仍静默 ——
  final f4 = await _runGroup(
    replies: ['  **【不参与】**  '],
    userText: '@李组 说下',
    strategy: 'manual',
  );
  final expertMsgs4 = f4.msgs.where((m) => m.isFromExpert).toList();
  t('F4.1', 'markdown+空白包裹的纯哨兵 → 静默（正文清空）', true,
      expertMsgs4.isNotEmpty && expertMsgs4.every((m) => m.content.isEmpty));
  t('F4.2', '对应消息 cancelled', true,
      expertMsgs4.every((m) => m.status == MessageStatus.cancelled));
}

class _GroupRun {
  _GroupRun(this.msgs, this.runStatus);
  final List<Message> msgs;
  final RunStatus runStatus;
}

/// 真跑一次 runGroupChat（内存仓储 + 脚本化 LLM）。
Future<_GroupRun> _runGroup({
  required List<String> replies,
  required String userText,
  required String strategy,
}) async {
  final repos = inMemoryRepositories();
  final now = DateTime.now().millisecondsSinceEpoch;

  // Provider / Model / Credential / Secret → 让 _resolveFor 走通
  await repos.providers.upsertProvider(
      const ProviderProfile(id: 'pp_q6', providerId: 'deepseek', displayName: 'DeepSeek', baseUrl: 'https://x'));
  await repos.providers.upsertModel(ModelProfile.deepseekChat(providerProfileId: 'pp_q6'));
  await repos.credentials.upsert(CredentialProfile(
      id: 'cr_q6', providerProfileId: 'pp_q6', name: 'k', secretRef: 'ref6',
      createdAt: now, updatedAt: now));
  await repos.secrets.write('ref6', 'sk-test');
  await repos.settings.set(SettingKeys.defaultModelProfileId, 'mp_deepseek_chat');
  await repos.settings.set(SettingKeys.defaultCredentialProfileId, 'cr_q6');

  // 专家 + 标签
  for (final e in [
    (id: 'eL', name: '李组', tags: ['消防车']),
    (id: 'eM1', name: '张工', tags: ['消防车泵']),
    (id: 'eM2', name: '王律', tags: ['合同法']),
  ]) {
    await repos.experts.upsertExpert(Expert(
        id: e.id, name: e.name, systemPrompt: 'sp', source: ExpertSource.local,
        createdAt: now, updatedAt: now));
    await repos.experts.setTags(e.id, e.tags);
  }

  // 群 + 成员 + 配置
  await repos.conversations.upsertConversation(
      Conversation(id: 'c6', type: ConversationType.group, title: '测试群', createdAt: now, updatedAt: now));
  await repos.conversations.upsertMember(
      const ConversationMember(conversationId: 'c6', expertId: 'eL', role: MemberRole.leader, sortOrder: 0));
  await repos.conversations.upsertMember(
      const ConversationMember(conversationId: 'c6', expertId: 'eM1', sortOrder: 1));
  await repos.conversations.upsertMember(
      const ConversationMember(conversationId: 'c6', expertId: 'eM2', sortOrder: 2));
  await repos.conversations.upsertGroupConfig(
      GroupConfig(conversationId: 'c6', speakStrategy: strategy, maxSpeakersPerRound: 3));

  final experts = ExpertService(repos);
  final conversations = ConversationService(repos);
  final knowledge = KnowledgeService(
    repos,
    parsers: [PlainTextParser()],
    chunker: SimpleChunker(),
    vectorStore: InMemoryVectorStore(repos.knowledge),
    retriever: InMemoryRetriever(repos.knowledge),
  );
  final group = GroupService(
    repos,
    experts: experts,
    conversations: conversations,
    knowledge: knowledge,
    llmFactory: (_) => ScriptedLlmProvider(replies: replies),
  );

  // async* 惰性：必须消费（_drain）才会真正跑编排，否则 msgs/runs 全为空 → 假绿。
  await _drain(group.runGroupChat(
    conversationId: 'c6',
    userMessageId: 'um6',
    userText: userText,
  ));

  final msgs = await repos.messages.listMessages('c6');
  final runs = await repos.generations.listRuns('c6');
  return _GroupRun(msgs, runs.isEmpty ? RunStatus.failed : runs.last.status);
}

// ---------------------------------------------------------------------------

void _print() {
  stdout.writeln('\n${'=' * 62}');
  stdout.writeln('# QA 第 6 轮用例表');
  stdout.writeln('| ID | 用例 | 期望 | 实际 | 结论 |');
  stdout.writeln('|----|------|------|------|------|');
  for (final r in _res) {
    final e = r.expected.replaceAll('|', r'\|');
    final a = r.actual.replaceAll('|', r'\|');
    stdout.writeln('| ${r.id} | ${r.name} | $e | $a | ${r.pass ? 'PASS' : 'FAIL'} |');
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
