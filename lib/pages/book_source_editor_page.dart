// 书源编辑页：一个站点的全部规则都在这里填，附带宽窄够用的「就地测试」。
//
// 表单本身没有魔法：18 个输入框 → [BookSource]，保存前统一走
// [BookSource.validate]。测试按钮用当前填的值真跑一次搜索，把前 5 条结果或
// 引擎给的那句错误原样显示出来——规则写错时用户不必先保存再试。

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/book_source.dart';
import '../services/book_source_engine.dart';
import '../services/book_source_store.dart';
import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_adaptive.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/settings/settings_archive_rows.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/wenku/wenku_ui.dart';

class BookSourceEditorPage extends StatefulWidget {
  const BookSourceEditorPage({super.key, this.source, this.store});

  /// null 表示新建。
  final BookSource? source;

  final BookSourceStore? store;

  @override
  State<BookSourceEditorPage> createState() => _BookSourceEditorPageState();
}

class _BookSourceEditorPageState extends State<BookSourceEditorPage> {
  BookSourceStore get _store => widget.store ?? BookSourceStore.instance;

  final _engine = BookSourceEngine();
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _searchUrl;
  late final TextEditingController _headers;
  final Map<String, TextEditingController> _rules = {};
  final _testKeyword = TextEditingController();

  bool _saving = false;
  bool _testing = false;
  String? _error;
  String? _testError;
  List<BookSourceSearchItem>? _testItems;

  static const List<_RuleField> _searchFields = [
    _RuleField('searchList', '搜索结果列表', '命中一个元素 = 一条结果，例如 css:#booklist li'),
    _RuleField('searchName', '书名', '相对上一条元素取值，例如 css:.name'),
    _RuleField('searchAuthor', '作者', '例如 css:.author|>stripHtml'),
    _RuleField('searchCover', '封面', '例如 css:img@src|>abs'),
    _RuleField('searchIntro', '简介', '例如 css:.intro|>stripHtml'),
    _RuleField('searchBookUrl', '详情页地址', '一般是 css:a@href|>abs，相对地址会自动补全'),
  ];

  static const List<_RuleField> _detailFields = [
    _RuleField('detailName', '书名', '留空沿用搜索结果，例如 css:h1'),
    _RuleField('detailAuthor', '作者', '例如 css:.author'),
    _RuleField('detailCover', '封面', '例如 css:.cover img@src|>abs'),
    _RuleField('detailIntro', '简介', '例如 css:.intro|>stripHtml；可继续用 |> 串更多步骤'),
    _RuleField('detailTocUrl', '目录页地址', '留空则用详情页当目录页，例如 css:a.toc@href|>abs'),
  ];

  static const List<_RuleField> _tocFields = [
    _RuleField('tocList', '章节列表', '命中一个元素 = 一章，例如 css:#list dd'),
    _RuleField('tocName', '章节名', '例如 css:a'),
    _RuleField('tocUrl', '章节地址', '例如 css:a@href|>abs'),
  ];

  static const List<_RuleField> _contentFields = [
    _RuleField(
      'content',
      '正文',
      '取内文时块级标签会转成换行，例如 css:#content 或 css:.read-content',
      lines: 2,
    ),
  ];

  static List<_RuleField> get _allRuleFields => [
    ..._searchFields,
    ..._detailFields,
    ..._tocFields,
    ..._contentFields,
  ];

  @override
  void initState() {
    super.initState();
    final source = widget.source;
    _name = TextEditingController(text: source?.name ?? '');
    _baseUrl = TextEditingController(text: source?.baseUrl ?? '');
    _searchUrl = TextEditingController(
      text: source?.searchUrl ?? '/search.php?q={{key}}',
    );
    _headers = TextEditingController(
      text: source == null
          ? ''
          : [
              for (final entry in source.headers.entries)
                '${entry.key}: ${entry.value}',
            ].join('\n'),
    );
    final rules = source?.rules ?? BookSourceRules.example;
    for (final field in _allRuleFields) {
      _rules[field.key] = TextEditingController(
        text: _ruleValue(rules, field.key),
      );
    }
  }

  @override
  void dispose() {
    _engine.dispose();
    _name.dispose();
    _baseUrl.dispose();
    _searchUrl.dispose();
    _headers.dispose();
    _testKeyword.dispose();
    for (final controller in _rules.values) {
      controller.dispose();
    }
    super.dispose();
  }

