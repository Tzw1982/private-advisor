/// Secret 存储实现：API Key 明文只进 OS 凭据库，**永不落 SQLite / 日志**。
///
/// 对应 V1.3 §16 / §35 与契约 02 §3.1。
library;

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              mOptions: MacOsOptions(useDataProtectionKeyChain: true),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String ref, String secret) =>
      _storage.write(key: _key(ref), value: secret);

  @override
  Future<String?> read(String ref) => _storage.read(key: _key(ref));

  @override
  Future<void> delete(String ref) => _storage.delete(key: _key(ref));

  @override
  Future<bool> contains(String ref) async =>
      (await _storage.read(key: _key(ref))) != null;

  String _key(String ref) => 'private_advisor.$ref';
}
