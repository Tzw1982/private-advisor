/// 通用基础类型：统一错误模型（V1.3 §36）与 ID 生成。
///
/// 本文件是 `advisor_core` 的最底层，不依赖任何其他领域文件。
library;

// ---------------------------------------------------------------------------
// 统一错误模型
// ---------------------------------------------------------------------------

/// 应用统一错误基类。所有跨层异常都必须归一化为 [AppError] 的子类，
/// UI 层不得直接依赖底层 HTTP 错误码。
sealed class AppError implements Exception {
  const AppError(this.code, this.message, [this.cause]);

  /// 稳定错误码（用于日志与 UI 分支，不随文案变化）。
  final String code;

  /// 面向用户的可读信息。
  final String message;

  /// 原始异常，便于排查。
  final Object? cause;

  @override
  String toString() => '$runtimeType($code): $message';
}

/// 参数 / 状态校验失败。
class ValidationError extends AppError {
  const ValidationError(super.code, super.message, [super.cause]);
}

/// 本地存储失败（SQLite / 文件系统）。
class StorageError extends AppError {
  const StorageError(super.code, super.message, [super.cause]);
}

/// Provider（模型服务商）相关错误基类。
sealed class ProviderError extends AppError {
  const ProviderError(super.code, super.message, [super.cause]);
}

/// 鉴权失败：Key 无效 / 被吊销（HTTP 401 / 403）。
class AuthenticationError extends ProviderError {
  const AuthenticationError([String message = 'API Key 无效或已失效'])
      : super('provider.auth', message);
}

/// 限流（HTTP 429）。
class RateLimitError extends ProviderError {
  const RateLimitError([String message = '请求过于频繁，已被限流'])
      : super('provider.rate_limit', message);
}

/// 网络不可达 / 超时。
class NetworkError extends ProviderError {
  const NetworkError([String message = '网络不可达', Object? cause])
      : super('provider.network', message, cause);
}

/// 配额耗尽（余额不足等）。
class QuotaError extends ProviderError {
  const QuotaError([String message = '账户配额不足'])
      : super('provider.quota', message);
}

/// 服务端错误（5xx）。
class ProviderServerError extends ProviderError {
  const ProviderServerError([String message = '模型服务端错误'])
      : super('provider.server', message);
}

/// 模型档案未开启「支持视觉」而消息携带图片（第 9 轮 · 图片多模态门控）。
///
/// **明确报错，绝不静默丢图**：用户能在界面上看到失败原因，并按提示
/// 换用支持视觉的模型、或在「设置 → 模型」中为该模型开启「支持视觉」。
class VisionUnsupportedError extends ProviderError {
  const VisionUnsupportedError([String message = '当前模型不支持图片输入'])
      : super('provider.vision_unsupported', message);
}

/// 知识库相关错误（解析 / 索引 / 检索）。
class KnowledgeError extends AppError {
  const KnowledgeError(super.code, super.message, [super.cause]);
}

/// 专家包相关错误基类。
sealed class PackageError extends AppError {
  const PackageError(super.code, super.message, [super.cause]);
}

/// 签名校验失败。
class SignatureError extends PackageError {
  const SignatureError([String message = '包签名校验失败'])
      : super('package.signature', message);
}

/// 哈希不匹配。
class HashMismatchError extends PackageError {
  const HashMismatchError([String message = '包哈希校验失败'])
      : super('package.hash', message);
}

/// Schema 校验失败。
class SchemaError extends PackageError {
  const SchemaError([String message = '包结构不符合规范'])
      : super('package.schema', message);
}

/// 不安全包（可执行文件 / 路径穿越 / 能力越权）。
class UnsafePackageError extends PackageError {
  const UnsafePackageError([String message = '包含不安全内容，已拒绝安装'])
      : super('package.unsafe', message);
}

/// 生成过程错误。
class GenerationError extends AppError {
  const GenerationError(super.code, super.message, [super.cause]);
}

// ---------------------------------------------------------------------------
// ID 生成
// ---------------------------------------------------------------------------

/// 本地 ID 生成器。带前缀、时间序、随机后缀，单机内碰撞概率可忽略。
abstract final class Ids {
  static final _rand = _Xorshift64(DateTime.now().microsecondsSinceEpoch);
  static int _seq = 0;

  /// 生成形如 `e_m3k9x2_7f3a91` 的 ID。
  static String next(String prefix) {
    _seq = (_seq + 1) & 0xffff;
    final t = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final r = _rand.nextUint32().toRadixString(36).padLeft(7, '0');
    final s = _seq.toRadixString(36).padLeft(3, '0');
    return '${prefix}_${t}_$r$s';
  }
}

/// 轻量伪随机源（避免引入 dart:math 的全局 Random 被误用为安全随机）。
class _Xorshift64 {
  _Xorshift64(int seed) : _s = (seed == 0 ? 0x9E3779B97F4A7C15 : seed) & 0xFFFFFFFFFFFFFFFF;

  int _s;

  int nextUint32() {
    var x = _s;
    x ^= (x << 13) & 0xFFFFFFFFFFFFFFFF;
    x ^= x >> 7;
    x ^= (x << 17) & 0xFFFFFFFFFFFFFFFF;
    _s = x & 0xFFFFFFFFFFFFFFFF;
    return (_s >> 16) & 0xFFFFFFFF;
  }

  /// 返回 [0, max) 内的整数。
  int nextInt(int max) {
    if (max <= 0) return 0;
    return nextUint32() % max;
  }

  /// 返回 [0.0, 1.0) 的浮点数。
  double nextDouble() => nextUint32() / 4294967296.0;
}
