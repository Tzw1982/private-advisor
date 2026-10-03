/// OpenAI 兼容 Provider 适配（DeepSeek / OpenRouter / Ollama / 自定义）。
///
/// 对应 V1.3 §26 的 `LlmProvider` 端口，是 M0 Spike 的关键项：
/// **SSE 流式必须可停止 / 可取消**。
library;

import 'dart:async';
import 'dart:convert';

import 'package:advisor_core/advisor_core.dart';
import 'package:http/http.dart' as http;

/// 内置 Provider 预设。
class ProviderPreset {
  const ProviderPreset({
    required this.providerId,
    required this.displayName,
    required this.baseUrl,
    this.requiresApiKey = true,
    this.defaultModels = const [],
  });

  final String providerId;
  final String displayName;
  final String baseUrl;
  final bool requiresApiKey;
  final List<String> defaultModels;

  static const deepseek = ProviderPreset(
    providerId: 'deepseek',
    displayName: 'DeepSeek 官方直连',
    baseUrl: 'https://api.deepseek.com/v1',
    defaultModels: ['deepseek-chat', 'deepseek-reasoner'],
  );

  static const openrouter = ProviderPreset(
    providerId: 'openrouter',
    displayName: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
  );

  static const ollama = ProviderPreset(
    providerId: 'ollama',
    displayName: 'Ollama（本地）',
    baseUrl: 'http://127.0.0.1:11434/v1',
    requiresApiKey: false,
    defaultModels: ['qwen2.5:7b', 'llama3.1:8b'],
  );

  static const all = [deepseek, openrouter, ollama];
}

