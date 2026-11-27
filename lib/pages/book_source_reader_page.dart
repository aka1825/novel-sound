// 书源阅读页：上下滚动的纯文本阅读器，带上一章/下一章与目录跳转。
//
// 刻意做成独立的最小阅读器：主阅读器绑着番茄的书/章节模型、朗读、AI 校对、
// 离线缓存等一整套链路，把自定义书源塞进去等于把两条数据链拧在一起。
// 这里只要「按章取正文 + 记住当前章」，够用且不会污染主链路。
//
// 正文已经过 [normalizeChapterContent] 规整（逐行 trim、连续空行折叠），
// 排版只需按行拆段。

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/book_source.dart';
import '../services/book_source_engine.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/wenku/wenku_ui.dart';

class BookSourceReaderPage extends StatefulWidget {
  const BookSourceReaderPage({
    super.key,
    required this.source,
    required this.book,
    required this.chapters,
    required this.initialIndex,
  });

  final BookSource source;
  final BookSourceBook book;
  final List<BookSourceChapter> chapters;
  final int initialIndex;

  @override
  State<BookSourceReaderPage> createState() => _BookSourceReaderPageState();
}

class _BookSourceReaderPageState extends State<BookSourceReaderPage> {
  final _engine = BookSourceEngine();
  final _scroll = ScrollController();
  final Map<int, String> _contents = {};

  late int _index = _clampedInitialIndex();

  bool _loading = true;
  String? _error;
  int _generation = 0;

  int _clampedInitialIndex() {
    final last = widget.chapters.isEmpty ? 0 : widget.chapters.length - 1;
    final index = widget.initialIndex;
    if (index < 0) return 0;
    return index > last ? last : index;
  }

  BookSourceChapter? get _chapter =>
      widget.chapters.isEmpty ? null : widget.chapters[_index];

  @override
  void initState() {
    super.initState();
    _load(_index, keepScroll: false);
  }

  @override
  void dispose() {
    _engine.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load(int index, {bool keepScroll = true, bool reload = false}) async {
    final chapter = widget.chapters.isEmpty ? null : widget.chapters[index];
    if (chapter == null) {
      setState(() {
        _loading = false;
        _error = '这本书没有目录';
      });
      return;
    }
    final generation = ++_generation;
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
    });
    if (keepScroll && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    final cached = reload ? null : _contents[index];
    if (cached != null) {
      setState(() {
        _loading = false;
      });
      return;
    }
    try {
      final text = await _engine.content(
        widget.source,
        chapter,
        reload: reload,
        referer: Uri.tryParse(widget.book.tocUrl),
      );
      if (!mounted || generation != _generation) return;
      _contents[index] = text;
      setState(() => _loading = false);
    } on BookSourceException catch (exception) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = exception.message;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '这一章加载失败，请重试';
      });
    }
  }

  void _step(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.chapters.length) return;
    _load(next);
  }

  Future<void> _openDirectory() async {
    final palette = HomePalette.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: palette.canvas,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: AppText(
                      '目录',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  GlassIconButton(
                    icon: CupertinoIcons.xmark,
                    label: '关闭',
                    onPressed: () => Navigator.pop(sheetContext),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: widget.chapters.length,
                itemBuilder: (_, index) {
                  final current = index == _index;
                  return JellyTapSurface(
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _load(index);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: AppText(
                        widget.chapters[index].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.4,
                          fontWeight: current
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: current ? palette.accentText : palette.ink,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final chapter = _chapter;
    return SettingsScaffold(
      title: chapter?.title ?? widget.book.name,
      actions: [
        GlassIconButton(
          icon: CupertinoIcons.list_bullet,
          label: '目录',
          onPressed: widget.chapters.isEmpty ? null : _openDirectory,
        ),
      ],
      bottomNavigationBar: _navBar(palette),
      body: _body(palette),
    );
  }

  Widget _body(HomePalette palette) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final message?) {
      return ContentNotice(
        icon: LucideIcons.circle_alert,
        title: '这一章没读出来',
        message: message,
        onRetry: () => _load(_index, reload: true),
      );
    }
    final text = _contents[_index] ?? '';
    final paragraphs = text.split('\n');
    return SelectionArea(
      child: ListView.builder(
        key: const ValueKey('book-source-reader'),
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 72),
        itemCount: paragraphs.length,
        itemBuilder: (context, index) {
          final paragraph = paragraphs[index];
          if (paragraph.isEmpty) return const SizedBox(height: 12);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AppText(
              paragraph,
              style: TextStyle(
                fontSize: 17,
                height: 1.9,
                letterSpacing: 0.2,
                color: palette.ink,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _navBar(HomePalette palette) {
    final hasPrevious = _index > 0;
    final hasNext = _index < widget.chapters.length - 1;
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
              onPressed: hasPrevious ? () => _step(-1) : null,
              child: const Text('上一章'),
            ),
            Expanded(
              child: AppText(
                widget.chapters.isEmpty
                    ? ''
                    : '${_index + 1} / ${widget.chapters.length}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ),
            TextButton(
              onPressed: hasNext ? () => _step(1) : null,
              child: const Text('下一章'),
            ),
          ],
        ),
      ),
    );
  }
}
