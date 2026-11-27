// 自定义书源模型（fqapp 专有功能，上游没有对应实现）。
//
// 一个书源就是「一组 URL 模板 + 一组取值规则」：搜索页、详情页、目录页、
// 正文页各自给一条规则串，[BookSourceRuleEvaluator]（见
// `services/book_source_engine.dart`）负责把规则套到 HTML/JSON 上。
//
// 规则串语法（与 legado 的 `@css:` 前缀兼容，但只实现本项目需要的那一档）：
//
//   取值原语（第一个 `|>` 之前的片段）
//     css:<选择器>            取第一个匹配元素的内文（<br>/块级标签转\n）
//     css:<选择器>@<属性名>   取属性；`@text` 内文、`@html` innerHTML、
//                             `@outer` outerHTML，其余按属性名取
//     regex:<正则>            在全页文本（或当前元素文本）上取第一个非空分组
//     json:<点路径>           在 JSON 响应上取值，支持 `a.b[0].c`
//     <选择器>                没有前缀时按 css 处理
//
//   后续步骤（用 `|>` 串起来的加工步骤）
//     trim        折叠空白：每行去首尾空格、行内连续空白压成一个空格
//     stripHtml   去掉残留标签、解码实体（正文规则常用）
//     abs         相对地址补全成绝对地址（封面、下一章地址常用）
//
// URL 模板支持 `{{key}}`（搜索词）、`{{page}}`（页码，默认 1）、
// `{{baseUrl}}`。以 `/` 开头的模板按站点地址补全；`{{key}}` 会做 URL 编码。
library;

/// 书源存储格式版本。改结构时递增，[BookSourceStore] 会跳过读不懂的旧数据。
const int bookSourceSchemaVersion = 1;

/// 搜索关键字可用的编码。`gbk` 用于「页面 UTF-8、但表单 accept-charset=GBK」的老 CMS。
const String queryEncodingUtf8 = 'utf-8';
const String queryEncodingGbk = 'gbk';

/// 把任意输入归一成受支持的编码名；不认识的一律按 UTF-8 处理。
String normalizeQueryEncoding(Object? value) {
  final text = value is String ? value.trim().toLowerCase() : '';
  return text == queryEncodingGbk ? queryEncodingGbk : queryEncodingUtf8;
}

/// 单个书源可配置的规则集合。
///
/// 字段分成四组，对应书本流转的四个页面；留空的规则表示「沿用上一层的值」
/// 或「这一步不做」，具体见 [BookSourceEngine] 的兜底顺序。
class BookSourceRules {
  const BookSourceRules({
    this.searchList = '',
    this.searchName = '',
    this.searchAuthor = '',
    this.searchCover = '',
    this.searchIntro = '',
    this.searchBookUrl = '',
    this.detailName = '',
    this.detailAuthor = '',
    this.detailCover = '',
    this.detailIntro = '',
    this.detailTocUrl = '',
    this.tocList = '',
    this.tocName = '',
    this.tocUrl = '',
    this.content = '',
  });

  /// 搜索结果列表的容器规则：命中一个元素就是一条搜索结果，
  /// 后面的 `search*` 规则都以该元素为根取值。
  final String searchList;

  final String searchName;
  final String searchAuthor;
  final String searchCover;
  final String searchIntro;

  /// 详情页地址；相对地址会自动按搜索页地址补全。
  final String searchBookUrl;

  final String detailName;
  final String detailAuthor;
  final String detailCover;
  final String detailIntro;

  /// 目录页地址规则。留空或取不到时直接用详情页地址当目录页。
  final String detailTocUrl;

  /// 目录列表容器规则：命中一个元素就是一章节。
  final String tocList;

  final String tocName;

  /// 章节正文页地址；相对地址按目录页地址补全。
  final String tocUrl;

  /// 正文规则。
  final String content;

  static const BookSourceRules empty = BookSourceRules();

  /// 新建书源时的示例值：只作为填写提示，用户改成目标站点的选择器即可。
  static const BookSourceRules example = BookSourceRules(
    searchList: 'css:#booklist li',
    searchName: 'css:.book-name',
    searchAuthor: 'css:.book-author|>stripHtml',
    searchCover: 'css:img@src|>abs',
    searchIntro: 'css:.intro|>stripHtml',
    searchBookUrl: 'css:a@href|>abs',
    detailName: 'css:h1',
    detailAuthor: 'css:.author|>stripHtml',
    detailCover: 'css:.cover img@src|>abs',
    detailIntro: 'css:.intro|>stripHtml',
    detailTocUrl: 'css:a.toc@href|>abs',
    tocList: 'css:#chapterlist li',
    tocName: 'css:a',
    tocUrl: 'css:a@href|>abs',
    content: 'css:#content',
  );

