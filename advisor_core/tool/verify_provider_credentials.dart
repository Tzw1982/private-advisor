/// 多 provider 凭据验证（用户走查反馈 #15-B · core 增量，纯 Dart，可 `dart run`）。
///
/// 运行：`cd advisor_core && dart run tool/verify_provider_credentials.dart`
///
/// 覆盖 `CredentialService.saveForProvider` / `getForProvider`：
/// 1. 保存后凭据行 + secret 存储双落，`getForProvider` 可读回；
///    `secretRef` 口径为 `pa.secret.cred_<providerProfileId>`。
/// 2. 再次保存同一 provider → 同 id 覆盖（createdAt 不变、updatedAt 前移），
///    secret 内容为新值。
/// 3. 空 API Key 抛 `cred.empty`（与 `saveDefault` 同款）。
/// 4. 与默认单例 `cred_default` **并存**互不干扰（saveDefault 零行为回归）。
/// 5. `getForProvider` 对未登记 provider 返回 null。
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

/// 断言抛出指定错误码。
Future<void> checkThrowsCode(
    String name, Future<void> Function() body, String code) async {
  try {
    await body();
    check(name, false, '未抛出异常（期望 code=$code）');
  } catch (e) {
    if (e is AppError && e.code == code) {
      check(name, true);
    } else {
      check(name, false, '抛出了 ${e.runtimeType}(${e is AppError ? e.code : '?'})，期望 $code');
    }
  }
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('私人顾问团 · 多 provider 凭据验证（advisor_core / CredentialService）');
  stdout.writeln('=' * 60);

  await _verifySaveForProvider();
  await _verifyCoexistWithDefault();

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
// 1. saveForProvider / getForProvider
// ---------------------------------------------------------------------------

Future<void> _verifySaveForProvider() async {
  section('saveForProvider（落库 / 覆盖 / 空 key 拦截 / 未知 provider）');

  final repos = inMemoryRepositories();
  final credentials = CredentialService(repos);

  // —— 未登记 → null ——
  check('未登记 provider：getForProvider 返回 null',
      (await credentials.getForProvider('pp_custom_x')) == null);

  // —— 保存 ——
  final saved = await credentials.saveForProvider(
    providerProfileId: 'pp_custom_x',
    apiKey: 'sk-abc123',
    name: '凭据（我的中转）',
  );
  checkEq('凭据 id = cred_<providerProfileId>', saved.id, 'cred_pp_custom_x');
  checkEq('providerProfileId 透传', saved.providerProfileId, 'pp_custom_x');
  checkEq('name 透传', saved.name, '凭据（我的中转）');
  checkEq('secretRef 口径', saved.secretRef,
      CredentialProfile.secretRefFor('cred_pp_custom_x'));
  checkEq('secret 存储已写入',
      await repos.secrets.read(saved.secretRef), 'sk-abc123');
  checkEq('凭据行已写入',
      (await repos.credentials.get('cred_pp_custom_x'))?.id,
      'cred_pp_custom_x');
  checkEq('getForProvider 可读回',
      (await credentials.getForProvider('pp_custom_x'))?.id,
      'cred_pp_custom_x');
  checkEq('resolveSecret 读到明文',
      await credentials.resolveSecret(saved.id), 'sk-abc123');

  // —— 空 key 拦截（与 saveDefault 同款） ——
  await checkThrowsCode(
      '空 key 抛 cred.empty',
      () => credentials.saveForProvider(
          providerProfileId: 'pp_custom_x', apiKey: '  '),
      'cred.empty');

  // —— 覆盖保存：同 id，secret 换新值，createdAt 不变 ——
  final before = (await credentials.getForProvider('pp_custom_x'))!;
  await Future<void>.delayed(const Duration(milliseconds: 2));
  final updated = await credentials.saveForProvider(
    providerProfileId: 'pp_custom_x',
    apiKey: 'sk-new999',
  );
  checkEq('覆盖保存 id 不变', updated.id, before.id);
  checkEq('覆盖保存 createdAt 不变', updated.createdAt, before.createdAt);
  check('覆盖保存 updatedAt 前移', updated.updatedAt >= before.updatedAt,
      'old=${before.updatedAt} new=${updated.updatedAt}');
  checkEq('覆盖保存 secretRef 不变', updated.secretRef, before.secretRef);
  checkEq('secret 内容已换新值',
      await repos.secrets.read(updated.secretRef), 'sk-new999');
  checkEq('name 缺省时有兜底文案', updated.name.isNotEmpty, true);

  // —— 未知 provider 仍为 null ——
  check('另一个 provider 仍未登记',
      (await credentials.getForProvider('pp_other')) == null);
}

// ---------------------------------------------------------------------------
// 2. 与默认单例并存（saveDefault 零行为回归）
// ---------------------------------------------------------------------------

Future<void> _verifyCoexistWithDefault() async {
  section('与 cred_default 并存（saveDefault 零行为回归）');

  final repos = inMemoryRepositories();
  final credentials = CredentialService(repos);

  final def = await credentials.saveDefault(
    apiKey: 'sk-default-key',
    providerProfileId: ProviderService.deepseekProviderId,
  );
  checkEq('默认凭据 id 仍为 cred_default',
      def.id, CredentialService.defaultCredentialId);
  checkEq('默认凭据 secretRef 口径',
      def.secretRef, CredentialProfile.secretRefFor('cred_default'));
  checkEq('hasDefault 为 true', await credentials.hasDefault(), true);

  // 同一 provider 再存 per-provider 凭据 → 两条并存，默认路径不受影响。
  await credentials.saveForProvider(
    providerProfileId: ProviderService.deepseekProviderId,
    apiKey: 'sk-per-provider',
  );
  checkEq('默认凭据行仍在',
      (await repos.credentials.get(CredentialService.defaultCredentialId))?.id,
      CredentialService.defaultCredentialId);
  checkEq('默认凭据 secret 未被覆盖',
      await repos.secrets.read(def.secretRef), 'sk-default-key');
  checkEq('per-provider 凭据独立存在',
      (await credentials.getForProvider(ProviderService.deepseekProviderId))
          ?.id,
      'cred_pp_deepseek');
  checkEq('per-provider secret 独立',
      await repos.secrets
          .read(CredentialProfile.secretRefFor('cred_pp_deepseek')),
      'sk-per-provider');
  checkEq('defaultCredentialProfileId 设置键未被动过',
      await credentials.defaultCredentialProfileId, 'cred_default');
  checkEq('凭据总数 = 2（并存）', (await credentials.list()).length, 2);
}
