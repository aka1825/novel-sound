// 书源搜索页：一次并发搜所有启用的自定义书源，结果按书源分组展示。
//
// 与搜索页里那套「番茄 / 书旗」互不影响：这里只读 [BookSourceStore]，
// 走 [BookSourceEngine] 的纯 Dart 抓取，失败只在结果页底部列一句原因。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/book_source.dart';
import '../services/book_source_engine.dart';
import '../services/book_source_store.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'book_source_book_page.dart';

class BookSourceSearchPage extends StatefulWidget {
  const BookSourceSearchPage({super.key, this.store, this.onlySourceId});

  final BookSourceStore? store;

  /// 只搜这一条书源；为 null 时搜所有启用的书源。
  final String? onlySourceId;

  @override
  State<BookSourceSearchPage> createState() => _BookSourceSearchPageState();
}

class _BookSourceSearchPageState extends State<BookSourceSearchPage> {
  BookSourceStore get _store => widget.store ?? BookSourceStore.instance;

  final _engine = BookSourceEngine();
  final _input = TextEditingController();

  bool _busy = false;
  bool _searched = false;
  String? _error;
  List<BookSourceSearchItem> _items = const [];
  List<String> _failures = const [];

  /// 当前参与搜索的书源：全部启用项，或从书源管理页点进来时的那一条。
  List<BookSource> get _targets {
    final only = widget.onlySourceId;
    if (only == null) return _store.enabledSources;
    return [
      for (final source in _store.sources)
        if (source.id == only && source.enabled) source,
    ];
  }

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    _store.load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    _engine.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _run(String raw) async {
    final keyword = raw.trim();
    if (keyword.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _failures = const [];
      _items = const [];
    });
    try {
      final outcome = await _engine.searchAll(_targets, keyword);
      if (!mounted) return;
      setState(() {
        _searched = true;
        _items = outcome.items;
        _failures = outcome.failures;
        if (outcome.items.isEmpty && outcome.failures.isEmpty) {
          _error = '没有启用的书源';
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _searched = true;
          _error = error is BookSourceException ? error.message : '搜索失败，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 顶部状态行的文案：搜索中 / 全部启用源 / 单源模式。
  String _statusLabel() {
    final targets = _targets;
    if (_busy) return '正在搜索 ${targets.length} 个书源…';
    if (widget.onlySourceId == null) return '启用中：${targets.length} 个书源';
    final name = targets.isEmpty ? '已停用' : targets.first.name;
    return '当前书源：$name';
  }

  void _open(BookSourceSearchItem item) {
    final source = _store.byId(item.sourceId);
    if (source == null) {
      setState(() => _error = '这个书源已被删除');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => BookSourceBookPage(source: source, item: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsArchivePage(
      title: '书源搜索',
      code: 'SYSTEM / BOOK SOURCE SEARCH',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              archiveChromeInset(context) + 12,
              16,
              8,
            ),
            child: AppSearchField(
              inputKey: const ValueKey('book-source-search-input'),
              controller: _input,
              hint: '输入书名或作者',
              autofocus: true,
              onSubmitted: _run,
            ),
          ),
          SizedBox(
            height: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _statusLabel(),
                      style: TextStyle(
                        fontSize: 12,
                        color: HomePalette.of(context).muted,
                      ),
                    ),
                  ),
                  if (_busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
          ),
          Expanded(child: _results(context)),
        ],
      ),
    );
  }

  Widget _results(BuildContext context) {
    final palette = HomePalette.of(context);
    if (_error case final message?) {
      return ContentNotice(
        icon: LucideIcons.circle_alert,
        title: '没有结果',
        message: message,
        onRetry: () => _run(_input.text),
      );
    }
    if (!_searched) {
      return ContentNotice(
        icon: LucideIcons.search,
        title: '搜一本书试试',
        message: '输入书名或作者后回车，会同时搜所有启用的书源。',
      );
    }
    if (_items.isEmpty) {
      return ContentNotice(
        icon: LucideIcons.search_x,
        title: '这些书源都没有这本书',
        message: _failures.isEmpty
            ? '换个关键词，或者在书源管理里补一条更准的规则。'
            : '失败原因：${_failures.join('；')}',
        onRetry: () => _run(_input.text),
      );
    }
    return ListView.builder(
      key: const ValueKey('book-source-search-results'),
      padding: EdgeInsets.fromLTRB(16, 4, 16, MediaQuery.paddingOf(context).bottom + 32),
      itemCount: _items.length + (_failures.isEmpty ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == _items.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '这些书源没返回结果：${_failures.join('；')}',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: palette.muted,
              ),
            ),
          );
        }
        final item = _items[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ContentPanel(
            onTap: () => _open(item),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _cover(palette, item.coverUrl),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppText(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      AppText(
                        item.author ?? '佚名',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: palette.muted),
                      ),
                      if (item.intro case final intro?) ...[
                        const SizedBox(height: 6),
                        AppText(
                          intro,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.55,
                            color: palette.muted,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: palette.soft,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: AppText(
                          item.sourceName,
                          style: TextStyle(
                            fontSize: 11,
                            color: palette.accentText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _cover(HomePalette palette, String? url) {
    if (url == null || url.isEmpty) return _coverPlaceholder(palette);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url,
        width: 56,
        height: 76,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => _coverPlaceholder(palette),
      ),
    );
  }

  Widget _coverPlaceholder(HomePalette palette) => Container(
    width: 56,
    height: 76,
    decoration: BoxDecoration(
      color: palette.soft,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(LucideIcons.book_open, size: 20, color: palette.muted),
  );
}