  BookSourceRules copyWith({
    String? searchList,
    String? searchName,
    String? searchAuthor,
    String? searchCover,
    String? searchIntro,
    String? searchBookUrl,
    String? detailName,
    String? detailAuthor,
    String? detailCover,
    String? detailIntro,
    String? detailTocUrl,
    String? tocList,
    String? tocName,
    String? tocUrl,
    String? content,
  }) => BookSourceRules(
    searchList: searchList ?? this.searchList,
    searchName: searchName ?? this.searchName,
    searchAuthor: searchAuthor ?? this.searchAuthor,
    searchCover: searchCover ?? this.searchCover,
    searchIntro: searchIntro ?? this.searchIntro,
    searchBookUrl: searchBookUrl ?? this.searchBookUrl,
    detailName: detailName ?? this.detailName,
    detailAuthor: detailAuthor ?? this.detailAuthor,
    detailCover: detailCover ?? this.detailCover,
    detailIntro: detailIntro ?? this.detailIntro,
    detailTocUrl: detailTocUrl ?? this.detailTocUrl,
    tocList: tocList ?? this.tocList,
    tocName: tocName ?? this.tocName,
    tocUrl: tocUrl ?? this.tocUrl,
    content: content ?? this.content,
  );

  Map<String, dynamic> toJson() => {
    'searchList': searchList,
    'searchName': searchName,
    'searchAuthor': searchAuthor,
    'searchCover': searchCover,
    'searchIntro': searchIntro,
    'searchBookUrl': searchBookUrl,
    'detailName': detailName,
    'detailAuthor': detailAuthor,
    'detailCover': detailCover,
    'detailIntro': detailIntro,
    'detailTocUrl': detailTocUrl,
    'tocList': tocList,
    'tocName': tocName,
    'tocUrl': tocUrl,
    'content': content,
  };

  factory BookSourceRules.fromJson(Map<String, dynamic> json) =>
      BookSourceRules(
        searchList: _string(json['searchList']),
        searchName: _string(json['searchName']),
        searchAuthor: _string(json['searchAuthor']),
        searchCover: _string(json['searchCover']),
        searchIntro: _string(json['searchIntro']),
        searchBookUrl: _string(json['searchBookUrl']),
        detailName: _string(json['detailName']),
        detailAuthor: _string(json['detailAuthor']),
        detailCover: _string(json['detailCover']),
        detailIntro: _string(json['detailIntro']),
        detailTocUrl: _string(json['detailTocUrl']),
        tocList: _string(json['tocList']),
        tocName: _string(json['tocName']),
        tocUrl: _string(json['tocUrl']),
        content: _string(json['content']),
      );
}

/// 一个自定义书源。
class BookSource {
  const BookSource({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.searchUrl = '',
    this.queryEncoding = 'utf-8',
    this.rules = BookSourceRules.empty,
    this.enabled = true,
    this.headers = const {},
  });

  /// 稳定标识，同时作为阅读进度/缓存的命名空间。
  final String id;

  final String name;

  /// 站点根地址，例如 `https://www.example.com`。
  final String baseUrl;

  /// 搜索地址模板，例如 `/search.php?q={{key}}&page={{page}}`。
  final String searchUrl;

  /// 搜索关键字用的编码：`utf-8`（默认）或 `gbk`。
  ///
  /// 老 CMS（第一版主这类）的表单是 `accept-charset="GBK"`，关键字必须按 GBK
  /// 提交才查得到；页面本身通常仍是 UTF-8。
  final String queryEncoding;

  final BookSourceRules rules;

  final bool enabled;

  /// 额外请求头（UA、Cookie、Referer 等）。UA 有内置默认值，这里只写要覆盖的。
  final Map<String, String> headers;

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  static const int maxSources = 50;

