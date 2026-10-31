import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

List<String> normalizeUpdateChangelog(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return const [];

  // 兼容服务端常见的几种公告格式：真实换行、JSON 中二次转义的
  // \\n/\\r\\n、HTML <br> / <p> / <li>，避免正文全部粘成一行。
  text = text
      .replaceAll(r'\r\n', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\r', '\n')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(?:p|div|li)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '• ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'[\t ]+[•●▪]\s*'), '\n• ')
      .replaceAllMapped(
        RegExp(r'([。；;])\s*(?=\d{1,2}[.、)])'),
        (match) => '${match.group(1)}\n',
      );

  final lines = text
      .split(RegExp(r'[\n\r]+'))
      .map((line) => line
          .replaceFirst(RegExp(r'^[•●▪*\-]+\s*'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim())
      .where((line) => line.isNotEmpty)
      .toList();

  // 某些 update.json 只有一整个中文段落且完全没有换行；长度较长时按
  // 句号/分号/问号/感叹号拆成易读条目。没有自然分隔符时保持原文。
  if (lines.length == 1 && lines.first.length > 48) {
    final sentenceLines = <String>[];
    final buffer = StringBuffer();
    for (final rune in lines.first.runes) {
      final char = String.fromCharCode(rune);
      buffer.write(char);
      if ('。！？；;'.contains(char)) {
        final value = buffer.toString().trim();
        if (value.isNotEmpty) sentenceLines.add(value);
        buffer.clear();
      }
    }
    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) sentenceLines.add(tail);
    if (sentenceLines.length > 1) return sentenceLines;
  }

  return lines;
}

class UpdateInfo {
  final String version;
  final int versionCode;
  final String changelog;
  final String downloadUrl;
  final int? size;
  final String sha256;

  const UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.changelog,
    required this.downloadUrl,
    this.size,
    this.sha256 = '',
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: '${json['version'] ?? ''}'.trim(),
      versionCode: int.tryParse('${json['versionCode'] ?? 0}') ?? 0,
      changelog: '${json['changelog'] ?? ''}'.trim(),
      downloadUrl: '${json['downloadUrl'] ?? ''}'.trim(),
      size: int.tryParse('${json['size'] ?? ''}'),
      sha256: '${json['sha256'] ?? ''}'.trim(),
    );
  }
}

class UpdateCheckResult {
  final String currentVersion;
  final int currentVersionCode;
  final UpdateInfo info;

  const UpdateCheckResult({
    required this.currentVersion,
    required this.currentVersionCode,
    required this.info,
  });

  bool get hasUpdate {
    if (info.versionCode > 0 && currentVersionCode > 0) {
      return info.versionCode > currentVersionCode;
    }
    return compareVersionNames(info.version, currentVersion) > 0;
  }
}

/// 比较 a.b.c 形式的版本号；无法解析的段按 0 处理。
int compareVersionNames(String left, String right) {
  final a = _versionParts(left);
  final b = _versionParts(right);
  final length = a.length > b.length ? a.length : b.length;
  for (var index = 0; index < length; index++) {
    final av = index < a.length ? a[index] : 0;
    final bv = index < b.length ? b[index] : 0;
    if (av != bv) return av > bv ? 1 : -1;
  }
  return 0;
}

