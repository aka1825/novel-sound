// 自定义书源的持久化（shared_preferences，与正文替换同一套做法）。
//
// 书源是用户手写的配置，不是正文数据：量小（上限 50 条）、需要可导出可粘贴，
// 所以不用 Hive/加密箱，直接存一份 JSON 到 preferences。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';

class BookSourceStore extends ChangeNotifier {
  BookSourceStore();

  static final BookSourceStore instance = BookSourceStore();

  static const String preferenceKey = 'custom_book_sources_v1';

  /// 首次进书源管理时补默认书源的一次性标记。
  ///
  /// 用标记而不是「列表为空就补」：用户主动删掉七猫之后，不该又被塞回来。
  static const String seedPreferenceKey = 'custom_book_sources_seed_v1';

  /// 导入文本上限：正常一份书源 JSON 只有几 KB，512KB 足够挡住误粘贴。
  static const int maxImportChars = 512 * 1024;

  /// 默认书源：七猫小说（公开 JSON 接口 + 章节页正文，实测可用）。
  ///
  /// 与内置适配器（Rust `qimao` 路由）并存：这里是「配置版」，走 Dart 规则引擎，
  /// 用户可以在编辑页里改；内置那条走核心，不占配置。
  static const BookSource qimaoDefault = BookSource(
    id: 'src_qimao',
    name: '七猫小说',
    baseUrl: 'https://api-www.qimao.com',
    searchUrl: '/api/search/result?keyword={{key}}&page=1&pageSize=20',
    rules: BookSourceRules(
      searchList: 'json:data.search_list',
      searchName: 'json:title',
      searchAuthor: 'json:author',
      searchCover: 'json:image_link',
      searchIntro: 'json:intro',
      searchBookUrl: 'json:read_url',
      detailTocUrl:
          'tpl:https://api-www.qimao.com/api/book/chapter-list?book_id={{bookId}}',
      tocList: 'json:data.chapters',
      tocName: 'json:title',
      tocUrl: 'tpl:https://www.qimao.com/shuku/{{bookId}}-{{value}}/',
      content: 'css:.chapter-detail-article .article',
    ),
  );

  List<BookSource> _sources = const [];
  String? _warning;
  bool _loaded = false;
  int _revision = 0;
  Future<void>? _loading;
  Future<void>? _writes;

  List<BookSource> get sources => _sources;

  List<BookSource> get enabledSources => [
    for (final source in _sources)
      if (source.enabled) source,
  ];

  bool get loaded => _loaded;

  /// 每次落盘递增，页面据此判断要不要重画。
  int get revision => _revision;

  /// 读取时的非致命问题（部分书源损坏等），UI 直接展示。
  String? get warning => _warning;

