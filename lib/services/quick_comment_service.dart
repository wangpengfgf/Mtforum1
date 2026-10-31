import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 帖子评论区上方的常用短语。点击后直接发送一条评论。
class QuickCommentService extends ChangeNotifier {
  QuickCommentService._();
  static final QuickCommentService instance = QuickCommentService._();

  static const String enabledKey = 'quick_comment_enabled';
  static const String itemsKey = 'quick_comment_items';
  static const int maxItems = 8;

  static const List<String> defaultItems = <String>[
    '感谢分享',
    '感谢楼主',
    '支持一下',
    '学习了',
    '前排',
    '好帖',
    '收藏了',
    '谢谢',
  ];

  bool _enabled = true;
  List<String> _items = List<String>.from(defaultItems);
  bool _loaded = false;

  bool get enabled => _enabled;
  List<String> get items => List<String>.unmodifiable(_items);

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(enabledKey) ?? true;
    final stored = prefs.getStringList(itemsKey);
    _items = _normalize(stored == null || stored.isEmpty ? defaultItems : stored);
    _loaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, value);
  }

  Future<void> setItemsFromText(String value) async {
    _items = _normalize(value.split(RegExp(r'[\n\r]+')));
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(itemsKey, _items);
  }

  Future<void> resetDefaults() async {
    _items = List<String>.from(defaultItems);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(itemsKey, _items);
  }

  List<String> _normalize(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final item = value.trim();
      if (item.isEmpty) continue;
      final key = item.toLowerCase();
      if (seen.add(key)) result.add(item.length > 50 ? item.substring(0, 50) : item);
      if (result.length >= maxItems) break;
    }
    return result.isEmpty ? List<String>.from(defaultItems) : result;
  }
}