  BookSource copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? searchUrl,
    String? queryEncoding,
    BookSourceRules? rules,
    bool? enabled,
    Map<String, String>? headers,
  }) => BookSource(
    id: id ?? this.id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    searchUrl: searchUrl ?? this.searchUrl,
    queryEncoding: queryEncoding ?? this.queryEncoding,
    rules: rules ?? this.rules,
    enabled: enabled ?? this.enabled,
    headers: headers ?? this.headers,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'searchUrl': searchUrl,
    'queryEncoding': queryEncoding,
    'enabled': enabled,
    'headers': headers,
    'rules': rules.toJson(),
  };

  factory BookSource.fromJson(Map<String, dynamic> json) {
    final rules = json['rules'];
    return BookSource(
      id: _string(json['id']),
      name: _string(json['name']),
      baseUrl: _string(json['baseUrl']),
      searchUrl: _string(json['searchUrl']),
      queryEncoding: normalizeQueryEncoding(json['queryEncoding']),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      headers: _headers(json['headers']),
      rules: rules is Map
          ? BookSourceRules.fromJson(Map<String, dynamic>.from(rules))
          : BookSourceRules.empty,
    );
  }

  /// 保存前的校验；返回 null 表示可以保存。
  String? validate() {
    if (name.trim().isEmpty) return '书源名称不能为空';
    if (name.trim().length > 40) return '书源名称最多 40 个字';
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null ||
        !(base.scheme == 'http' || base.scheme == 'https') ||
        base.host.isEmpty) {
      return '站点地址必须是 http(s):// 开头的完整地址';
    }
    if (searchUrl.trim().isEmpty) return '搜索地址不能为空';
    if (normalizeQueryEncoding(queryEncoding) != queryEncoding) {
      return '搜索词编码只能是 utf-8 或 gbk';
    }
    if (rules.searchList.trim().isEmpty) return '搜索结果列表规则不能为空';
    if (rules.searchName.trim().isEmpty) return '搜索结果书名规则不能为空';
    if (rules.searchBookUrl.trim().isEmpty) return '详情页地址规则不能为空';
    if (rules.tocList.trim().isEmpty) return '目录列表规则不能为空';
    if (rules.tocName.trim().isEmpty) return '章节名规则不能为空';
    if (rules.tocUrl.trim().isEmpty) return '章节地址规则不能为空';
    if (rules.content.trim().isEmpty) return '正文规则不能为空';
    return null;
  }

  /// 兼容 legado 书源 JSON 的最小子集：字段名沿用 legado，规则里的
  /// `@css:` 前缀照收，其余前缀（`@XPath:`、`@js:` 等）不支持，
  /// 直接抛 [FormatException] 让用户知道这条导不进来。
  ///
  /// 支持的字段：`bookSourceName` / `bookSourceUrl` / `searchUrl` /
  /// `ruleSearch.{bookList,name,author,coverUrl,intro,bookUrl}` /
  /// `ruleBookInfo.{name,author,coverUrl,intro,tocUrl}` /
  /// `ruleToc.{chapterList,chapterName,chapterUrl}` / `ruleContent.content` /
  /// `header` / `enabled`。
  static BookSource fromLegadoJson(Map<String, dynamic> json) {
    final name = _string(json['bookSourceName'] ?? json['name']);
    final baseUrl = _string(json['bookSourceUrl'] ?? json['baseUrl']).trim();
    if (name.isEmpty || baseUrl.isEmpty) {
      throw const FormatException('书源缺少 bookSourceName 或 bookSourceUrl');
    }
    final ruleSearch = _map(json['ruleSearch']);
    final ruleBookInfo = _map(json['ruleBookInfo']);
    final ruleToc = _map(json['ruleToc']);
    final ruleContent = _map(json['ruleContent']);
    final searchUrl = _string(json['searchUrl']);
    final rules = BookSourceRules(
      searchList: _legadoRule(ruleSearch['bookList']),
      searchName: _legadoRule(ruleSearch['name']),
      searchAuthor: _legadoRule(ruleSearch['author']),
      searchCover: _legadoRule(ruleSearch['coverUrl']),
      searchIntro: _legadoRule(ruleSearch['intro']),
      searchBookUrl: _legadoRule(ruleSearch['bookUrl']),
      detailName: _legadoRule(ruleBookInfo['name']),
      detailAuthor: _legadoRule(ruleBookInfo['author']),
      detailCover: _legadoRule(ruleBookInfo['coverUrl']),
      detailIntro: _legadoRule(ruleBookInfo['intro']),
      detailTocUrl: _legadoRule(ruleBookInfo['tocUrl']),
      tocList: _legadoRule(ruleToc['chapterList']),
      tocName: _legadoRule(ruleToc['chapterName']),
      tocUrl: _legadoRule(ruleToc['chapterUrl']),
      content: _legadoRule(ruleContent['content']),
    );
    final source = BookSource(
      id: _string(json['bookSourceId']).isEmpty
          ? newBookSourceId()
          : _string(json['bookSourceId']),
      name: name,
      baseUrl: baseUrl,
      searchUrl: searchUrl,
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      headers: _headers(json['header']),
      rules: rules,
    );
    return source;
  }
}

