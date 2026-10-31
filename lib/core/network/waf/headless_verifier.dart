import 'dart:async';

import 'package:flutter/services.dart';

class WafVerificationException implements Exception {
  final String message;
  const WafVerificationException(this.message);

  @override
  String toString() => message;
}

/// 通过 Android 侧不可见 WebView 完成站点人机验证。
///
/// 原生侧只负责加载页面并返回 Cookie；验证判定、Cookie 合并与重试由 Dart
/// 网络层负责，避免把论坛登录态带到浏览器的可见页面。
class HeadlessVerifier {
  const HeadlessVerifier();

  static const MethodChannel _channel =
      MethodChannel('com.wangpengfgf.mtforum/headless_verification');

  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<Map<String, String>> verify({
    required String url,
    required String userAgent,
    required Map<String, String> cookies,
    required List<String> staleCookieNames,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!await isAvailable()) {
      throw const WafVerificationException('当前平台不支持后台验证，跳过');
    }

    final started = await _channel.invokeMapMethod<String, dynamic>('start', {
      'url': url,
      'userAgent': userAgent,
      'cookies': cookies,
      'staleCookieNames': staleCookieNames,
    });
    final id = started?['id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      throw const WafVerificationException('启动不可见 WebView 失败');
    }

    final deadline = DateTime.now().add(timeout);
    try {
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final state = await _channel.invokeMapMethod<String, dynamic>('cookies', {
          'id': id,
        });
        final rawCookie = state?['cookie']?.toString() ?? '';
        final loadCount = _asInt(state?['loadCount']);
        final parsed = parseCookieHeader(rawCookie);
        if (_hasWafCookie(parsed)) {
          return parsed;
        }
        // 页面已经完成两次加载且返回了非空 Cookie，说明验证页已离开。
        if (loadCount >= 2 && parsed.isNotEmpty) {
          return parsed;
        }
      }
      throw const WafVerificationException('验证超时，未拿到论坛页面');
    } finally {
      try {
        await _channel.invokeMethod<void>('dispose', {'id': id});
      } catch (_) {
        // 清理失败不影响主流程。
      }
    }
  }

  static bool _hasWafCookie(Map<String, String> cookies) {
    for (final name in cookies.keys) {
      if (name.toLowerCase() == 'acw_sc__v2' ||
          name.toLowerCase() == 'acw_sc_v2') {
        return true;
      }
    }
    return false;
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  static Map<String, String> parseCookieHeader(String raw) {
    final result = <String, String>{};
    for (final item in raw.split(';')) {
      final separator = item.indexOf('=');
      if (separator < 1) continue;
      final name = item.substring(0, separator).trim();
      final value = item.substring(separator + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) result[name] = value;
    }
    return result;
  }
}