/// OpenAI 兼容 Provider 实现。
class OpenAiCompatibleProvider implements LlmProvider {
  OpenAiCompatibleProvider({
    required this.providerId,
    required this.baseUrl,
    required this.apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 120),
  }) : _client = client ?? http.Client();

  @override
  final String providerId;

  final String baseUrl;

  /// API Key 明文。**仅在此处短暂持有，绝不写日志 / 落库。**
  final String apiKey;

  final Duration timeout;
  final http.Client _client;

  Uri _uri(String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base$path');
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json; charset=utf-8',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      };

  @override
  Future<List<ModelDescriptor>> listModels() async {
    try {
      final res = await _client
          .get(_uri('/models'), headers: _headers)
          .timeout(timeout);
      if (res.statusCode != 200) {
        throw mapHttpStatus(res.statusCode, _safeBody(res.bodyBytes));
      }
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final data = (decoded is Map && decoded['data'] is List)
          ? decoded['data'] as List
          : const [];
      return data
          .whereType<Map<String, dynamic>>()
          .map((m) => ModelDescriptor(
                modelId: '${m['id']}',
                contextWindow: (m['context_length'] as num?)?.toInt(),
              ))
          .toList();
    } on AppError {
      rethrow;
    } catch (e) {
      throw mapError(e);
    }
  }

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    try {
      final res = await _client
          .post(
            _uri('/chat/completions'),
            headers: _headers,
            body: utf8.encode(jsonEncode(_buildBody(request, stream: false))),
          )
          .timeout(timeout);

      if (res.statusCode != 200) {
        throw mapHttpStatus(res.statusCode, _safeBody(res.bodyBytes));
      }
      final decoded =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final choices = decoded['choices'] as List?;
      final content = choices != null && choices.isNotEmpty
          ? '${(choices.first as Map)['message']?['content'] ?? ''}'
          : '';
      final usage = decoded['usage'] as Map?;
      return ChatResponse(
        content: content,
        promptTokens: (usage?['prompt_tokens'] as num?)?.toInt() ?? 0,
        completionTokens: (usage?['completion_tokens'] as num?)?.toInt() ?? 0,
      );
    } on AppError {
      rethrow;
    } catch (e) {
      throw mapError(e);
    }
  }

  /// SSE 流式请求。
  ///
  /// 取消语义：订阅方 `cancel()` → 底层 HTTP 连接被关闭，服务端停止生成。
  @override
  Stream<StreamEvent> stream(ChatRequest request) {
    final controller = StreamController<StreamEvent>();
    http.Client? localClient;
    StreamSubscription<String>? sub;
    var closed = false;

    Future<void> shutdown() async {
      if (closed) return;
      closed = true;
      await sub?.cancel();
      localClient?.close();
      if (!controller.isClosed) await controller.close();
    }

    controller.onListen = () async {
      try {
        // 每次流式请求用独立 client，便于精确取消
        localClient = http.Client();
        final req = http.Request('POST', _uri('/chat/completions'))
          ..headers.addAll(_headers)
          ..bodyBytes =
              utf8.encode(jsonEncode(_buildBody(request, stream: true)));

        final res = await localClient!.send(req).timeout(timeout);
        if (res.statusCode != 200) {
          final body = await res.stream.bytesToString();
          controller.add(StreamErrorEvent(
              mapHttpStatus(res.statusCode, _safeBodyText(body))));
          await shutdown();
          return;
        }

        var buffer = '';
        sub = res.stream.transform(utf8.decoder).listen(
          (chunk) {
            buffer += chunk;
            while (true) {
              final idx = buffer.indexOf('\n');
              if (idx < 0) break;
              final line = buffer.substring(0, idx).trim();
              buffer = buffer.substring(idx + 1);
              if (line.isEmpty) continue;
              if (!line.startsWith('data:')) continue;
              final payload = line.substring(5).trim();
              if (payload == '[DONE]') {
                controller.add(const StreamDone());
                shutdown();
                return;
              }
              final event = _parseChunk(payload);
              if (event != null) controller.add(event);
            }
          },
          onError: (Object e) {
            controller.add(StreamErrorEvent(mapError(e)));
            shutdown();
          },
          onDone: () {
            controller.add(const StreamDone());
            shutdown();
          },
          cancelOnError: true,
        );
      } catch (e) {
        controller.add(StreamErrorEvent(mapError(e)));
        await shutdown();
      }
    };

    controller.onCancel = shutdown;
    return controller.stream;
  }

  StreamEvent? _parseChunk(String payload) {
    try {
      final json = jsonDecode(payload);
      if (json is! Map) return null;

      // usage（DeepSeek 在 stream_options.include_usage 时于末尾返回）
      final usage = json['usage'];
      if (usage is Map) {
        return UsageEvent(
          (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
          (usage['completion_tokens'] as num?)?.toInt() ?? 0,
        );
      }

      final choices = json['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final delta = (choices.first as Map)['delta'];
      if (delta is! Map) return null;

      // DeepSeek reasoner 的思维链单独走 reasoning_content，不并入正文
      final content = delta['content'];
      if (content is String && content.isNotEmpty) return TokenDelta(content);
      return null;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _buildBody(ChatRequest request,
          {required bool stream}) =>
      {
        'model': request.model,
        'messages': request.messages
            // 第 8 轮多模态：有图片时 content 走 OpenAI content-parts（由 core 的
            // `openAiContentFor` 1:1 委托，见 `application/vision.dart`）；无图片时
            // 返回原字符串，**请求体逐字不变**（回归防护，verify_round8 §12⑤）。
            .map((m) => {'role': m.role.name, 'content': openAiContentFor(m)})
            .toList(),
        'stream': stream,
        if (stream) 'stream_options': {'include_usage': true},
        if (request.temperature != null) 'temperature': request.temperature,
        if (request.topP != null) 'top_p': request.topP,
        if (request.maxTokens != null) 'max_tokens': request.maxTokens,
        if (request.jsonMode) 'response_format': {'type': 'json_object'},
      };

  @override
  Future<ProviderHealth> healthCheck() async {
    final sw = Stopwatch()..start();
    try {
      await listModels();
      return ProviderHealth(
          health: Health.healthy, latencyMs: sw.elapsedMilliseconds);
    } on AppError catch (e) {
      return ProviderHealth(
        health: ExpertStatus.healthFromError(e),
        latencyMs: sw.elapsedMilliseconds,
        detail: e.message,
      );
    } catch (e) {
      return ProviderHealth(
        health: Health.providerError,
        latencyMs: sw.elapsedMilliseconds,
        detail: '$e',
      );
    }
  }

  @override
  AppError mapError(Object raw) {
    if (raw is AppError) return raw;
    if (raw is TimeoutException) return const NetworkError('请求超时');
    final s = raw.toString().toLowerCase();
    if (s.contains('socket') ||
        s.contains('connection') ||
        s.contains('network')) {
      return NetworkError('网络不可达', raw);
    }
    return ProviderServerError('$raw');
  }

  /// 从响应体里提取可读错误信息，**并确保不泄露任何密钥**。
  String _safeBody(List<int> bytes) {
    try {
      return _safeBodyText(utf8.decode(bytes));
    } catch (_) {
      return '';
    }
  }

  String _safeBodyText(String body) {
    var s = body.length > 300 ? '${body.substring(0, 300)}…' : body;
    // 兜底脱敏：任何疑似 Key 的串都替换掉
    s = s.replaceAll(RegExp(r'sk-[A-Za-z0-9_\-]{8,}'), 'sk-***');
    return s;
  }

  void dispose() => _client.close();
}