  static String _ruleValue(BookSourceRules rules, String key) => switch (key) {
    'searchList' => rules.searchList,
    'searchName' => rules.searchName,
    'searchAuthor' => rules.searchAuthor,
    'searchCover' => rules.searchCover,
    'searchIntro' => rules.searchIntro,
    'searchBookUrl' => rules.searchBookUrl,
    'detailName' => rules.detailName,
    'detailAuthor' => rules.detailAuthor,
    'detailCover' => rules.detailCover,
    'detailIntro' => rules.detailIntro,
    'detailTocUrl' => rules.detailTocUrl,
    'tocList' => rules.tocList,
    'tocName' => rules.tocName,
    'tocUrl' => rules.tocUrl,
    'content' => rules.content,
    _ => '',
  };

  static BookSourceRules _withRule(
    BookSourceRules rules,
    String key,
    String value,
  ) => switch (key) {
    'searchList' => rules.copyWith(searchList: value),
    'searchName' => rules.copyWith(searchName: value),
    'searchAuthor' => rules.copyWith(searchAuthor: value),
    'searchCover' => rules.copyWith(searchCover: value),
    'searchIntro' => rules.copyWith(searchIntro: value),
    'searchBookUrl' => rules.copyWith(searchBookUrl: value),
    'detailName' => rules.copyWith(detailName: value),
    'detailAuthor' => rules.copyWith(detailAuthor: value),
    'detailCover' => rules.copyWith(detailCover: value),
    'detailIntro' => rules.copyWith(detailIntro: value),
    'detailTocUrl' => rules.copyWith(detailTocUrl: value),
    'tocList' => rules.copyWith(tocList: value),
    'tocName' => rules.copyWith(tocName: value),
    'tocUrl' => rules.copyWith(tocUrl: value),
    'content' => rules.copyWith(content: value),
    _ => rules,
  };

