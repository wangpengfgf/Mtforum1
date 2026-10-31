import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'api_service.dart';

class SavedAccount {
  final String id;
  final String username;
  final String? uid;
  final String? avatarUrl;
  final String auth;
  final String saltkey;
  final int updatedAt;

  const SavedAccount({
    required this.id,
    required this.username,
    required this.auth,
    required this.saltkey,
    this.uid,
    this.avatarUrl,
    this.updatedAt = 0,
  });

  SavedAccount copyWith({
    String? id,
    String? username,
    String? uid,
    String? avatarUrl,
    String? auth,
    String? saltkey,
    int? updatedAt,
  }) {
    return SavedAccount(
      id: id ?? this.id,
      username: username ?? this.username,
      uid: uid ?? this.uid,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      auth: auth ?? this.auth,
      saltkey: saltkey ?? this.saltkey,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'uid': uid,
        'avatar': avatarUrl,
        'auth': auth,
        'saltkey': saltkey,
        'updatedAt': updatedAt,
      };

  static SavedAccount? fromJson(Map<String, dynamic> json) {
    final id = '${json['id'] ?? ''}'.trim();
    final username = '${json['username'] ?? ''}'.trim();
    final auth = '${json['auth'] ?? ''}'.trim();
    final saltkey = '${json['saltkey'] ?? ''}'.trim();
    if (id.isEmpty || username.isEmpty || auth.isEmpty || saltkey.isEmpty) {
      return null;
    }
    return SavedAccount(
      id: id,
      username: username,
      uid: '${json['uid'] ?? ''}'.trim().isEmpty
          ? null
          : '${json['uid']}'.trim(),
      avatarUrl: '${json['avatar'] ?? ''}'.trim().isEmpty
          ? null
          : '${json['avatar']}'.trim(),
      auth: auth,
      saltkey: saltkey,
      updatedAt: int.tryParse('${json['updatedAt'] ?? 0}') ?? 0,
    );
  }
}

/// 多账号会话管理：仅保存 auth/saltkey 与展示资料，不保存密码。
class AccountService extends ChangeNotifier {
  AccountService._();
  static final AccountService instance = AccountService._();

  static const String accountsKey = 'forum_accounts_v1';
  static const String activeKey = 'forum_active_account_v1';

  SharedPreferences? _prefs;
  List<SavedAccount> _accounts = const [];
  String? _activeId;
  String? _pendingRestoreId;
  bool _loaded = false;

