// 书源管理页（fqapp 专有功能，上游没有对应页面）。
//
// 版式按产品给定的稿子做：顶部返回 + 居中标题 + 右上「导入 / 导出」；列表
// 先是两条内置书源（番茄 / 书旗，只读，右侧「内置」标记），接着是用户自建
// 书源（开关 + 编辑 + 删除），再是「AI 编写指南」，最后一行规则说明；右下角
// 悬浮「添加书源」。
//
// 交互约定：
// * 点自建书源整行 = 用这个书源去搜书（最常用的动作）；
// * 铅笔 = 改规则，垃圾桶 = 删除，开关 = 是否参与多源搜索；
// * 点内置书源只提示「随包提供、规则不可改」。

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/book_source.dart';
import '../services/book_source_store.dart';
import '../widgets/home/home_design.dart';
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

/// 随包提供的两条书源。规则在 Rust 核心里硬编码，这里只做展示，
/// 不参与 [BookSourceStore]，也不允许编辑。
class _BuiltinSource {
  const _BuiltinSource({
    required this.name,
    required this.baseUrl,
    required this.avatar,
  });

  final String name;
  final String baseUrl;
  final String avatar;
}

const List<_BuiltinSource> _builtinSources = [
  _BuiltinSource(
    name: '番茄小说',
    baseUrl: 'https://fangnovel.com',
    avatar: '番',
  ),
  _BuiltinSource(name: '书旗小说', baseUrl: 'https://www.shuqi.com', avatar: '书'),
];

class _BookSourcesPageState extends State<BookSourcesPage> {
  BookSourceStore get _store => widget.store ?? BookSourceStore.instance;

  bool _loading = true;
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