  BookSource _compose() {
    var rules = widget.source?.rules ?? BookSourceRules.empty;
    for (final field in _allRuleFields) {
      rules = _withRule(rules, field.key, _rules[field.key]!.text.trim());
    }
    return BookSource(
      id: widget.source?.id ?? newBookSourceId(),
      name: _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      searchUrl: _searchUrl.text.trim(),
      enabled: widget.source?.enabled ?? true,
      headers: parseHeaderText(_headers.text),
      rules: rules,
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    final source = _compose();
    final error = source.validate();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _store.upsert(source);
      if (mounted) Navigator.pop(context);
    } catch (exception) {
      if (mounted) {
        setState(
          () => _error = exception is FormatException
              ? exception.message
              : '保存失败，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final source = widget.source;
    if (source == null) return;
    final ok = await showSettingsConfirmDialog(
      context: context,
      title: '删除书源',
      message: '删除「${source.name}」？',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _store.remove(source.id);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _error = '删除失败，请重试');
    }
  }

  Future<void> _test() async {
    if (_testing) return;
    final source = _compose();
    final error = source.validate();
    if (error != null) {
      setState(() {
        _testError = error;
        _testItems = null;
      });
      return;
    }
    final keyword = _testKeyword.text.trim();
    if (keyword.isEmpty) {
      setState(() {
        _testError = '先填一个测试关键词';
        _testItems = null;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testError = null;
      _testItems = null;
    });
    try {
      final items = await _engine.search(source, keyword);
      if (!mounted) return;
      setState(() {
        if (items.isEmpty) {
          _testError = '没解析出结果：检查「搜索结果列表」「书名」「详情页地址」三条规则';
        } else {
          _testItems = items.take(5).toList(growable: false);
        }
      });
    } on BookSourceException catch (exception) {
      if (mounted) setState(() => _testError = exception.message);
    } catch (_) {
      if (mounted) setState(() => _testError = '测试失败，请检查站点地址与规则');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final classic = AppUiScope.isClassic(context);
    final editing = widget.source != null;
    final children = <Widget>[
      const SettingsHint(
        '规则写法：css:.选择器 内文、css:.选择器@href 取属性、'
        'regex:正则 取第一个分组、json:data.list[0].name 取 JSON 字段；'
        '后面可用 |> 串加工步骤 trim / stripHtml / abs / lower / upper。'
        '地址模板支持 {{key}}、{{page}}、{{baseUrl}}。',
        fontSize: 12.5,
      ),
      const SizedBox(height: 12),
      SettingsCard(
        children: [
          _field(
            key: 'book-source-name',
            controller: _name,
            label: '书源名称',
            help: '显示在搜索结果里的来源名',
          ),
          _field(
            key: 'book-source-base',
            controller: _baseUrl,
            label: '站点地址',
            help: '例如 https://www.example.com',
          ),
          _field(
            key: 'book-source-search-url',
            controller: _searchUrl,
            label: '搜索地址',
            help: '例如 /search.php?q={{key}}&page={{page}}；/ 开头会按站点地址补全',
          ),
        ],
      ),
      const SizedBox(height: 12),
      SettingsSection(title: '搜索规则', code: '01 / SEARCH'),
      const SizedBox(height: 8),
      SettingsCard(children: _fields(_searchFields)),
      const SizedBox(height: 12),
      SettingsSection(title: '详情规则', code: '02 / BOOK'),
      const SizedBox(height: 8),
      SettingsCard(children: _fields(_detailFields)),
      const SizedBox(height: 12),
      SettingsSection(title: '目录规则', code: '03 / TOC'),
      const SizedBox(height: 8),
      SettingsCard(children: _fields(_tocFields)),
      const SizedBox(height: 12),
      SettingsSection(title: '正文规则', code: '04 / CONTENT'),
      const SizedBox(height: 8),
      SettingsCard(children: _fields(_contentFields)),
      const SizedBox(height: 12),
      SettingsSection(title: '请求头', code: '05 / HEADERS'),
      const SizedBox(height: 8),
      SettingsCard(
        children: [
          _field(
            key: 'book-source-headers',
            controller: _headers,
            label: '附加请求头',
            help: '每行一条，例如 Cookie: a=b；最多 16 条',
            lines: 3,
          ),
        ],
      ),
      const SizedBox(height: 12),
      SettingsSection(title: '就地测试', code: '06 / TEST'),
      const SizedBox(height: 8),
      SettingsCard(
        children: [
          _field(
            key: 'book-source-test',
            controller: _testKeyword,
            label: '测试关键词',
            help: '用上面填的规则真搜一次，只显示前 5 条',
          ),
          SettingsActionRow(
            icon: LucideIcons.search,
            title: _testing ? '正在搜索…' : '运行测试',
            onPressed: _testing ? null : _test,
            enabled: !_testing,
          ),
          if (_testError case final message?)
            SettingsCardRow(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: classic
                      ? HomePalette.of(context).accentText
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          if (_testItems case final items?)
            for (final item in items)
              SettingsCardRow(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${item.author ?? '佚名'} · ${item.bookUrl}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: HomePalette.of(context).muted,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
      if (_error case final message?) ...[
        const SizedBox(height: 12),
        SettingsHint(message, emphasis: true),
      ],
      if (editing) ...[
        const SizedBox(height: 12),
        SettingsCard(
          children: [
            SettingsActionRow(
              icon: LucideIcons.trash,
              title: '删除这个书源',
              onPressed: _saving ? null : _delete,
              enabled: !_saving,
            ),
          ],
        ),
      ],
    ];

    return SettingsArchivePage(
      title: editing ? '编辑书源' : '新建书源',
      code: 'SYSTEM / BOOK SOURCE',
      classicBottomBar: classic ? _classicSaveBar() : null,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: classic ? 720 : 860),
              child: ListView(
                key: const ValueKey('book-source-editor'),
                padding: classic
                    ? featurePadding(context)
                    : featurePadding(context).copyWith(
                        bottom: MediaQuery.paddingOf(context).bottom + 120,
                      ),
                children: children,
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
                      key: const ValueKey('book-source-save'),
                      icon: CupertinoIcons.check_mark,
                      label: _saving ? '保存中…' : '保存书源',
                      loading: _saving,
                      onPressed: _saving ? null : _save,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _classicSaveBar() => SafeArea(
    top: false,
    child: Container(
      color: HomePalette.of(context).canvas,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SettingsAction(
        key: const ValueKey('book-source-save'),
        label: _saving ? '保存中…' : '保存书源',
        icon: LucideIcons.check,
        style: SettingsActionStyle.filled,
        expand: true,
        onPressed: _saving ? null : _save,
      ),
    ),
  );

  List<Widget> _fields(List<_RuleField> fields) => [
    for (final field in fields)
      _field(
        key: 'book-source-rule-${field.key}',
        controller: _rules[field.key]!,
        label: field.label,
        help: field.help,
        lines: field.lines,
      ),
  ];

  Widget _field({
    required String key,
    required TextEditingController controller,
    required String label,
    required String help,
    int lines = 1,
  }) => SettingsCardRow(
    child: TextField(
      key: ValueKey(key),
      controller: controller,
      enabled: !_saving,
      minLines: 1,
      maxLines: lines,
      style: const TextStyle(fontSize: 13.5),
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 3,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

class _RuleField {
  const _RuleField(this.key, this.label, this.help, {this.lines = 1});

  final String key;
  final String label;
  final String help;
  final int lines;
}