  BookSource? byId(String id) {
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  /// 首次打开书源管理时补一条默认书源（[qimaoDefault]）。
  ///
  /// 只在「没播种过 + 当前一条都没有」时写入，并立刻打标记：之后无论用户是
  /// 删掉还是继续添加，都不会再被自动补回来。
  Future<void> seedDefaults() async {
    await load();
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(seedPreferenceKey) == true) return;
    final seeded = await preferences.setBool(seedPreferenceKey, true);
    if (!seeded) return;
    if (_sources.isNotEmpty) return;
    await upsert(qimaoDefault);
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      await (_loading ??= _load());
      _loaded = true;
    } finally {
      _loading = null;
    }
  }

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final text = preferences.getString(preferenceKey);
      if (text == null || text.trim().isEmpty) return;
      final raw = jsonDecode(text);
      if (raw is! Map ||
          raw['schemaVersion'] != bookSourceSchemaVersion ||
          raw['sources'] is! List) {
        throw const FormatException('书源存储格式无效');
      }
      final parsed = <BookSource>[];
      final ids = <String>{};
      for (final record in raw['sources'] as List) {
        try {
          if (record is! Map) throw const FormatException();
          final source = BookSource.fromJson(Map<String, dynamic>.from(record));
          if (source.name.isEmpty ||
              source.baseUrl.isEmpty ||
              !ids.add(source.id)) {
            throw const FormatException();
          }
          parsed.add(source);
        } catch (_) {
          _warning = '部分书源已损坏，已跳过';
        }
      }
      _sources = List<BookSource>.unmodifiable(parsed);
    } catch (_) {
      _warning = '无法读取自定义书源，已按空列表处理';
    }
  }

  Future<void> upsert(BookSource source) async {
    final error = source.validate();
    if (error != null) throw FormatException(error);
    await load();
    final next = [..._sources];
    final index = next.indexWhere((item) => item.id == source.id);
    if (index >= 0) {
      next[index] = source;
    } else {
      if (next.length >= BookSource.maxSources) {
        throw const FormatException('最多 ${BookSource.maxSources} 个书源');
      }
      next.add(source);
    }
    await _persist(next);
  }

  Future<void> remove(String id) async {
    await load();
    await _persist([
      for (final source in _sources)
        if (source.id != id) source,
    ]);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await load();
    await _persist([
      for (final source in _sources)
        if (source.id == id) source.copyWith(enabled: enabled) else source,
    ]);
  }

  /// 粘贴导入。支持三种形状：
  ///
  /// * `{"schemaVersion":1,"sources":[...]}`：本应用导出的整包；
  /// * `[ {...}, {...} ]`：书源数组；
  /// * `{...}`：单个书源（本应用格式或 legado 书源格式）。
  ///
  /// 返回成功导入的条数；一条都没导进来时抛 [FormatException] 说明原因。
  Future<int> importJson(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const FormatException('粘贴内容为空');
    if (trimmed.length > maxImportChars) {
      throw const FormatException('粘贴内容超过 512KB，请分批导入');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw const FormatException('不是合法的 JSON');
    }
    final records = <Object?>[];
    if (decoded is List) {
      records.addAll(decoded);
    } else if (decoded is Map) {
      if (decoded['sources'] is List) {
        records.addAll(decoded['sources'] as List);
      } else {
        records.add(decoded);
      }
    } else {
      throw const FormatException('JSON 顶层必须是对象或数组');
    }

    await load();
    final next = [..._sources];
    var imported = 0;
    String? firstError;
    for (final record in records) {
      if (record is! Map) continue;
      final map = Map<String, dynamic>.from(record);
      try {
        final source = map.containsKey('rules') || map.containsKey('baseUrl')
            ? BookSource.fromJson(map)
            : BookSource.fromLegadoJson(map);
        final error = source.validate();
        if (error != null) throw FormatException(error);
        final existing = next.indexWhere((item) => item.id == source.id);
        if (existing >= 0) {
          next[existing] = source;
        } else {
          if (next.length >= BookSource.maxSources) {
            throw FormatException('最多 ${BookSource.maxSources} 个书源');
          }
          next.add(
            source.id.isEmpty ? source.copyWith(id: newBookSourceId()) : source,
          );
        }
        imported++;
      } catch (error) {
        firstError ??=
            '${map['name'] ?? map['bookSourceName'] ?? '未命名'}：'
            '${error is FormatException ? error.message : '格式不正确'}';
      }
    }
    if (imported == 0) {
      throw FormatException(firstError ?? '没有可导入的书源');
    }
    await _persist(next);
    return imported;
  }

  /// 导出成可粘贴的整包 JSON，方便换设备时搬走。
  String exportJson() => const JsonEncoder.withIndent('  ').convert({
    'schemaVersion': bookSourceSchemaVersion,
    'sources': [for (final source in _sources) source.toJson()],
  });

  Future<void> _persist(List<BookSource> sources) {
    final snapshot = List<BookSource>.unmodifiable(sources);
    final next = (_writes ?? Future<void>.value()).then((_) async {
      final preferences = await SharedPreferences.getInstance();
      final saved = await preferences.setString(
        preferenceKey,
        jsonEncode({
          'schemaVersion': bookSourceSchemaVersion,
          'sources': [for (final source in snapshot) source.toJson()],
        }),
      );
      if (!saved) throw StateError('书源保存失败');
      _sources = snapshot;
      _warning = null;
      _revision++;
      notifyListeners();
    });
    late final Future<void> tail;
    void clear() {
      if (identical(_writes, tail)) _writes = null;
    }

    tail = next.then<void>(
      (_) => clear(),
      onError: (Object _, StackTrace _) => clear(),
    );
    _writes = tail;
    return next;
  }
}
