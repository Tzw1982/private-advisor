/// 内置模型同步验证（走查反馈：视觉开关重启失效 + reasoner 上下文纠正）。
///
/// 运行：`cd advisor_core && dart run tool/verify_builtin_model_sync.dart`
///
/// `ProviderService.registerBuiltins()` 对内置模型档案的两类字段取舍：
/// - **模板权威字段**（`modelId` / `contextWindow` / `supportsStreaming`
///   / `supportsJson`）→ 每次启动覆盖，存量过期值可自纠正；
/// - **用户覆盖字段**（`supportsVision` / `supportsTools`）→ 保留用户值。
///
/// 覆盖：
/// a) 存量 `contextWindow=65536` 的 reasoner 行 → 启动后纠正为 1M（chat 同理）；
/// b) 用户开启 `supportsVision`/`supportsTools` → 启动后仍为 true（不被重置）；
/// c) 首次安装（行不存在）→ 两个内置模型按模板落库；
/// d) 幂等：连跑两次 registerBuiltins，纠正值与用户值都稳定。
library;

import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:advisor_core/testing/in_memory.dart';

// ---------------------------------------------------------------------------
// 迷你断言框架（与 advisor_core/tool 下既有 verify_*.dart 同款）
// ---------------------------------------------------------------------------

int _passed = 0;
int _failed = 0;
final List<String> _failures = [];
String _current = '';

void section(String name) {
  _current = name;
  stdout.writeln('\n── $name ─────────────────────────────');
}

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  ✓ $name');
  } else {
    _failed++;
    final msg = '[$_current] $name${detail == null ? '' : '  → $detail'}';
    _failures.add(msg);
    stdout.writeln('  ✗ $name${detail == null ? '' : '  → $detail'}');
  }
}

void checkEq(String name, Object? actual, Object? expected) {
  check(name, actual == expected, 'actual=$actual expected=$expected');
}

// ---------------------------------------------------------------------------
// 测试环境
// ---------------------------------------------------------------------------

class _Env {
  _Env() {
    repos = inMemoryRepositories();
    providers = ProviderService(repos);
  }

  late final Repositories repos;
  late final ProviderService providers;

  Future<ModelProfile?> model(String id) => repos.providers.getModel(id);
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 内置模型同步验证（advisor_core / ProviderService.registerBuiltins）');
  stdout.writeln('=' * 60);

  await _verifyFirstInstall(); // c
  await _verifyStaleContextCorrected(); // a
  await _verifyUserTogglesPreserved(); // b
  await _verifyIdempotent(); // d

  stdout.writeln('\n${'=' * 60}');
  stdout.writeln('结果：通过 $_passed ／ 失败 $_failed');
  if (_failures.isNotEmpty) {
    stdout.writeln('\n失败明细：');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
    exitCode = 1;
  } else {
    stdout.writeln('全部通过 ✅');
  }
}

// ---------------------------------------------------------------------------
// c) 首次安装：按模板落库
// ---------------------------------------------------------------------------

Future<void> _verifyFirstInstall() async {
  section('c) 首次安装（行不存在）→ 两个内置模型按模板落库');

  final env = _Env();
  await env.providers.registerBuiltins();

  final chat = await env.model('mp_deepseek_chat');
  final reasoner = await env.model('mp_deepseek_reasoner');
  check('chat 行已落库', chat != null);
  check('reasoner 行已落库', reasoner != null);
  checkEq('chat.modelId', chat?.modelId, 'deepseek-chat');
  checkEq('reasoner.modelId', reasoner?.modelId, 'deepseek-reasoner');
  checkEq('chat.contextWindow = 1M', chat?.contextWindow, 1000000);
  checkEq('reasoner.contextWindow = 1M', reasoner?.contextWindow, 1000000);
  checkEq('chat.providerProfileId', chat?.providerProfileId, 'pp_deepseek');
  checkEq('reasoner.providerProfileId', reasoner?.providerProfileId, 'pp_deepseek');
  checkEq('chat.supportsStreaming', chat?.supportsStreaming, true);
  checkEq('chat.supportsJson', chat?.supportsJson, true);
  checkEq('chat.supportsVision 默认 false', chat?.supportsVision, false);
  checkEq('reasoner.supportsVision 默认 false', reasoner?.supportsVision, false);
  checkEq('model 总数 = 2', (await env.repos.providers.listModels()).length, 2);
  checkEq('默认模型设置键', await env.providers.defaultModelProfileId,
      'mp_deepseek_chat');
}

// ---------------------------------------------------------------------------
// a) 存量过期 contextWindow 纠正
// ---------------------------------------------------------------------------