List<int> _versionParts(String raw) {
  final cleaned = raw.trim().replaceFirst(RegExp(r'^v', caseSensitive: false), '');
  final main = cleaned.split(RegExp(r'[-+]')).first;
  return main
      .split('.')
      .map((part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList(growable: false);
}

class DownloadProgress {
  final int status;
  final int downloaded;
  final int total;

  const DownloadProgress({
    required this.status,
    required this.downloaded,
    required this.total,
  });

  double? get fraction {
    if (total <= 0) return null;
    return downloaded / total;
  }

  bool get completed => status == 8; // DownloadManager.STATUS_SUCCESSFUL
  bool get failed => status == 16; // DownloadManager.STATUS_FAILED
}

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const _channel = MethodChannel('mtforum/update');
  static const _startupKey = 'startup_auto_check_update';
  static const String githubRepository = 'wangpengfgf/Mtforum1';
  static const String latestReleaseApi =
      'https://api.github.com/repos/$githubRepository/releases/latest';
  static const manifestUrl = String.fromEnvironment(
    'MTFORUM_UPDATE_URL',
    defaultValue: '',
  );

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: const {
        'Accept': 'application/json',
        'Cache-Control': 'no-cache',
      },
    ),
  );

  Future<bool> getStartupCheckEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_startupKey) ?? true;
  }

  Future<void> setStartupCheckEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_startupKey, value);
  }

  Future<Map<String, dynamic>> getCurrentVersionInfo() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>('getVersionInfo');
    return raw ?? const <String, dynamic>{};
  }

  Future<UpdateCheckResult> check() async {
    final version = await getCurrentVersionInfo();
    final currentName = '${version['versionName'] ?? ''}';
    final currentCode = int.tryParse('${version['versionCode'] ?? 0}') ?? 0;

    final info = manifestUrl.isNotEmpty
        ? await _checkLegacyManifest()
        : await _checkGitHubRelease();

    return UpdateCheckResult(
      currentVersion: currentName,
      currentVersionCode: currentCode,
      info: info,
    );
  }

  Future<UpdateInfo> _checkLegacyManifest() async {
    final response = await _dio.get<dynamic>(
      manifestUrl,
      queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
      options: Options(responseType: ResponseType.plain),
    );
    dynamic decoded = response.data;
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map) throw const FormatException('update.json 格式错误');
    final info = _parseManifest(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
    final rawDownloadUri = Uri.tryParse(info.downloadUrl);
    if (rawDownloadUri != null && !rawDownloadUri.hasScheme) {
      final resolved = Uri.parse(manifestUrl).resolveUri(rawDownloadUri).toString();
      return _validateInfo(
        UpdateInfo(
          version: info.version,
          versionCode: info.versionCode,
          changelog: info.changelog,
          downloadUrl: resolved,
          size: info.size,
          sha256: info.sha256,
        ),
      );
    }
    return _validateInfo(info);
  }

  Future<UpdateInfo> _checkGitHubRelease() async {
    final release = await _getJson(
      latestReleaseApi,
      accept: 'application/vnd.github+json',
    );
    if (release is! Map) throw const FormatException('GitHub 发行版格式错误');
    if (release['draft'] == true || release['prerelease'] == true) {
      throw const FormatException('最新发行版尚未正式发布');
    }

    final tag = '${release['tag_name'] ?? ''}'.trim();
    final version = _versionFromTag(tag);
    if (version.isEmpty) {
      throw FormatException('无法识别发行版版本：$tag');
    }

    final assets = <Map<String, dynamic>>[];
    final rawAssets = release['assets'];
    if (rawAssets is List) {
      for (final item in rawAssets) {
        if (item is Map) {
          assets.add(item.map((key, value) => MapEntry('$key', value)));
        }
      }
    }

    Map<String, dynamic>? manifestAsset;
    for (final asset in assets) {
      if ('${asset['name'] ?? ''}'.trim() == 'update.json') {
        manifestAsset = asset;
        break;
      }
    }
    final configAsset = manifestAsset;
    if (configAsset != null) {
      final url = '${configAsset['browser_download_url'] ?? ''}'.trim();
      if (!_trustedGithubAsset(url)) {
        throw const FormatException('更新配置地址不受信任');
      }
      final raw = await _getText(url, accept: 'application/json');
      final map = jsonDecode(raw);
      if (map is! Map) throw const FormatException('更新配置不是有效的 JSON');
      final parsed = _parseManifest(
        map.map((key, value) => MapEntry('$key', value)),
        fallbackVersion: version,
      );
      if (parsed.versionCode > 0 && parsed.version != version) {
        throw const FormatException('更新配置版本与发行版标签不一致');
      }
      return _validateInfo(parsed);
    }

    Map<String, dynamic>? apk;
    for (final asset in assets) {
      final name = '${asset['name'] ?? ''}'.trim().toLowerCase();
      if (name.endsWith('.apk')) {
        apk = asset;
        break;
      }
    }
    if (apk == null) throw const FormatException('最新发行版没有 APK 资产');
    final downloadUrl = '${apk['browser_download_url'] ?? ''}'.trim();
    if (!_trustedGithubAsset(downloadUrl)) {
      throw const FormatException('安装包地址不受信任');
    }
    final digest = '${apk['digest'] ?? ''}'.trim();
    final sha256 = digest.toLowerCase().startsWith('sha256:')
        ? digest.substring(7).trim()
        : digest;
    return _validateInfo(
      UpdateInfo(
        version: version,
        versionCode: 0,
        changelog: '${release['body'] ?? ''}'.trim(),
        downloadUrl: downloadUrl,
        size: (apk['size'] as num?)?.toInt(),
        sha256: sha256,
      ),
    );
  }

  UpdateInfo _parseManifest(
    Map<String, dynamic> map, {
    String fallbackVersion = '',
  }) {
    if (map['schema_version'] != null && map['latest'] is Map) {
      final latest = (map['latest'] as Map).map(
        (key, value) => MapEntry('$key', value),
      );
      final notes = latest['changelog'];
      final changelog = notes is List
          ? notes.map((item) => '$item'.trim()).where((item) => item.isNotEmpty).join('\n')
          : '${notes ?? ''}'.trim();
      return UpdateInfo(
        version: '${latest['version_name'] ?? fallbackVersion}'.trim(),
        versionCode: int.tryParse('${latest['version_code'] ?? 0}') ?? 0,
        changelog: changelog,
        downloadUrl: '${latest['download_url'] ?? latest['download_page_url'] ?? ''}'.trim(),
        size: int.tryParse('${latest['file_size_bytes'] ?? ''}'),
        sha256: '${latest['sha256'] ?? ''}'.trim(),
      );
    }
    final info = UpdateInfo.fromJson(map);
    if (info.version.isEmpty && fallbackVersion.isNotEmpty) {
      return UpdateInfo(
        version: fallbackVersion,
        versionCode: info.versionCode,
        changelog: info.changelog,
        downloadUrl: info.downloadUrl,
        size: info.size,
        sha256: info.sha256,
      );
    }
    return info;
  }

  UpdateInfo _validateInfo(UpdateInfo info) {
    if (info.version.isEmpty || info.downloadUrl.isEmpty) {
      throw const FormatException('更新信息缺少必要字段');
    }
    final uri = Uri.tryParse(info.downloadUrl);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      throw const FormatException('更新下载地址必须是 HTTPS 地址');
    }
    return info;
  }

  String _versionFromTag(String tag) {
    final match = RegExp(r'^v?(\d+\.\d+\.\d+)(?:-build\.\d+)?', caseSensitive: false)
        .firstMatch(tag.trim());
    return match?.group(1) ?? '';
  }

  bool _trustedGithubAsset(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme.toLowerCase() != 'https') return false;
    if (uri.host.toLowerCase() != 'github.com') return false;
    return uri.path.startsWith('/$githubRepository/releases/download/');
  }

  Future<dynamic> _getJson(String url, {required String accept}) async {
    final text = await _getText(url, accept: accept);
    return jsonDecode(text);
  }

  Future<String> _getText(String url, {required String accept}) async {
    try {
      final response = await _dio.get<dynamic>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'Accept': accept,
            'User-Agent': 'MTForum-Android',
            'X-GitHub-Api-Version': '2022-11-28',
          },
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw StateError('GitHub 请求失败（$status）');
      }
      final realUri = response.realUri;
      final host = realUri.host.toLowerCase();
      if (realUri.scheme.toLowerCase() != 'https' ||
          !const {
            'api.github.com',
            'github.com',
            'objects.githubusercontent.com',
            'release-assets.githubusercontent.com',
            'github-releases.githubusercontent.com',
          }.contains(host)) {
        throw const FormatException('更新请求跳转到了未知网站');
      }
      final raw = response.data?.toString().trim() ?? '';
      if (raw.isEmpty) throw const FormatException('GitHub 返回了空响应');
      return raw;
    } on DioException catch (error) {
      final status = error.response?.statusCode ?? 0;
      if (status == 403 || status == 429) {
        throw StateError('GitHub API 请求过于频繁，请稍后再试');
      }
      if (status == 404) {
        throw StateError('GitHub 仓库暂无发行版');
      }
      rethrow;
    }
  }

  Future<bool> verifyDownloadHash(int id, String expectedSha256) async {
    final expected = expectedSha256.trim().toLowerCase();
    if (expected.isEmpty) return true;
    final actual = await _channel.invokeMethod<String>('sha256Download', {'id': id});
    if (actual == null || actual.isEmpty) {
      throw StateError('无法校验安装包完整性');
    }
    return actual.toLowerCase() == expected;
  }

  Future<int> startDownload(UpdateInfo info) async {
    final uri = Uri.tryParse(info.downloadUrl);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      throw StateError('软件更新下载地址无效，只支持 HTTPS');
    }
    final id = await _channel.invokeMethod<int>('startDownload', {
      'url': info.downloadUrl,
      'fileName': 'MTForum-${info.version}-Release.apk',
    });
    if (id == null) throw StateError('启动下载失败');
    return id;
  }

  Future<void> openDownloadInBrowser(UpdateInfo info) async {
    final uri = Uri.tryParse(info.downloadUrl);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty) {
      throw StateError('软件更新下载地址无效，只支持 HTTPS');
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) throw StateError('无法打开浏览器');
  }

  Future<DownloadProgress> queryDownload(int id) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'queryDownload',
      {'id': id},
    );
    if (result == null) {
      return const DownloadProgress(status: 16, downloaded: 0, total: 0);
    }
    return DownloadProgress(
      status: int.tryParse('${result['status'] ?? 0}') ?? 0,
      downloaded: int.tryParse('${result['downloaded'] ?? 0}') ?? 0,
      total: int.tryParse('${result['total'] ?? 0}') ?? 0,
    );
  }

  Future<String> installDownload(int id) async {
    return await _channel.invokeMethod<String>('installDownload', {'id': id}) ??
        'failed';
  }
}

