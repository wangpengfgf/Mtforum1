import '../models/models.dart';

/// 将论坛的平铺楼层整理成可渲染的评论串。
///
/// MT 移动版不提供结构化父 PID，因此优先按“被引用正文”匹配父楼层，
/// 再用引用时间与用户名作为辅助信号；无法唯一匹配时保持独立。
class CommentThreadService {
  const CommentThreadService();

  String? resolveParentPid(Post post, List<Post> source) {
    final postIndex = source.indexWhere((item) => item.pid == post.pid);
    if (postIndex <= 0) return null;

    final explicitPid = post.repquotePid?.trim() ?? '';
    final explicitIndex = explicitPid.isEmpty
        ? -1
        : source.indexWhere((item) => item.pid == explicitPid);
    if (explicitPid.isNotEmpty &&
        explicitPid != post.pid &&
        explicitIndex >= 0 &&
        explicitIndex < postIndex) {
      return explicitPid;
    }

    final quoteKey = _textKey(post.replyQuoteText);
    final replyName = (post.replyToName ?? '').trim().toLowerCase();
    final timeKey = _timeKey(post.replyToTime);
    if (quoteKey.isEmpty && replyName.isEmpty && timeKey.isEmpty) {
      return null;
    }

    final scored = <({Post post, int score})>[];

    for (var index = 0; index < postIndex; index++) {
      final candidate = source[index];
      final ownKey = _ownTextKey(candidate);

      var score = 0;
      // 被引用正文是最可靠的父楼层线索：移动版模板的“回复 用户名”
      // 经常被服务端改写成楼主昵称（例如所有引用都显示 Cynnie），
      // 因此不能再要求用户名一致，否则引用同一楼层的回复会被拆散。
      if (quoteKey.isNotEmpty && ownKey.isNotEmpty) {
        if (ownKey == quoteKey) {
          score += 300;
        } else if (quoteKey.length >= 2 && ownKey.contains(quoteKey)) {
          score += 200;
        } else if (ownKey.length >= 2 && quoteKey.contains(ownKey)) {
          score += 120;
        }
      }
      final candidateTimeKey = _timeKey(candidate.postTime);
      if (timeKey.isNotEmpty && candidateTimeKey == timeKey) {
        score += 100;
      }
      final name = (candidate.authorName ?? '').trim().toLowerCase();
      if (replyName.isNotEmpty && name == replyName) {
        score += 40;
      }

      if (score > 0) scored.add((post: candidate, score: score));
    }

    if (scored.isEmpty) return null;
    final bestScore = scored.map((item) => item.score).reduce(
          (value, next) => value > next ? value : next,
        );
    final best = scored
        .where((item) => item.score == bestScore)
        .toList(growable: false);
    return best.length == 1 ? best.single.post.pid : null;
  }

  String _ownTextKey(Post post) {
    final values = <String>[];

    void collect(PostContent content) {
      if (content.type == PostContentType.quote ||
          content.type == PostContentType.richQuote) {
        return;
      }
      if (content.text.trim().isNotEmpty) values.add(content.text);
      for (final child in content.children) {
        collect(child);
      }
    }

    for (final content in post.richContent) {
      collect(content);
    }
    final ownText = values.join(' ').trim();
    return _textKey(ownText.isEmpty ? post.content : ownText);
  }

  String _textKey(String? raw) {
    return (raw ?? '')
        .toLowerCase()
        .replaceAll(
          RegExp(r'''[\s，。！？、：；,.!?;:'"“”‘’（）()\[\]【】<>《》]+'''),
          '',
        );
  }

  String _timeKey(String? raw) {
    final text = (raw ?? '').trim();
    final date = RegExp(
      r'(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})(?:日)?\s+(\d{1,2}):(\d{1,2})',
    ).firstMatch(text);
    if (date != null) {
      return [
        date.group(1),
        int.parse(date.group(2)!).toString(),
        int.parse(date.group(3)!).toString(),
        int.parse(date.group(4)!).toString(),
        int.parse(date.group(5)!).toString(),
      ].join('-');
    }
    return text.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  }
}
