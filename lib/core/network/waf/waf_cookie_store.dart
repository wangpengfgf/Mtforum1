import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// WAF（Aliyun acw_sc__v2 等）Cookie 的持久化存储。
///
/// 这些 Cookie 与论坛登录态的 auth/saltkey 相互独立：验证成功后缓存，
/// 登录/退出时清空，验证失败时按需重新采集。
class WafCookieStore {
  static const String storageKey = 'forum_waf_cookies_v1';

  final SharedPreferences _prefs;

  WafCookieStore(this._prefs);

  static bool isWafCookieName(String name) {
    final lower = name.toLowerCase();
    if (const {
      'acw_sc__v2',
      'acw_sc_v2',
      'acw_tc',
      'cdn_sec_tc',
      'sec_tc',
      'aliyungf_tc',
      'ssxmod_itna',
      'ssxmod_itna2',
    }.contains(lower)) {
      return true;
    }
    return lower.startsWith('acw_') ||
        lower.startsWith('acwsc_') ||
        lower.startsWith('aliyungf_') ||
        lower.startsWith('ssxmod_') ||
        lower.startsWith('__cdn');
  }

  Future<Map<String, String>> load() async {
    final raw = _prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final result = <String, String>{};
      for (final entry in decoded.entries) {
        final name = entry.key.toString().trim();
        final value = entry.value?.toString().trim() ?? '';
        if (name.isNotEmpty && value.isNotEmpty) result[name] = value;
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  Future<void> save(Map<String, String> cookies) async {
    final wafOnly = <String, String>{};
    for (final entry in cookies.entries) {
      if (isWafCookieName(entry.key) && entry.value.isNotEmpty) {
        wafOnly[entry.key] = entry.value;
      }
    }
    if (wafOnly.isEmpty) return;
    await _prefs.setString(storageKey, jsonEncode(wafOnly));
  }

  Future<void> clear() async {
    await _prefs.remove(storageKey);
  }
}
