/// 识别论坛返回的 WAF 人机验证/拦截页。
///
/// 只根据响应内容做保守判断，避免把正常的小页面误判为验证页。
class InterstitialDetector {
  const InterstitialDetector();

  static final RegExp _arg1Pattern = RegExp(
    r"""var\s+arg1\s*=\s*['"]([0-9A-Fa-f]{8,128})['"]""",
    caseSensitive: false,
  );

  static final RegExp _forumSkeleton = RegExp(
    r"""discuz|formhash|comiis|id\s*=\s*['"]?(?:ct|hd|ft|postlist|thread_subject)""",
    caseSensitive: false,
  );

  bool looksLikeChallenge({
    required String body,
    required String contentType,
    required int statusCode,
  }) {
    final type = contentType.toLowerCase();
    final isHtml = type.contains('text/html') || type.contains('application/xhtml');
    if (!isHtml) return false;

    final lower = body.toLowerCase();
    if (statusCode == 403 || statusCode == 503) {
      return lower.contains('<html') || lower.contains('<body');
    }
    if (body.length > 64 * 1024) return false;
    if (!lower.contains('<html')) return false;
    if (_arg1Pattern.hasMatch(body) ||
        lower.contains('acw_sc__v2') ||
        lower.contains('acw_sc_v2')) {
      return true;
    }
    if (!lower.contains('<script') || _forumSkeleton.hasMatch(body)) {
      return false;
    }

    // 极短的脚本页，且包含典型的 Cookie/跳转写入逻辑：WAF 挑战页。
    final scriptLike = lower.contains('document.cookie') ||
        lower.contains('window.location') ||
        lower.contains('settimeout') ||
        lower.contains('arg1');
    if (!scriptLike) return false;

    final visible = body
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return visible.length < 256;
  }

  bool looksLikeInterstitialPage(String body, String contentType) {
    return looksLikeChallenge(
      body: body,
      contentType: contentType,
      statusCode: 200,
    );
  }
}
