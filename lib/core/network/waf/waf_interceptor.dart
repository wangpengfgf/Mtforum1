import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';

import 'headless_verifier.dart';
import 'interstitial_detector.dart';
import 'waf_cookie_store.dart';

/// 在论坛请求被 WAF 拦截时，用不可见 WebView 完成验证并把新 Cookie 写回
/// Dart 侧 CookieJar，然后对安全的只读请求自动重试一次。
class WafInterceptor extends Interceptor {
  static const String retriedFlag = 'mtforum_waf_retried';

  final Dio dio;
  final CookieJar cookieJar;
  final HeadlessVerifier verifier;
  final WafCookieStore cookieStore;
  final InterstitialDetector detector;
  final Future<bool> Function() autoVerifyEnabled;
  final String userAgent;

  const WafInterceptor({
    required this.dio,
    required this.cookieJar,
    required this.verifier,
    required this.cookieStore,
    required this.detector,
    required this.autoVerifyEnabled,
    required this.userAgent,
  });

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    unawaited(_handleResponse(response, handler));
  }

  Future<void> _handleResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final options = response.requestOptions;
    final body = response.data;
    if (options.extra[retriedFlag] == true || body is! String) {
      handler.next(response);
      return;
    }

    final contentType =
        response.headers.value(Headers.contentTypeHeader) ?? '';
    if (!detector.looksLikeChallenge(
      body: body,
      contentType: contentType,
      statusCode: response.statusCode ?? 0,
    )) {
      handler.next(response);
      return;
    }

    if (!await autoVerifyEnabled()) {
      handler.reject(
        DioException(
          requestOptions: options,
          response: response,
          type: DioExceptionType.badResponse,
          error: const WafVerificationException(
            '站点要求人机验证，请在设置中开启自动验证或稍后重试',
          ),
        ),
      );
      return;
    }

    final uri = options.uri;
    final current = await _cookieValues(uri);
    final stale = current.keys
        .where(WafCookieStore.isWafCookieName)
        .toList(growable: false);

    try {
      final verified = await verifier.verify(
        url: uri.toString(),
        userAgent: userAgent,
        cookies: current,
        staleCookieNames: stale,
      );
      await _saveCookies(uri, verified);
      await cookieStore.save(verified);
    } catch (error) {
      handler.reject(
        DioException(
          requestOptions: options,
          response: response,
          type: DioExceptionType.badResponse,
          error: error,
        ),
      );
      return;
    }

    final method = options.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      handler.reject(
        DioException(
          requestOptions: options,
          response: response,
          type: DioExceptionType.badResponse,
          error: const WafVerificationException('人机验证已完成，请重新提交'),
        ),
      );
      return;
    }

    options.extra[retriedFlag] = true;
    try {
      final retried = await dio.fetch<dynamic>(options);
      handler.resolve(retried);
    } on DioException catch (error) {
      handler.reject(error);
    } catch (error) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: error,
          type: DioExceptionType.unknown,
        ),
      );
    }
  }

  Future<Map<String, String>> _cookieValues(Uri uri) async {
    final cookies = await cookieJar.loadForRequest(uri);
    return {for (final cookie in cookies) cookie.name: cookie.value};
  }

  Future<void> _saveCookies(Uri uri, Map<String, String> values) async {
    if (values.isEmpty) return;
    final cookies = <Cookie>[];
    for (final entry in values.entries) {
      if (entry.key.isEmpty || entry.value.isEmpty) continue;
      cookies.add(
        Cookie(entry.key, entry.value)
          ..path = '/'
          ..secure = true,
      );
    }
    if (cookies.isNotEmpty) {
      await cookieJar.saveFromResponse(uri, cookies);
    }
  }
}
