import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 搜索页最近使用过的关键词。
class SearchHistoryService extends ChangeNotifier {
  SearchHistoryService._();
  static final SearchHistoryService instance = SearchHistoryService._();

  static const String storageKey = 'search_history_v1';
  static const int maxItems = 10;

  List<String> _items = const [];
  bool _loaded = false;

  List<String> get items => List<String>.unmodifiable(_items);

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _items = _normalize(prefs.getStringList(storageKey) ?? const []);
    _loaded = true;
    notifyListeners();
  }

  Future<void> add(String keyword) async {
    final value = keyword.trim();
    if (value.isEmpty) return;
    _items = _normalize(<String>[value, ..._items]);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(storageKey, _items);
  }

  Future<void> remove(String keyword) async {
    _items = _items.where((item) => item != keyword).toList(growable: false);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(storageKey, _items);
  }

  Future<void> clear() async {
    _items = const [];
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
  }

  List<String> _normalize(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final item = value.trim();
      if (item.isEmpty) continue;
      final key = item.toLowerCase();
      if (seen.add(key)) result.add(item);
      if (result.length >= maxItems) break;
    }
    return result;
  }
}