  List<SavedAccount> get accounts => List<SavedAccount>.unmodifiable(_accounts);
  String? get activeId => _activeId;
  SavedAccount? get activeAccount {
    final id = _activeId;
    if (id == null) return null;
    for (final account in _accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  Future<void> loadAndSync() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    _accounts = _readAccounts(prefs);
    _activeId = prefs.getString(activeKey);
    _loaded = true;
    final api = ApiService.instance;
    if (api.isLoggedIn) {
      if (_accounts.isEmpty) {
        await saveCurrent();
      } else {
        final active = activeAccount;
        if (active != null &&
            active.auth != api.auth &&
            (_activeId == null || api.auth?.isNotEmpty == true)) {
          // Cookie 可能由网页登录刷新过，以当前会话为准更新活动账号。
          await _snapshotCurrent();
        }
      }
    }
    notifyListeners();
  }

  Future<void> saveCurrent({String? username}) async {
    final api = ApiService.instance;
    final auth = api.auth?.trim() ?? '';
    final saltkey = api.saltkey?.trim() ?? '';
    if (auth.isEmpty || saltkey.isEmpty) return;

    UserProfile? profile;
    try {
      profile = await api.getProfile();
    } catch (_) {
      // 资料拉取失败时仍保存会话，后续切换仍可用。
    }

    final previous = _activeId == null ? null : _findById(_activeId!);
    final resolvedName =
        (profile?.username?.trim().isNotEmpty == true
                ? profile!.username!.trim()
                : username?.trim())
            ?.trim();
    final name = (resolvedName?.isNotEmpty == true
            ? resolvedName
            : previous?.username?.trim())
        ?.trim();
    final finalName =
        (name?.isNotEmpty == true ? name : '论坛成员').toString();
    final uid = profile?.uid?.trim();
    final existing = _findByUid(uid) ??
        _findByUsername(finalName) ??
        previous;
    final id = existing?.id ??
        (uid?.isNotEmpty == true
            ? uid!
            : 'u:${finalName.toLowerCase()}');

    final account = SavedAccount(
      id: id,
      username: finalName,
      uid: uid?.isNotEmpty == true ? uid : existing?.uid,
      avatarUrl: profile?.avatarUrl ?? existing?.avatarUrl,
      auth: auth,
      saltkey: saltkey,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _upsert(account);
    _activeId = account.id;
    _pendingRestoreId = null;
    await _persist();
    notifyListeners();
  }

  Future<void> switchTo(String id) async {
    if (id == _activeId && ApiService.instance.isLoggedIn) return;
    await _snapshotCurrent();
    final target = _findById(id);
    if (target == null) return;
    await ApiService.instance.applyAccountSession(
      target.auth,
      target.saltkey,
    );
    _activeId = id;
    _pendingRestoreId = null;
    await _persist();
    notifyListeners();
  }

  Future<void> startAddAccount() async {
    await _snapshotCurrent();
    _pendingRestoreId = _activeId;
    await ApiService.instance.clearSessionForAdd();
    _activeId = null;
    await _persist();
    notifyListeners();
  }

  Future<void> cancelAddAccount() async {
    if (ApiService.instance.isLoggedIn) {
      _pendingRestoreId = null;
      return;
    }
    final previous = _pendingRestoreId;
    _pendingRestoreId = null;
    if (previous != null && _findById(previous) != null) {
      await switchTo(previous);
    } else {
      await _persist();
      notifyListeners();
    }
  }

  Future<void> onLoginSuccess(String username) async {
    await saveCurrent(username: username);
  }

  Future<void> logoutCurrent() async {
    await ApiService.instance.logout();
    final id = _activeId;
    _activeId = null;
    if (id != null) {
      _accounts = _accounts.where((account) => account.id != id).toList();
    }
    final next = _accounts.isEmpty ? null : _accounts.first;
    if (next != null) {
      await ApiService.instance.applyAccountSession(next.auth, next.saltkey);
      _activeId = next.id;
    }
    await _persist();
    notifyListeners();
  }

  Future<void> _snapshotCurrent() async {
    final api = ApiService.instance;
    final auth = api.auth?.trim() ?? '';
    final saltkey = api.saltkey?.trim() ?? '';
    if (auth.isEmpty || saltkey.isEmpty) return;
    final id = _activeId;
    if (id == null) return;
    final index = _accounts.indexWhere((account) => account.id == id);
    if (index < 0) return;
    final updated = _accounts[index].copyWith(
      auth: auth,
      saltkey: saltkey,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final list = List<SavedAccount>.from(_accounts)..[index] = updated;
    _accounts = list;
    await _persist();
  }

  SavedAccount? _findById(String id) {
    for (final account in _accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  SavedAccount? _findByUid(String? uid) {
    if (uid == null || uid.isEmpty) return null;
    for (final account in _accounts) {
      if (account.uid == uid) return account;
    }
    return null;
  }

  SavedAccount? _findByUsername(String name) {
    final lower = name.toLowerCase();
    for (final account in _accounts) {
      if (account.username.toLowerCase() == lower) return account;
    }
    return null;
  }

  void _upsert(SavedAccount account) {
    final list = List<SavedAccount>.from(_accounts);
    final index = list.indexWhere(
      (item) =>
          item.id == account.id ||
          item.username.toLowerCase() == account.username.toLowerCase(),
    );
    if (index >= 0) {
      list[index] = account.copyWith(id: list[index].id);
    } else {
      list.add(account);
    }
    _accounts = list;
  }

  List<SavedAccount> _readAccounts(SharedPreferences prefs) {
    final raw = prefs.getString(accountsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final result = <SavedAccount>[];
      for (final item in decoded) {
        if (item is Map) {
          final parsed = SavedAccount.fromJson(
            item.map((key, value) => MapEntry('$key', value)),
          );
          if (parsed != null) result.add(parsed);
        }
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persist() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setString(
      accountsKey,
      jsonEncode(_accounts.map((account) => account.toJson()).toList()),
    );
    final active = _activeId;
    if (active == null) {
      await prefs.remove(activeKey);
    } else {
      await prefs.setString(activeKey, active);
    }
  }
}