Future<void> showUpdateDialog(
  BuildContext context,
  UpdateCheckResult result,
) async {
  if (!result.hasUpdate) return;
  final info = result.info;
  final theme = Theme.of(context);
  final colors = theme.colorScheme;

  final lines = normalizeUpdateChangelog(info.changelog);

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 18, 10, 18),
              color: colors.primaryContainer.withValues(alpha: 0.72),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.rocket_launch_rounded,
                      color: colors.onPrimary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '发现新版本',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: colors.onPrimaryContainer,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'MTForum v${info.version}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onPrimaryContainer
                                .withValues(alpha: 0.76),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '稍后更新',
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(Icons.close_rounded),
                    color: colors.onPrimaryContainer,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _UpdateVersionCard(
                          label: '当前版本',
                          version: result.currentVersion,
                          emphasized: false,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(
                          Icons.arrow_forward_rounded,
                          color: colors.primary,
                        ),
                      ),
                      Expanded(
                        child: _UpdateVersionCard(
                          label: '最新版本',
                          version: info.version,
                          emphasized: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: 19,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '本次更新',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (info.size != null && info.size! > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            _formatUpdateSize(info.size!),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 230),
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: colors.outlineVariant.withValues(alpha: 0.72),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: lines.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Text(
                                '优化使用体验并修复已知问题',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            )
                          : Column(
                              children: [
                                for (var index = 0;
                                    index < lines.length;
                                    index++)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          width: 22,
                                          height: 22,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: colors.primaryContainer,
                                            borderRadius:
                                                BorderRadius.circular(7),
                                          ),
                                          child: Text(
                                            '${index + 1}',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                              color:
                                                  colors.onPrimaryContainer,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            lines[index],
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(height: 1.5),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              color: colors.surfaceContainerLow,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(dialogContext);
                        try {
                          await UpdateService.instance
                              .openDownloadInBrowser(info);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('打开浏览器失败：$e')),
                            );
                          }
                        }
                      },
                      icon: const Icon(
                        Icons.open_in_browser_rounded,
                        size: 18,
                      ),
                      label: const Text('浏览器下载'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(dialogContext);
                        showUpdateDownloadDialog(context, info);
                      },
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('立即更新'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

String _formatUpdateSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kilobytes = bytes / 1024;
  if (kilobytes < 1024) return '${kilobytes.toStringAsFixed(1)} KB';
  final megabytes = kilobytes / 1024;
  return '${megabytes.toStringAsFixed(1)} MB';
}

