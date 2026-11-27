// 七猫小说（核心适配器）的浏览入口：搜索 → 目录 → 正文。
//
// 这个源不走「自定义书源」那套规则，而是由 Rust 核心里的 `qimao` 适配器直连
// 站点公开接口（`/api/search/result`、`/api/book/chapter-list`）并解析章节页。
// 所以这里的 UI 刻意做得很薄：只负责调 `ApiClient.qimao*` 三个方法并展示。

import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/api_client.dart';
import '../widgets/home/home_design.dart';
import '../widgets/wenku/wenku_ui.dart';

class QimaoPage extends StatefulWidget {
  const QimaoPage({super.key, this.api, this.initialBookId, this.initialName});

  /// 单测可注入；正常走进程内客户端。
  final ApiClient? api;

  /// 从搜索页点结果进来时带上书号：直接落到目录，不要求再搜一次。
  final String? initialBookId;
  final String? initialName;

  @override
  State<QimaoPage> createState() => _QimaoPageState();
}

class _QimaoBook {
  const _QimaoBook({
    required this.id,
    required this.name,
    required this.author,
    required this.cover,
    required this.intro,
  });

  final String id;
  final String name;
  final String author;
  final String cover;
  final String intro;
}

class _QimaoChapter {
  const _QimaoChapter({
    required this.id,
    required this.title,
    required this.vip,
  });

  final String id;
  final String title;
  final bool vip;
}

class _QimaoPageState extends State<QimaoPage> {
  ApiClient get _api => widget.api ?? ApiClient.instance;

  final _input = TextEditingController();

  bool _busy = false;
  String? _error;

  List<_QimaoBook> _books = const [];
  _QimaoBook? _book;
  List<_QimaoChapter> _chapters = const [];
  int _index = 0;
  String? _content;

