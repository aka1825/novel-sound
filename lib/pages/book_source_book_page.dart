// 书源详情页：简介 + 目录，点章节直接进阅读页。
//
// 详情规则留空的字段在 [BookSourceEngine.book] 里已经用搜索结果兜过一次，
// 所以这里只负责展示，不再做二次兜底。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/book_source.dart';
import '../services/book_source_engine.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'book_source_reader_page.dart';

class BookSourceBookPage extends StatefulWidget {
  const BookSourceBookPage({
    super.key,
    required this.source,
    required this.item,
  });

  final BookSource source;
  final BookSourceSearchItem item;

  @override
  State<BookSourceBookPage> createState() => _BookSourceBookPageState();
}

class _BookSourceBookPageState extends State<BookSourceBookPage> {
  final _engine = BookSourceEngine();

  BookSourceBook? _book;
  List<BookSourceChapter> _chapters = const [];
  bool _loading = true;
  String? _error;
  bool _introExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final book = await _engine.book(widget.source, widget.item, reload: true);
      final chapters = await _engine.chapters(
        widget.source,
        book,
        reload: true,
      );
      if (!mounted) return;
      setState(() {
        _book = book;
        _chapters = chapters;
      });
    } on BookSourceException catch (exception) {
      if (mounted) setState(() => _error = exception.message);
    } catch (_) {
      if (mounted) setState(() => _error = '加载失败，请检查站点地址与规则');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openChapter(int index) {
    final book = _book;
    if (book == null) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => BookSourceReaderPage(
          source: widget.source,
          book: book,
          chapters: _chapters,
          initialIndex: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final book = _book;
    return SettingsArchivePage(
      title: book?.name ?? widget.item.name,
      code: 'SYSTEM / BOOK SOURCE',
      child: _body(context, palette, book),
    );
  }

  Widget _body(
    BuildContext context,
    HomePalette palette,
    BookSourceBook? book,
  ) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final message?) {
      return ContentNotice(
        icon: LucideIcons.circle_alert,
        title: '没能打开这本书',
        message: message,
        onRetry: _load,
      );
    }
    if (book == null) {
      return ContentNotice(
        icon: LucideIcons.circle_alert,
        title: '没有解析到这本书',
        message: '详情页可能改版了，回到书源里调一下详情规则。',
        onRetry: _load,
      );
    }
    return ListView(
      key: const ValueKey('book-source-book'),
      padding: featurePadding(context).copyWith(
        bottom: MediaQuery.paddingOf(context).bottom + 32,
      ),
      children: [
        _header(palette, book),
        const SizedBox(height: 12),
        if (book.intro case final intro? when intro.isNotEmpty) ...[
                  ContentPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText(
                          '简介',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        AppText(
                          intro,
                          maxLines: _introExpanded ? null : 5,
                          overflow: _introExpanded
                              ? TextOverflow.visible
                              : TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.7,
                            color: palette.muted,
                          ),
                        ),
                        if (intro.length > 120)
                          GestureDetector(
                            onTap: () => setState(
                              () => _introExpanded = !_introExpanded,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: AppText(
                                _introExpanded ? '收起' : '展开',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: palette.accentText,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: AppText(
                          '目录',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      AppText(
                        '共 ${_chapters.length} 章',
                        style: TextStyle(fontSize: 12, color: palette.muted),
                      ),
                    ],
                  ),
                ),
                for (var index = 0; index < _chapters.length; index++)
                  _chapterRow(palette, index),
      ],
    );
  }

  Widget _header(HomePalette palette, BookSourceBook book) {
    return ContentPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cover(palette, book.coverUrl),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  book.name,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 6),
                AppText(
                  book.author ?? '佚名',
                  style: TextStyle(fontSize: 13, color: palette.muted),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
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
                        '来源：${book.sourceName}',
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.accentText,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (_chapters.isNotEmpty)
                      GlassTextButton(
                        onPressed: () => _openChapter(0),
                        child: AppText('从第一章开始'),
                      ),
                    const SizedBox(width: 8),
                    GlassTextButton(
                      onPressed: _load,
                      child: const AppText('刷新目录'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chapterRow(HomePalette palette, int index) {
    final chapter = _chapters[index];
    return JellyTapSurface(
      onTap: () => _openChapter(index),
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.line, width: 0.6)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              child: AppText(
                '${index + 1}',
                style: TextStyle(fontSize: 11.5, color: palette.muted),
              ),
            ),
            Expanded(
              child: AppText(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, height: 1.4),
              ),
            ),
            Icon(LucideIcons.chevron_right, size: 14, color: palette.muted),
          ],
        ),
      ),
    );
  }

  Widget _cover(HomePalette palette, String? url) {
    final placeholder = Container(
      width: 74,
      height: 100,
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(LucideIcons.book_open, size: 24, color: palette.muted),
    );
    if (url == null || url.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        url,
        width: 74,
        height: 100,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => placeholder,
      ),
    );
  }
}
