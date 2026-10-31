import 'package:flutter/services.dart';

import 'api_service.dart';

/// 调用 Android 系统分享面板，不引入额外插件。
class ShareService {
  ShareService._();
  static final ShareService instance = ShareService._();

  static const MethodChannel _channel = MethodChannel('mtforum/share');

  String threadLink(String tid) =>
      '${ApiService.baseUrl}/thread-$tid-1-1.html';

  Future<bool> shareThread({required String title, required String tid}) {
    final link = threadLink(tid);
    final text = title.trim().isEmpty ? link : '${title.trim()}\n$link';
    return shareText(text, subject: title);
  }

  Future<bool> shareText(String text, {String? subject}) async {
    final value = text.trim();
    if (value.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('shareText', {
            'text': value,
            if (subject != null && subject.trim().isNotEmpty)
              'subject': subject.trim(),
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<String> copyThreadLink(String tid) async {
    final link = threadLink(tid);
    await Clipboard.setData(ClipboardData(text: link));
    return link;
  }
}