/// 一条搜索结果（也可以当作「这本书在某个书源里的引用」）。
class BookSourceSearchItem {
  const BookSourceSearchItem({
    required this.sourceId,
    required this.sourceName,
    required this.name,
    required this.bookUrl,
    this.author,
    this.coverUrl,
    this.intro,
  });

  final String sourceId;
  final String sourceName;
  final String name;
  final String bookUrl;
  final String? author;
  final String? coverUrl;
  final String? intro;

  BookSourceSearchItem copyWith({
    String? name,
    String? author,
    String? coverUrl,
    String? intro,
    String? bookUrl,
  }) => BookSourceSearchItem(
    sourceId: sourceId,
    sourceName: sourceName,
    name: name ?? this.name,
    bookUrl: bookUrl ?? this.bookUrl,
    author: author ?? this.author,
    coverUrl: coverUrl ?? this.coverUrl,
    intro: intro ?? this.intro,
  );
}

/// 详情页解析后的书。
class BookSourceBook {
  const BookSourceBook({
    required this.sourceId,
    required this.sourceName,
    required this.name,
    required this.bookUrl,
    required this.tocUrl,
    this.author,
    this.coverUrl,
    this.intro,
  });

  final String sourceId;
  final String sourceName;
  final String name;
  final String bookUrl;
  final String tocUrl;
  final String? author;
  final String? coverUrl;
  final String? intro;

  BookSourceSearchItem get asSearchItem => BookSourceSearchItem(
    sourceId: sourceId,
    sourceName: sourceName,
    name: name,
    bookUrl: bookUrl,
    author: author,
    coverUrl: coverUrl,
    intro: intro,
  );
}

/// 一章目录项。
class BookSourceChapter {
  const BookSourceChapter({required this.title, required this.url});

  final String title;
  final String url;
}

String newBookSourceId() =>
    'src_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

String _string(Object? value) => value is String ? value : '';

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

Map<String, String> _headers(Object? value) {
  // legado 的 `header` 是一段 "名: 值" 多行文本，本项目的 `headers` 是对象，
  // 两种都收。
  if (value is String) return parseHeaderText(value);
  final raw = _map(value);
  final out = <String, String>{};
  raw.forEach((key, entry) {
    if (entry is String && key.trim().isNotEmpty) {
      out[key.trim()] = entry;
    }
  });
  return out;
}

/// 把 "名: 值" 多行文本解析成请求头。编辑页与 legado 导入共用这一份规则。
Map<String, String> parseHeaderText(String text, {int limit = 16}) {
  final headers = <String, String>{};
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final index = trimmed.indexOf(':');
    if (index <= 0) continue;
    final name = trimmed.substring(0, index).trim();
    final value = trimmed.substring(index + 1).trim();
    if (name.isNotEmpty && value.isNotEmpty && headers.length < limit) {
      headers[name] = value;
    }
  }
  return headers;
}

/// legado 规则 → 本项目规则串。
///
/// legado 用 `@css:` 显式声明 CSS，`@text`/`@href` 这类后缀与本项目的 `@属性`
/// 一致，所以这里只做前缀归一；`&&`、`-`、`@XPath:`、`{{js}}` 等不做转换，
/// 抛 [FormatException]，避免「导入成功但抓不到东西」。
String _legadoRule(Object? value) {
  if (value is! String) return '';
  var rule = value.trim();
  if (rule.isEmpty) return '';
  rule = rule.replaceFirst(RegExp(r'^@css:'), 'css:');
  rule = rule.replaceFirst(RegExp(r'^@text:'), '');
  if (rule.startsWith('@XPath:') ||
      rule.startsWith('@json:') ||
      rule.startsWith('@js:') ||
      rule.contains('&&')) {
    throw FormatException('暂不支持这条 legado 规则：$rule');
  }
  return rule;
}