  @override
  void initState() {
    super.initState();
    final bookId = widget.initialBookId;
    if (bookId != null && bookId.isNotEmpty) {
      // 搜索页点结果进来：直接拉目录。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          _openBook(
            _QimaoBook(
              id: bookId,
              name: widget.initialName ?? '猫小说',
              author: '',
              cover: '',
              intro: '',
            ),
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _search(String raw) async {
    final key = raw.trim();
    if (key.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _books = const [];
      _book = null;
      _chapters = const [];
      _content = null;
    });
    try {
      final payload = await _api.qimaoSearch(key);
      final data = payload['data'];
      if (data is! List) throw StateError('搜索没有返回结果');
      final books = <_QimaoBook>[];
      for (final item in data) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final id = '${map['bookId'] ?? ''}';
        final name = '${map['name'] ?? ''}';
        if (id.isEmpty || name.isEmpty) continue;
        books.add(
          _QimaoBook(
            id: id,
            name: name,
            author: '${map['author'] ?? ''}',
            cover: '${map['coverUrl'] ?? ''}',
            intro: '${map['intro'] ?? ''}',
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _books = books;
        if (books.isEmpty) _error = '七猫没有搜到这本书';
      });
    } catch (error) {
      if (mounted) setState(() => _error = _messageOf(error, '搜索失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBook(_QimaoBook book) async {
    setState(() {
      _busy = true;
      _error = null;
      _book = book;
      _chapters = const [];
      _content = null;
    });
    try {
      final payload = await _api.qimaoToc(book.id);
      final data = payload['data'];
      final raw = data is Map ? data['chapters'] : null;
      if (raw is! List) throw StateError('没有取到目录');
      final chapters = <_QimaoChapter>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final id = '${map['id'] ?? ''}';
        final title = '${map['title'] ?? ''}';
        if (id.isEmpty || title.isEmpty) continue;
        chapters.add(
          _QimaoChapter(id: id, title: title, vip: map['isVip'] == true),
        );
      }
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        if (chapters.isEmpty) _error = '目录是空的，可能站点改版了';
      });
    } catch (error) {
      if (mounted) setState(() => _error = _messageOf(error, '目录加载失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openChapter(int index) async {
    final book = _book;
    if (book == null || index < 0 || index >= _chapters.length) return;
    setState(() {
      _busy = true;
      _error = null;
      _index = index;
      _content = null;
    });
    try {
      final payload = await _api.qimaoChapter(book.id, _chapters[index].id);
      final data = payload['data'];
      final text = data is Map ? data['content'] : null;
      if (text is! String || text.trim().isEmpty) {
        throw StateError('这一章没有取到正文（可能是付费章节）');
      }
      if (!mounted) return;
      setState(() => _content = text);
    } catch (error) {
      if (mounted) setState(() => _error = _messageOf(error, '正文加载失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _messageOf(Object error, String fallback) {
    if (error is StateError) return error.message;
    final text = error.toString();
    // ApiException 的 message 已经是中文文案，直接取；其它异常统一兜底。
    if (text.contains('qimao') || text.contains('article block missing')) {
      return '$fallback：$text';
    }
    return fallback;
  }

  void _back() {
    if (_content != null) {
      setState(() {
        _content = null;
        _error = null;
      });
      return;
    }
    if (_book != null) {
      setState(() {
        _book = null;
        _chapters = const [];
        _error = null;
      });
      return;
    }
    Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(palette),
            Expanded(child: _body(palette)),
            if (_content != null) _navBar(palette),
          ],
        ),
      ),
    );
  }

  Widget _topBar(HomePalette palette) {
    final title = _content != null
        ? (_chapters.isEmpty ? '七猫小说' : _chapters[_index].title)
        : _book?.name ?? '七猫小说';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 8, 2),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('qimao-back'),
            tooltip: '返回',
            icon: Icon(LucideIcons.arrow_left, size: 22, color: palette.ink),
            onPressed: _back,
          ),
          Expanded(
            child: Center(
              child: AppText(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
            ),
          ),
          if (_book != null && _chapters.isNotEmpty && _content != null)
            IconButton(
              tooltip: '目录',
              icon: Icon(
                CupertinoIcons.list_bullet,
                size: 20,
                color: palette.ink,
              ),
              onPressed: () => setState(() {
                _content = null;
                _error = null;
              }),
            )
          else
            const SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _body(HomePalette palette) {
    if (_content != null) return _reader(palette);
    if (_book != null) return _toc(palette);
    return _searchView(palette);
  }

  Widget _searchView(HomePalette palette) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: AppSearchField(
            inputKey: const ValueKey('qimao-search-input'),
            controller: _input,
            hint: '搜索七猫书名或作者',
            autofocus: true,
            onSubmitted: _search,
          ),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _books.isEmpty
              ? ContentNotice(
                  icon: LucideIcons.search,
                  title: _error ?? '输入书名搜七猫',
                  message: _error == null ? '搜索、目录、正文都走核心里的七猫适配器。' : null,
                  onRetry: _error == null ? null : () => _search(_input.text),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    0,
                    16,
                    MediaQuery.paddingOf(context).bottom + 24,
                  ),
                  itemCount: _books.length,
                  itemBuilder: (context, index) =>
                      _bookRow(palette, _books[index]),
                ),
        ),
      ],
    );
  }

  Widget _bookRow(HomePalette palette, _QimaoBook book) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ContentPanel(
        onTap: () => _openBook(book),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cover(palette, book.cover, 52, 70),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppText(
                    book.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  AppText(
                    book.author.isEmpty ? '佚名' : book.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: palette.muted),
                  ),
                  if (book.intro.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    AppText(
                      book.intro,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: palette.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toc(HomePalette palette) {
    if (_busy && _chapters.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_chapters.isEmpty) {
      return ContentNotice(
        icon: LucideIcons.circle_alert,
        title: _error ?? '没有取到目录',
        onRetry: _book == null ? null : () => _openBook(_book!),
      );
    }
    return ListView.builder(
      key: const ValueKey('qimao-toc'),
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        MediaQuery.paddingOf(context).bottom + 24,
      ),
      itemCount: _chapters.length,
      itemBuilder: (context, index) {
        final chapter = _chapters[index];
        return InkWell(
          onTap: () => _openChapter(index),
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: palette.line, width: 0.6),
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: AppText(
                    chapter.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, color: palette.ink),
                  ),
                ),
                if (chapter.vip)
                  AppText(
                    'VIP',
                    style: TextStyle(fontSize: 11, color: palette.accentText),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _reader(HomePalette palette) {
    final text = _content ?? '';
    final paragraphs = text.split('\n');
    return SelectionArea(
      child: ListView.builder(
        key: const ValueKey('qimao-reader'),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        itemCount: paragraphs.length,
        itemBuilder: (context, index) {
          final paragraph = paragraphs[index];
          if (paragraph.isEmpty) return const SizedBox(height: 12);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AppText(
              paragraph,
              style: TextStyle(fontSize: 17, height: 1.9, color: palette.ink),
            ),
          );
        },
      ),
    );
  }

  Widget _navBar(HomePalette palette) {
    final hasPrevious = _index > 0;
    final hasNext = _index < _chapters.length - 1;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: palette.canvas,
          border: Border(top: BorderSide(color: palette.line, width: 0.6)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            TextButton(
              onPressed: hasPrevious ? () => _openChapter(_index - 1) : null,
              child: const Text('上一章'),
            ),
            Expanded(
              child: _busy
                  ? const Center(
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : AppText(
                      '${_index + 1} / ${_chapters.length}',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
            ),
            TextButton(
              onPressed: hasNext ? () => _openChapter(_index + 1) : null,
              child: const Text('下一章'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(HomePalette palette, String url, double width, double height) {
    final placeholder = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(LucideIcons.book_open, size: 20, color: palette.muted),
    );
    if (url.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => placeholder,
      ),
    );
  }
}
