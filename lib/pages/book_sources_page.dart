// 自定义书源管理页（fqapp 专有功能，上游没有对应页面）。
//
// 一页管三件事：书源列表（开关 / 编辑 / 删除）、粘贴导入导出、进书源搜索。
// 版式沿用设置类页面的既有骨架（SettingsArchivePage + SettingsCard），
// 经典 / 档案两种风格共用同一棵子树。

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/book_source.dart';
import '../services/book_source_store.dart';
import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_adaptive.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/settings/settings_archive_rows.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/wenku/wenku_ui.dart';
import 'book_source_editor_page.dart';
import 'book_source_search_page.dart';

class BookSourcesPage extends StatefulWidget {
  const BookSourcesPage({super.key, this.store});

  /// 单测可注入独立实例；正常路由用进程内单例。
  final BookSourceStore? store;

  @override
  State<BookSourcesPage> createState() => _BookSourcesPageState();
}

class _BookSourcesPageState extends State<BookSourcesPage> {
  BookSourceStore get _store => widget.store ?? BookSourceStore.instance;

  bool _loading = true;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    _load();
  }

  Future<void> _load() async {
    await _store.load();
    if (mounted) setState(() => _loading = false);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    super.dispose();
  }

  Future<void> _openEditor([BookSource? source]) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => BookSourceEditorPage(source: source, store: _store),
      ),
    );
  }

  Future<void> _toggle(BookSource source, bool enabled) async {
    try {
      await _store.setEnabled(source.id, enabled);
    } catch (error) {
      _toast(error is FormatException ? error.message : '保存失败，请重试');
    }
  }

  Future<void> _import() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入书源'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '粘贴本应用导出的书源 JSON，或 legado 书源 JSON（数组/单个都行）。'
                '只识别 css 规则子集。',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('book-source-import-text'),
                controller: controller,
                minLines: 6,
                maxLines: 12,
                decoration: const InputDecoration(
                  labelText: '书源 JSON',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final count = await _store.importJson(text);
      _toast('已导入 $count 个书源');
    } catch (error) {
      _toast('导入失败：${error is FormatException ? error.message : '格式不正确'}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    if (_store.sources.isEmpty) {
      _toast('还没有书源可导出');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导出书源'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            child: SelectableText(
              _store.exportJson(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    setState(() => _message = message);
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final classic = AppUiScope.isClassic(context);
    final sources = _store.sources;
    final content = <Widget>[
      const SettingsHint(
        '书源就是「网址模板 + 取值规则」。填好一个站点的搜索、目录、正文规则，'
        '就能在应用里直接搜这本书、读它的正文。规则语法见编辑页的说明。',
        fontSize: 12.5,
      ),
      const SizedBox(height: 12),
      SettingsCard(
        children: [
          SettingsLinkRow(
            icon: LucideIcons.search,
            title: '书源搜索',
            subtitle: '用已启用的书源搜书、读正文',
            onTap: _store.enabledSources.isEmpty
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => BookSourceSearchPage(store: _store),
                    ),
                  ),
          ),
          SettingsLinkRow(
            icon: LucideIcons.file_input,
            title: '导入书源',
            subtitle: '粘贴 JSON，支持 legado 书源子集',
            onTap: _busy ? null : _import,
          ),
          SettingsLinkRow(
            icon: LucideIcons.download,
            title: '导出书源',
            subtitle: '复制整包 JSON，换设备时搬走',
            onTap: _export,
          ),
        ],
      ),
      if (_store.warning case final warning?) ...[
        const SizedBox(height: 8),
        SettingsHint(warning, emphasis: true),
      ],
      if (_message case final message?) ...[
        const SizedBox(height: 8),
        SettingsHint(message, emphasis: true),
      ],
      const SizedBox(height: 12),
      if (_loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (sources.isEmpty)
        const SettingsNotice(
          icon: LucideIcons.globe,
          classicIcon: LucideIcons.globe,
          title: '还没有自定义书源',
          message: '点下方「添加书源」，或粘贴一份书源 JSON 导入。',
        )
      else
        SettingsCard(
          children: [
            for (final source in sources)
              SettingsLinkRow(
                key: ValueKey('book-source-${source.id}'),
                icon: LucideIcons.globe,
                title: source.name,
                subtitle: '${source.baseUrl} · ${_rulesSummary(source)}',
                trailing: SettingsSwitch(
                  value: source.enabled,
                  semanticLabel: '${source.name} 启用',
                  onChanged: (value) => _toggle(source, value),
                ),
                onTap: () => _openEditor(source),
              ),
          ],
        ),
      const SizedBox(height: 12),
      if (sources.isNotEmpty)
        SettingsHint(
          '点任意书源可编辑规则或删除；关闭开关只是不参与搜索。',
          fontSize: 12.5,
        ),
    ];

    return SettingsArchivePage(
      title: '自定义书源',
      code: 'SYSTEM / BOOK SOURCES',
      classicBottomBar: classic ? _classicAddBar() : null,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: classic ? 640 : 760),
              child: ListView(
                key: const ValueKey('book-sources-list'),
                padding: classic
                    ? featurePadding(context)
                    : featurePadding(context).copyWith(
                        bottom: MediaQuery.paddingOf(context).bottom + 120,
                      ),
                children: content,
              ),
            ),
          ),
          if (!classic)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: Center(
                    child: GlassPillButton(
                      key: const ValueKey('book-source-add'),
                      icon: CupertinoIcons.add,
                      label: '添加书源',
                      onPressed: _loading || _busy ? null : _openEditor,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _classicAddBar() => SafeArea(
    top: false,
    child: Container(
      color: HomePalette.of(context).canvas,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SettingsAction(
        key: const ValueKey('book-source-add'),
        label: '添加书源',
        icon: LucideIcons.plus,
        style: SettingsActionStyle.filled,
        expand: true,
        onPressed: _loading || _busy ? null : _openEditor,
      ),
    ),
  );

  static String _rulesSummary(BookSource source) {
    final rules = source.rules;
    final filled = [
      rules.searchList,
      rules.tocList,
      rules.content,
    ].where((rule) => rule.trim().isNotEmpty).length;
    return filled == 3 ? '规则已配置' : '还差 ${3 - filled} 组规则';
  }
}