class _UpdateVersionCard extends StatelessWidget {
  final String label;
  final String version;
  final bool emphasized;

  const _UpdateVersionCard({
    required this.label,
    required this.version,
    required this.emphasized,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: emphasized
            ? colors.primaryContainer.withValues(alpha: 0.72)
            : colors.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: emphasized
              ? colors.primary.withValues(alpha: 0.28)
              : colors.outlineVariant.withValues(alpha: 0.68),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'v$version',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              color: emphasized ? colors.primary : colors.onSurface,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showUpdateDownloadDialog(
  BuildContext context,
  UpdateInfo info,
) async {
  final service = UpdateService.instance;
  int? downloadId;
  Timer? timer;
  final progress = ValueNotifier<DownloadProgress?>(null);
  final error = ValueNotifier<String?>(null);

  try {
    downloadId = await service.startDownload(info);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$e')),
      );
    }
    progress.dispose();
    error.dispose();
    return;
  }

  timer = Timer.periodic(const Duration(milliseconds: 650), (_) async {
    try {
      final value = await service.queryDownload(downloadId!);
      progress.value = value;
      if (value.completed || value.failed) timer?.cancel();
      if (value.failed) error.value = '安装包下载失败';
    } catch (e) {
      timer?.cancel();
      error.value = '$e';
    }
  });

  if (!context.mounted) {
    timer?.cancel();
    progress.dispose();
    error.dispose();
    return;
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text('正在下载 v${info.version}'),
        content: ValueListenableBuilder<DownloadProgress?>(
          valueListenable: progress,
          builder: (_, value, __) {
            return ValueListenableBuilder<String?>(
              valueListenable: error,
              builder: (_, errorText, __) {
                if (errorText != null) return Text(errorText);
                if (value == null) {
                  return const LinearProgressIndicator();
                }
                if (value.completed) {
                  return const Text('下载完成，可以安装新版本。');
                }
                final percent = value.fraction == null
                    ? null
                    : '${(value.fraction! * 100).clamp(0, 100).toStringAsFixed(0)}%';
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: value.fraction),
                    const SizedBox(height: 10),
                    Text(percent == null ? '下载中…' : '下载中 $percent'),
                  ],
                );
              },
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              timer?.cancel();
              Navigator.pop(dialogContext);
            },
            child: const Text('后台下载'),
          ),
          ValueListenableBuilder<DownloadProgress?>(
            valueListenable: progress,
            builder: (_, value, __) {
              return FilledButton(
                onPressed: value?.completed == true
                    ? () async {
                        try {
                          final verified = await service.verifyDownloadHash(
                            downloadId!,
                            info.sha256,
                          );
                          if (!verified) {
                            if (dialogContext.mounted) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text('安装包 SHA-256 校验失败，请重新下载'),
                                ),
                              );
                            }
                            return;
                          }
                          final result =
                              await service.installDownload(downloadId!);
                          if (result == 'permission') {
                            if (dialogContext.mounted) {
                              ScaffoldMessenger.of(dialogContext).showSnackBar(
                                const SnackBar(
                                  content: Text('请允许“安装未知应用”，返回后再次点击安装'),
                                ),
                              );
                            }
                          } else if (result == 'started' &&
                              dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        } catch (error) {
                          if (dialogContext.mounted) {
                            ScaffoldMessenger.of(dialogContext).showSnackBar(
                              SnackBar(content: Text('安装包校验失败：$error')),
                            );
                          }
                        }
                      }
                    : null,
                child: const Text('安装'),
              );
            },
          ),
        ],
      );
    },
  );

  timer?.cancel();
  progress.dispose();
  error.dispose();
}