Future<void> _verifyStaleContextCorrected() async {
  section('a) 存量 65536 → 启动后纠正为 1M（模板权威字段覆盖）');

  final env = _Env();
  // 预置两行"老库"：reasoner=65536（真实故障值）、chat=32768（同类型过期值）。
  await env.repos.providers.upsertModel(ModelProfile(
    id: 'mp_deepseek_chat',
    providerProfileId: 'pp_deepseek',
    modelId: 'deepseek-chat',
    contextWindow: 32768,
    supportsStreaming: true,
    supportsJson: true,
  ));
  await env.repos.providers.upsertModel(ModelProfile(
    id: 'mp_deepseek_reasoner',
    providerProfileId: 'pp_deepseek',
    modelId: 'deepseek-reasoner',
    contextWindow: 65536,
    supportsStreaming: true,
  ));
  checkEq('前置：存量 reasoner 确为 65536',
      (await env.model('mp_deepseek_reasoner'))?.contextWindow, 65536);

  await env.providers.registerBuiltins();

  checkEq('存量 reasoner 已纠正为 1M',
      (await env.model('mp_deepseek_reasoner'))?.contextWindow, 1000000);
  checkEq('存量 chat 已纠正为 1M',
      (await env.model('mp_deepseek_chat'))?.contextWindow, 1000000);
  check('modelId 亦属模板权威字段（存量被改也能纠正）',
      (await env.model('mp_deepseek_reasoner'))?.modelId == 'deepseek-reasoner');

  // 模板权威字段被存量值污染时同样纠正（supportsStreaming / supportsJson）。
  await env.repos.providers.upsertModel(ModelProfile(
    id: 'mp_deepseek_chat',
    providerProfileId: 'pp_deepseek',
    modelId: 'deepseek-chat',
    contextWindow: 1000000,
    supportsStreaming: false,
    supportsJson: false,
  ));
  await env.providers.registerBuiltins();
  checkEq('存量 supportsStreaming=false 被纠正为 true',
      (await env.model('mp_deepseek_chat'))?.supportsStreaming, true);
  checkEq('存量 supportsJson=false 被纠正为 true',
      (await env.model('mp_deepseek_chat'))?.supportsJson, true);
}

// ---------------------------------------------------------------------------
// b) 用户覆盖字段保留
// ---------------------------------------------------------------------------

Future<void> _verifyUserTogglesPreserved() async {
  section('b) 用户开 supportsVision / supportsTools → 启动后保留（不被重置）');

  final env = _Env();
  await env.providers.registerBuiltins();

  // 模拟用户在「设置 → 模型视觉能力」里打开内置模型的视觉开关。
  for (final id in ['mp_deepseek_chat', 'mp_deepseek_reasoner']) {
    final m = (await env.model(id))!;
    await env.repos.providers
        .upsertModel(m.copyWith(supportsVision: true, supportsTools: true));
  }
  checkEq('前置：chat 视觉已开',
      (await env.model('mp_deepseek_chat'))?.supportsVision, true);
  checkEq('前置：reasoner 视觉已开',
      (await env.model('mp_deepseek_reasoner'))?.supportsVision, true);

  // —— 关键：再启动一次（用户实机"重启后失效"的复现路径）——
  await env.providers.registerBuiltins();

  checkEq('重启后 chat.supportsVision 仍为 true',
      (await env.model('mp_deepseek_chat'))?.supportsVision, true);
  checkEq('重启后 reasoner.supportsVision 仍为 true',
      (await env.model('mp_deepseek_reasoner'))?.supportsVision, true);
  checkEq('重启后 chat.supportsTools 仍为 true',
      (await env.model('mp_deepseek_chat'))?.supportsTools, true);
  checkEq('重启后 reasoner.supportsTools 仍为 true',
      (await env.model('mp_deepseek_reasoner'))?.supportsTools, true);

  // 视觉开关关闭同样要被保留（用户显式关 = 也不得反转）。
  final chat = (await env.model('mp_deepseek_chat'))!;
  await env.repos.providers.upsertModel(chat.copyWith(supportsVision: false));
  await env.providers.registerBuiltins();
  checkEq('显式关闭的视觉开关同样保留',
      (await env.model('mp_deepseek_chat'))?.supportsVision, false);
}

// ---------------------------------------------------------------------------
// d) 幂等（纠正值与用户值都稳定）
// ---------------------------------------------------------------------------

Future<void> _verifyIdempotent() async {
  section('d) 幂等：连跑两次 registerBuiltins，纠正值与用户值都稳定');

  final env = _Env();
  // 老库 + 用户已开视觉：两件事同时成立的复合场景。
  await env.repos.providers.upsertModel(ModelProfile(
    id: 'mp_deepseek_reasoner',
    providerProfileId: 'pp_deepseek',
    modelId: 'deepseek-reasoner',
    contextWindow: 65536,
    supportsStreaming: true,
    supportsVision: true,
    supportsTools: true,
  ));

  await env.providers.registerBuiltins();
  final first = (await env.model('mp_deepseek_reasoner'))!;
  checkEq('第一次启动：contextWindow 已纠正', first.contextWindow, 1000000);
  checkEq('第一次启动：视觉开关保留', first.supportsVision, true);

  await env.providers.registerBuiltins();
  final second = (await env.model('mp_deepseek_reasoner'))!;
  checkEq('第二次启动：contextWindow 仍为 1M（稳定）', second.contextWindow, 1000000);
  checkEq('第二次启动：视觉开关仍为 true（稳定）', second.supportsVision, true);
  checkEq('第二次启动：supportsTools 仍为 true（稳定）', second.supportsTools, true);
  checkEq('未产生多余模型行', (await env.repos.providers.listModels()).length, 2);
  checkEq('provider 行未增殖',
      (await env.repos.providers.listProviders()).length, 2);
}