  Future<void> _searchWith(BookSource source) async {
    if (!source.enabled) {
      _toast('先把这个书源打开，再搜书');
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            BookSourceSearchPage(store: _store, onlySourceId: source.id),
      ),
    );
  }

  Future<void> _toggle(BookSource source, bool enabled) async {
    try {
      await _store.setEnabled(source.id, enabled);
    } catch (_) {
      _toast('保存失败，请重试');
    }
  }

  Future<void> _delete(BookSource source) async {
    final ok = await showSettingsConfirmDialog(
      context: context,
      title: '删除书源',
      message: '删除「${source.name}」？已缓存的正文不受影响。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _store.remove(source.id);
      _toast('已删除「${source.name}」');
    } catch (_) {
      _toast('删除失败，请重试');
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
          child: TextField(
            key: const ValueKey('book-source-import-text'),
            controller: controller,
            autofocus: true,
            minLines: 7,
            maxLines: 12,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: '粘贴书源 JSON（单个对象或数组）',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    try {
      final count = await _store.importJson(text);
      _toast('已导入 $count 个书源');
    } catch (error) {
      _toast('导入失败：${error is FormatException ? error.message : '格式不正确'}');
    }
  }

  Future<void> _export() async {
    if (_store.sources.isEmpty) {
      _toast('还没有自建书源可导出');
      return;
    }
    final json = _store.exportJson();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导出书源'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            child: SelectableText(
              json,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              Clipboard.setData(ClipboardData(text: json));
              Navigator.pop(dialogContext);
              _toast('已复制到剪贴板');
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAiGuide() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: HomePalette.of(context).canvas,
      builder: (sheetContext) => _AiGuideSheet(prompt: _aiPrompt),
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
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _topBar(palette),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : ListView(
                          key: const ValueKey('book-sources-list'),
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                          children: [
                            for (final builtin in _builtinSources) ...[
                              _card(
                                palette,
                                _tile(
                                  palette,
                                  avatar: builtin.avatar,
                                  title: builtin.name,
                                  subtitle: '内置 · ${builtin.baseUrl}',
                                  trailing: _builtinChip(palette),
                                ),
                                onTap: () => _toast('内置书源随包提供，规则不可修改'),
                              ),
                              const SizedBox(height: 10),
                            ],
                            for (final source in _store.sources) ...[
                              _card(
                                palette,
                                _tile(
                                  palette,
                                  avatar: _avatarChar(source.name),
                                  title: source.name,
                                  subtitle: '自建 · ${source.baseUrl}',
                                  trailing: _customActions(palette, source),
                                ),
                                onTap: () => _searchWith(source),
                              ),
                              const SizedBox(height: 10),
                            ],
                            _card(
                              palette,
                              _tile(
                                palette,
                                icon: LucideIcons.sparkles,
                                title: 'AI 编写指南',
                                subtitle: '复制给 AI，让它按格式生成可导入的书源规则',
                                trailing: Icon(
                                  LucideIcons.chevron_right,
                                  size: 18,
                                  color: palette.muted,
                                ),
                              ),
                              onTap: _showAiGuide,
                            ),
                            const SizedBox(height: 16),
                            _ruleHint(palette),
                            if (_store.warning case final warning?) ...[
                              const SizedBox(height: 8),
                              AppText(
                                warning,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.6,
                                  color: palette.accentText,
                                ),
                              ),
                            ],
                            if (_message case final message?) ...[
                              const SizedBox(height: 8),
                              AppText(
                                message,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.6,
                                  color: palette.muted,
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
              ],
            ),
            Positioned(
              right: 20,
              bottom: MediaQuery.paddingOf(context).bottom + 20,
              child: _addButton(palette),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(HomePalette palette) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 2, 6, 2),
    child: Row(
      children: [
        IconButton(
          key: const ValueKey('book-sources-back'),
          tooltip: '返回',
          icon: Icon(LucideIcons.arrow_left, size: 22, color: palette.ink),
          onPressed: () => Navigator.maybePop(context),
        ),
        Expanded(
          child: Center(
            child: AppText(
              '书源管理',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: palette.ink,
              ),
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('book-sources-import'),
          tooltip: '导入书源',
          icon: Icon(LucideIcons.download, size: 20, color: palette.ink),
          onPressed: _import,
        ),
        IconButton(
          key: const ValueKey('book-sources-export'),
          tooltip: '导出书源',
          icon: Icon(
            LucideIcons.square_arrow_out_up_right,
            size: 19,
            color: palette.ink,
          ),
          onPressed: _export,
        ),
      ],
    ),
  );

  Widget _card(HomePalette palette, Widget child, {VoidCallback? onTap}) {
    final container = Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.line, width: 0.6),
      ),
      child: child,
    );
    if (onTap == null) return container;
    return JellyTapSurface(onTap: onTap, child: container);
  }

  Widget _tile(
    HomePalette palette, {
    String? avatar,
    IconData? icon,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
    child: Row(
      children: [
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: palette.soft,
            shape: BoxShape.circle,
          ),
          child: icon != null
              ? Icon(icon, size: 18, color: palette.accentText)
              : AppText(
                  avatar ?? '源',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: palette.accentText,
                  ),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppText(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
              const SizedBox(height: 4),
              AppText(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        trailing,
      ],
    ),
  );

  Widget _builtinChip(HomePalette palette) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: palette.soft,
      borderRadius: BorderRadius.circular(10),
    ),
    child: AppText(
      '内置',
      style: TextStyle(fontSize: 12, color: palette.muted),
    ),
  );

  Widget _customActions(HomePalette palette, BookSource source) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SettingsSwitch(
        value: source.enabled,
        semanticLabel: '${source.name} 启用',
        onChanged: (value) => _toggle(source, value),
      ),
      const SizedBox(width: 2),
      IconButton(
        key: ValueKey('book-source-edit-${source.id}'),
        tooltip: '编辑规则',
        visualDensity: VisualDensity.compact,
        icon: Icon(LucideIcons.pencil, size: 19, color: palette.muted),
        onPressed: () => _openEditor(source),
      ),
      IconButton(
        key: ValueKey('book-source-delete-${source.id}'),
        tooltip: '删除书源',
        visualDensity: VisualDensity.compact,
        icon: Icon(LucideIcons.trash, size: 19, color: palette.muted),
        onPressed: () => _delete(source),
      ),
    ],
  );

  Widget _ruleHint(HomePalette palette) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: AppText(
      '规则说明：css:选择器@text|html|属性；json:data.list；regex:正则；'
      '支持 |trim |abs |lower |upper |stripHtml 后缀。',
      style: TextStyle(fontSize: 11.5, height: 1.7, color: palette.muted),
    ),
  );

  Widget _addButton(HomePalette palette) {
    final background = palette.eink
        ? palette.surface
        : Color.alphaBlend(
            palette.accentText.withValues(alpha: 0.12),
            palette.canvas,
          );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: JellyTapSurface(
        onTap: _openEditor,
        child: Container(
          key: const ValueKey('book-source-add'),
          padding: const EdgeInsets.fromLTRB(18, 12, 20, 12),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: palette.line, width: 0.6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.plus, size: 18, color: palette.accentText),
              const SizedBox(width: 6),
              AppText(
                '添加书源',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: palette.accentText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 头像用的首字：按 rune 取，避免 emoji / 代理对被截成半个字符。
String _avatarChar(String name) {
  for (final rune in name.trim().runes) {
    return String.fromCharCode(rune);
  }
  return '源';
}

/// 「AI 编写指南」弹层：把规则语法交给 AI 时用同一份文本，避免两头口径漂移。
class _AiGuideSheet extends StatelessWidget {
  const _AiGuideSheet({required this.prompt});

  final String prompt;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: AppText(
                    'AI 编写指南',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: palette.ink,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    // 先取 messenger 再 pop：弹层关掉后它的 context 已经失活，
                    // 事后再 ScaffoldMessenger.of(context) 会抛「deactivated widget」。
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    Clipboard.setData(ClipboardData(text: prompt));
                    HapticFeedback.selectionClick();
                    Navigator.pop(context);
                    messenger?.showSnackBar(
                      const SnackBar(content: Text('已复制提示词，粘给 AI 即可')),
                    );
                  },
                  child: const Text('复制'),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: SelectableText(
                prompt,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.7,
                  color: palette.ink,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 给 AI 的提示词：格式与 `BookSourceRules` 一一对应，语法与引擎实现一致。
const String _aiPrompt = '''
你是 fqapp 的自定义书源规则助手。请为站点 SITE_URL 生成一份可直接导入的书源 JSON。

只输出 JSON，不要解释、不要 Markdown 代码围栏。顶层必须是单个对象：

{
  "id": "src_xxx",
  "name": "站点名称",
  "baseUrl": "https://www.example.com",
  "searchUrl": "/search.php?q={{key}}&page={{page}}",
  "enabled": true,
  "headers": {},
  "rules": {
    "searchList": "", "searchName": "", "searchAuthor": "",
    "searchCover": "", "searchIntro": "", "searchBookUrl": "",
    "detailName": "", "detailAuthor": "", "detailCover": "",
    "detailIntro": "", "detailTocUrl": "",
    "tocList": "", "tocName": "", "tocUrl": "",
    "content": ""
  }
}

规则语法：
1. 取值原语（第一个 |> 之前）：
   - css:<选择器>            取第一个命中元素的内文（<br>/块级标签转换行）
   - css:<选择器>@text       同上；@html 取 innerHTML；@outer 取 outerHTML
   - css:<选择器>@任意属性   取属性，如 @href、@src、@content
   - regex:<正则>            在全页文本上匹配，取第一个非空分组
   - json:<点路径>           在 JSON 响应上取值，支持 a.b[0].c
   - 省略前缀的选择器        按 css 处理
2. 加工步骤（用 |> 串联，从左到右）：trim / stripHtml / abs / lower / upper
   - abs 把相对地址补成绝对地址（封面、详情页、章节地址基本都要）
3. 列表规则（searchList、tocList）只认 css: 选择器或 json: 数组路径，
   命中一个元素/一项 = 一条结果；不要给列表规则加 |> 步骤。
4. 单值规则以列表项元素为根求值，所以 css:a 指「这一项里的 a」。
5. URL 模板支持 {{key}}（搜索词，自动 URL 编码）、{{page}}（页码）、{{baseUrl}}；
   以 / 开头的模板按 baseUrl 补全。

硬性要求：
- searchList、searchName、searchBookUrl、tocList、tocName、tocUrl、content 必有值。
- 只支持 UTF-8 站点，页面不能依赖 JavaScript 渲染；不处理「下一页」。
- 需要登录的站点请把 Cookie 写进 headers，格式为 {"Cookie": "a=b; c=d"}。
''';
