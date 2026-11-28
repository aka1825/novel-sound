// 自定义书源的规则引擎：抓页面 → 套规则 → 出书/目录/正文。
//
// 这一层刻意不碰 Rust 核心、不碰 [ApiClient]：自定义书源是纯 Dart 的
// 「HTTP + HTML/JSON 提取」，失败也只会影响自己这条书源，不会让主流程
// 的番茄/书旗链路出现新的失败态。
//
// 规则串语法见 `models/book_source.dart` 顶部的说明。这里负责实现它：
// 取值原语 css/regex/json + `|>` 加工步骤 trim/stripHtml/abs。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/book_source.dart';
import 'gbk_codec.dart';

/// 书源链路上的可展示错误。文案直接进 UI，不带原始响应体与签名地址。
class BookSourceException implements Exception {
  const BookSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一次抓取的结果：最终地址 + 原始文本。
///
/// [root] 按内容自动判定成 HTML DOM 或 JSON 对象，规则里的 `json:` 只能作用在
/// JSON 上，`css:` 只能作用在 HTML 上。
class BookSourcePage {
  BookSourcePage({required this.url, required this.body}) : root = _parse(body);

  final Uri url;
  final String body;
  final Object root;

  static Object _parse(String body) {
    final head = body.trimLeft();
    if (head.startsWith('{') || head.startsWith('[')) {
      try {
        return jsonDecode(body) as Object;
      } catch (_) {
        // 不是合法 JSON 就按 HTML 处理，交给 css 规则。
      }
    }
    return html_parser.parse(body);
  }
}

/// 多书源并发搜索的结果：能用的结果 + 每条失败书源的一句话原因。
class BookSourceSearchOutcome {
  const BookSourceSearchOutcome({required this.items, required this.failures});

  final List<BookSourceSearchItem> items;

  /// 形如 `书源名：搜索超时`，直接显示在结果页底部。
  final List<String> failures;
}

const Set<String> _blockTags = {
  'address',
  'article',
  'aside',
  'blockquote',
  'br',
  'dd',
  'div',
  'dl',
  'dt',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hr',
  'li',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'table',
  'tbody',
  'td',
  'th',
  'tr',
  'ul',
};

/// 把规则串套到 HTML/JSON 上。
///
/// [baseUrl] 是当前页面的地址，`abs` 步骤和相对链接补全都以它为基准。
class BookSourceRuleEvaluator {
  const BookSourceRuleEvaluator({this.baseUrl, this.vars = const {}});

  final Uri? baseUrl;

  /// 规则模板里可用的额外变量（目前由引擎注入 `bookId`）。
  final Map<String, String> vars;

  BookSourceRuleEvaluator withBaseUrl(Uri url) =>
      BookSourceRuleEvaluator(baseUrl: url, vars: vars);

  /// 取单值。取不到或取到空串都返回 null，方便调用方写 `?? 兜底`。
  String? text(Object root, String rule) {
    final trimmed = rule.trim();
    if (trimmed.isEmpty) return null;
    final pipeline = trimmed.split('|>');
    final head = pipeline.first.trim();
    // 整条规则就是「拼串步骤」时（`tpl:https://…/{{bookId}}`、`prefix:…`），
    // 没有取值原语：从空串开始，先跑这一段再串后面的步骤。
    final builderOnly = _isBuilderStep(head);
    if (builderOnly && trimmed.contains('{{value}}')) {
      // 典型误写：`tpl:https://x/{{bookId}}-{{value}}/` 少了取值原语，
      // {{value}} 会被替换成空串，所有章节地址都变成同一个残址。
      throw BookSourceException(
        '规则里用了 {{value}}，但前面没有取值原语：先写 json:id / css:… 再 |> tpl:…',
      );
    }
    var current = '';
    if (!builderOnly) {
      final first = _primitive(head, root);
      if (first == null) return null;
      current = first;
    }
    final steps = builderOnly ? pipeline : pipeline.skip(1);
    for (final step in steps) {
      final next = _applyStep(current, step.trim());
      if (next == null) return null;
      current = next;
    }
    final result = current.trim();
    return result.isEmpty ? null : result;
  }

  /// `tpl:` / `prefix:` / `suffix:` 既可以当步骤，也可以单独成一条规则。
  static bool _isBuilderStep(String rule) =>
      rule.startsWith('tpl:') ||
      rule.startsWith('prefix:') ||
      rule.startsWith('suffix:');

  /// 取元素列表，列表规则（搜索结果、目录）用这个。
  ///
  /// 两种列表：`css:` 选择器返回命中的 DOM 元素，`json:` 路径返回数组里的
  /// 每一项（Map/标量都可能）。列表规则不参与 `|>` 加工：一个元素就是一本书
  /// 或一章，加工留给子规则。
  List<Object> elements(Object root, String rule) {
    final trimmed = rule.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.startsWith('json:')) {
      final value = _jsonPath(trimmed.substring('json:'.length).trim(), root);
      if (value is List) {
        final items = <Object>[];
        for (final item in value) {
          if (item != null) items.add(item);
        }
        return items;
      }
      return value == null ? const [] : [value];
    }
    final selector = trimmed.startsWith('css:')
        ? trimmed.substring('css:'.length).trim()
        : trimmed;
    return List<Object>.from(_select(root, selector));
  }

  String? _primitive(String base, Object root) {
    if (base.startsWith('regex:')) {
      final pattern = base.substring('regex:'.length).trim();
      if (pattern.isEmpty) {
        throw const BookSourceException('正则规则为空');
      }
      final RegExp expression;
      try {
        expression = RegExp(pattern, multiLine: true, dotAll: true);
      } on FormatException {
        throw BookSourceException('正则规则写错了：$pattern');
      }
      final match = expression.firstMatch(_subjectText(root));
      if (match == null) return null;
      for (var index = 1; index <= match.groupCount; index++) {
        final group = match.group(index);
        if (group != null && group.trim().isNotEmpty) return group;
      }
      return match.group(0);
    }
    if (base.startsWith('json:')) {
      return _jsonText(_jsonPath(base.substring('json:'.length).trim(), root));
    }
    // 裸 `@href` / `@text`：直接作用在当前节点上。
    // 目录列表常常直接选中 <a> 本身，这时没有选择器可写。
    if (base.startsWith('@')) {
      final element = root;
      if (element is! dom.Element) return null;
      return _valueOf(element, base.substring(1).trim());
    }
    final body = base.startsWith('css:')
        ? base.substring('css:'.length).trim()
        : base;
    final (selector, attribute) = _splitSelector(body);
    final elements = _select(root, selector);
    if (elements.isEmpty) return null;
    return _valueOf(elements.first, attribute);
  }

  List<dom.Element> _select(Object root, String selector) {
    if (selector.trim().isEmpty) return const [];
    try {
      if (root is dom.Element) return root.querySelectorAll(selector);
      if (root is dom.Document) return root.querySelectorAll(selector);
    } on ArgumentError {
      throw BookSourceException('CSS 选择器写错了：$selector');
    } on FormatException {
      throw BookSourceException('CSS 选择器写错了：$selector');
    } on UnimplementedError {
      // csslib 对伪类/伪元素支持不全（例如把 URL 当成选择器时会报 `:https`）。
      throw BookSourceException('CSS 选择器不受支持：$selector');
    }
    return const [];
  }

  String? _valueOf(dom.Element element, String? attribute) {
    if (attribute == null || attribute.isEmpty) return innerText(element);
    switch (attribute.toLowerCase()) {
      case 'text':
        return innerText(element);
      case 'html':
        return element.innerHtml;
      case 'outer':
        return element.outerHtml;
    }
    final key = attribute.toLowerCase();
    final direct = element.attributes[key];
    if (direct != null) return direct;
    // html 包的 attributes 是 LinkedHashMap<Object, String>，键不一定是 String。
    for (final entry in element.attributes.entries) {
      if (entry.key.toString().toLowerCase() == key) return entry.value;
    }
    return null;
  }

  String? _applyStep(String value, String step) {
    // 带参数的步骤先看前缀：它们是 URL 拼装的关键（章节地址常常要拿 id 拼）。
    if (step.startsWith('prefix:')) return step.substring(7) + value;
    if (step.startsWith('suffix:')) return value + step.substring(7);
    if (step.startsWith('tpl:')) {
      var out = step.substring(4).replaceAll('{{value}}', value);
      vars.forEach((name, replacement) {
        out = out.replaceAll('{{$name}}', replacement);
      });
      return out;
    }
    if (step == 'b64') {
      // 42zw 这类站把正文切成几十段塞进 `document.writeln(qsbs.bb('...'))`：
      // 要把所有引号里的 base64 依次解码拼起来，再按 HTML 取内文。
      final decoded = _decodeBase64Chunks(value);
      if (decoded == null) return null;
      if (decoded.contains('<')) {
        return innerText(html_parser.parseFragment(decoded));
      }
      return decoded;
    }
    switch (step) {
      case 'trim':
      case 'text':
        return collapseWhitespace(value);
      case 'stripHtml':
        return collapseWhitespace(innerText(html_parser.parseFragment(value)));
      case 'lower':
        return value.toLowerCase();
      case 'upper':
        return value.toUpperCase();
      case 'abs':
        final base = baseUrl;
        if (base == null) return value;
        return BookSourceEngine.absoluteUrl(value, base) ?? value;
      case '':
        return value;
      default:
        throw BookSourceException('不认识的规则步骤：$step');
    }
  }

  (String, String?) _splitSelector(String body) {
    final index = body.lastIndexOf('@');
    if (index <= 0) return (body.trim(), null);
    final attribute = body.substring(index + 1).trim();
    if (attribute.isEmpty || attribute.contains(RegExp(r'[\s>+~\[\]()]'))) {
      return (body.trim(), null);
    }
    return (body.substring(0, index).trim(), attribute);
  }

  String _subjectText(Object root) {
    if (root is String) return root;
    if (root is dom.Element) return innerText(root);
    if (root is dom.Document) {
      final body = root.body;
      return innerText(body ?? root.documentElement ?? root);
    }
    return jsonEncode(root);
  }
}

/// 取元素内文：`<br>` 与块级标签转成换行，`script/style` 直接丢掉。
///
/// 不直接用 `element.text`：那个会把换行一起折叠掉，正文段落就读不出来了。
String innerText(dom.Node node) {
  final buffer = StringBuffer();
  for (final child in node.nodes) {
    if (child is dom.Text) {
      buffer.write(child.data);
      continue;
    }
    if (child is! dom.Element) {
      buffer.write(innerText(child));
      continue;
    }
    final tag = child.localName?.toLowerCase() ?? '';
    if (tag == 'script' || tag == 'style' || tag == 'noscript') continue;
    if (tag == 'br') {
      buffer.write('\n');
      continue;
    }
    final block = _blockTags.contains(tag);
    if (block) buffer.write('\n');
    buffer.write(innerText(child));
    if (block) buffer.write('\n');
  }
  return buffer.toString();
}

/// 折叠空白：每行去首尾空格、行内连续空白压成一个空格。
String collapseWhitespace(String value) {
  final lines = value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final out = <String>[];
  for (final line in lines) {
    final cleaned = line.replaceAll(RegExp(r'[ \t\u00a0\u3000]+'), ' ').trim();
    out.add(cleaned);
  }
  return out.join('\n').trim();
}

/// 正文规整：逐行 trim、连续空行压成一个、去掉只有空白的行。
String normalizeChapterContent(String raw) {
  final lines = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final out = <String>[];
  var blank = true;
  for (final line in lines) {
    final cleaned = line.replaceAll(RegExp(r'[ \t\u00a0\u3000]+'), ' ').trim();
    if (cleaned.isEmpty) {
      if (blank) continue;
      blank = true;
      out.add('');
      continue;
    }
    blank = false;
    out.add(cleaned);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}

/// 抓取 + 解析一条龙。
///
/// [client] 可注入，单测里用假的 [http.Client] 或本地桩页面；
/// 引擎内部对同一 URL 有一次内存缓存，翻回上一章不会重新抓。
class BookSourceEngine {
  BookSourceEngine({http.Client? client, this.cacheSize = 24})
    : _client = client ?? http.Client(),
      _cache = LinkedHashMap<String, BookSourcePage>();

  static const Duration defaultTimeout = Duration(seconds: 20);
  static const int maxBodyBytes = 4 * 1024 * 1024;

  final http.Client _client;
  final LinkedHashMap<String, BookSourcePage> _cache;

  /// 页面缓存条数上限。
  final int cacheSize;

  BookSourceRuleEvaluator evaluatorFor(
    Uri url, {
    Map<String, String> vars = const {},
  }) => BookSourceRuleEvaluator(baseUrl: url, vars: vars);

  /// 从书籍地址里取书号（第一段 3 位以上的数字）。
  ///
  /// 章节地址常常是 `/<书号>-<章节号>/` 这种形状，而目录接口只给章节号，
  /// 所以规则里的 `{{bookId}}` 需要引擎把书号从 bookUrl 里抠出来。
  static String bookIdFrom(String url) {
    final uri = Uri.tryParse(url);
    final path = uri?.path ?? url;
    final match = RegExp(r'(\d{3,})').firstMatch(path);
    return match?.group(1) ?? '';
  }

  /// 抓一个地址。返回的 [BookSourcePage.url] 是跟过重定向之后的最终地址。
  ///
  /// [formBody] 非空时改用 POST（wenku8 这类站的搜索是表单提交）。
  Future<BookSourcePage> get(
    Uri url, {
    required BookSource source,
    Uri? referer,
    bool useCache = true,
    String? formBody,
  }) async {
    if (url.scheme != 'http' && url.scheme != 'https') {
      throw BookSourceException('只支持 http/https 地址：$url');
    }
    final key = formBody == null ? url.toString() : '$url#post:$formBody';
    if (useCache) {
      final cached = _cache.remove(key);
      if (cached != null) {
        _cache[key] = cached;
        return cached;
      }
    }
    final headers = <String, String>{
      'user-agent': BookSource.defaultUserAgent,
      'accept':
          'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
      'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
      if (referer != null) 'referer': referer.toString(),
      ...source.headers,
    };
    final http.Response response;
    try {
      if (formBody == null) {
        response = await _client
            .get(url, headers: headers)
            .timeout(defaultTimeout);
      } else {
        response = await _client
            .post(
              url,
              headers: {
                ...headers,
                'content-type': 'application/x-www-form-urlencoded',
              },
              body: formBody,
            )
            .timeout(defaultTimeout);
      }
    } on TimeoutException {
      throw BookSourceException('「${source.name}」请求超时');
    } on http.ClientException {
      throw BookSourceException('「${source.name}」网络请求失败，请检查站点地址');
    } on ArgumentError {
      throw BookSourceException('「${source.name}」请求地址不合法');
    }
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw BookSourceException(
        '「${source.name}」返回 HTTP ${response.statusCode}',
      );
    }
    final bytes = response.bodyBytes;
    if (bytes.length > maxBodyBytes) {
      throw BookSourceException('「${source.name}」页面超过 4MB，已跳过');
    }
    final page = BookSourcePage(
      url: response.request?.url ?? url,
      body: decodePageBytes(bytes, response.headers, source),
    );
    if (useCache) {
      _cache[page.url.toString()] = page;
      _cache[key] = page;
      while (_cache.length > cacheSize) {
        _cache.remove(_cache.keys.first);
      }
    }
    return page;
  }

  /// 按页面声明的编码解码：UTF-8 / GBK（GB2312、GB18030 走同一张表）。
  ///
  /// Big5 仍然明确报错——没有对应码表，宁可说清楚也不吐乱码。
  static String decodePageBytes(
    List<int> bytes,
    Map<String, String> headers,
    BookSource source,
  ) {
    final declared = <String>[];
    final contentType = headers['content-type'] ?? '';
    final headerMatch = RegExp(
      r'charset\s*=\s*"?([\w-]+)',
      caseSensitive: false,
    ).firstMatch(contentType);
    if (headerMatch != null) declared.add(headerMatch.group(1)!.toLowerCase());
    // meta 前缀按 latin1 读，避免用错误的编码去猜编码。
    final probe = String.fromCharCodes(bytes.take(2048)).toLowerCase();
    final metaMatch = RegExp(
      r'''charset\s*=\s*["']?\s*([\w-]+)''',
      caseSensitive: false,
    ).firstMatch(probe);
    if (metaMatch != null) declared.add(metaMatch.group(1)!.toLowerCase());

    if (declared.any(
      (value) => value == 'gbk' || value == 'gb2312' || value == 'gb18030',
    )) {
      return decodeGbk(bytes);
    }
    if (declared.any((value) => value == 'big5' || value == 'big5-hkscs')) {
      throw BookSourceException('「${source.name}」是 Big5 编码站点，暂不支持');
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 搜索。返回该书的引用列表，地址已补全成绝对地址。
  Future<List<BookSourceSearchItem>> search(
    BookSource source,
    String keyword,
  ) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return const [];
    final variables = {'key': trimmed, 'page': '1'};
    final uri = buildUri(source.searchUrl, source, variables);
    // POST 搜索（wenku8 的 /so.php、很多笔趣阁克隆）：地址照旧拼，参数走表单体。
    final formBody = source.searchMethod == 'post'
        ? buildFormBody(source.searchBody, source, variables)
        : null;
    final page = await get(uri, source: source, formBody: formBody);
    final evaluator = evaluatorFor(page.url);
    final nodes = evaluator.elements(page.root, source.rules.searchList);
    final items = <BookSourceSearchItem>[];
    final seen = <String>{};
    for (final node in nodes) {
      final name = evaluator.text(node, source.rules.searchName);
      if (name == null) continue;
      final rawBookUrl = evaluator.text(node, source.rules.searchBookUrl);
      final bookUrl = absoluteUrl(rawBookUrl, page.url);
      if (bookUrl == null) continue;
      if (!seen.add(bookUrl)) continue;
      items.add(
        BookSourceSearchItem(
          sourceId: source.id,
          sourceName: source.name,
          name: name,
          bookUrl: bookUrl,
          author: evaluator.text(node, source.rules.searchAuthor),
          coverUrl: absoluteUrl(
            evaluator.text(node, source.rules.searchCover),
            page.url,
          ),
          intro: evaluator.text(node, source.rules.searchIntro),
        ),
      );
      if (items.length >= 200) break;
    }
    return items;
  }

  /// 并发搜索多条书源。单条失败不影响其它书源。
  Future<BookSourceSearchOutcome> searchAll(
    List<BookSource> sources,
    String keyword,
  ) async {
    final enabled = sources.where((source) => source.enabled).toList();
    if (enabled.isEmpty) {
      return const BookSourceSearchOutcome(items: [], failures: []);
    }
    final failures = <String>[];
    final batches = await Future.wait([
      for (final source in enabled)
        search(source, keyword).then<List<BookSourceSearchItem>>(
          (items) => items,
          onError: (Object error) {
            failures.add(
              '${source.name}：${error is BookSourceException ? error.message : '搜索失败'}',
            );
            return const <BookSourceSearchItem>[];
          },
        ),
    ]);
    return BookSourceSearchOutcome(
      items: [for (final batch in batches) ...batch],
      failures: failures,
    );
  }

  /// 详情页 + 目录页地址。详情规则留空的字段沿用搜索结果里的值。
  Future<BookSourceBook> book(
    BookSource source,
    BookSourceSearchItem item, {
    bool reload = false,
  }) async {
    final page = await get(
      Uri.parse(item.bookUrl),
      source: source,
      useCache: !reload,
    );
    final evaluator = evaluatorFor(
      page.url,
      vars: {'bookId': bookIdFrom(page.url.toString())},
    );
    final rules = source.rules;
    final tocUrl =
        absoluteUrl(evaluator.text(page.root, rules.detailTocUrl), page.url) ??
        page.url.toString();
    return BookSourceBook(
      sourceId: source.id,
      sourceName: source.name,
      name: evaluator.text(page.root, rules.detailName) ?? item.name,
      bookUrl: page.url.toString(),
      tocUrl: tocUrl,
      author: evaluator.text(page.root, rules.detailAuthor) ?? item.author,
      coverUrl:
          absoluteUrl(evaluator.text(page.root, rules.detailCover), page.url) ??
          item.coverUrl,
      intro: evaluator.text(page.root, rules.detailIntro) ?? item.intro,
    );
  }

  /// 目录。
  Future<List<BookSourceChapter>> chapters(
    BookSource source,
    BookSourceBook book, {
    bool reload = false,
  }) async {
    final page = await get(
      Uri.parse(book.tocUrl),
      source: source,
      referer: Uri.tryParse(book.bookUrl),
      useCache: !reload,
    );
    final evaluator = evaluatorFor(
      page.url,
      vars: {'bookId': bookIdFrom(book.bookUrl)},
    );
    final rules = source.rules;
    final nodes = evaluator.elements(page.root, rules.tocList);
    final chapters = <BookSourceChapter>[];
    final seen = <String>{};
    for (final node in nodes) {
      final title = evaluator.text(node, rules.tocName);
      final url = absoluteUrl(evaluator.text(node, rules.tocUrl), page.url);
      if (title == null || url == null) continue;
      if (!seen.add(url)) continue;
      chapters.add(BookSourceChapter(title: title, url: url));
    }
    if (chapters.isEmpty) {
      throw BookSourceException('「${source.name}」没有解析出目录，检查目录规则');
    }
    return chapters;
  }

  /// 正文。
  Future<String> content(
    BookSource source,
    BookSourceChapter chapter, {
    bool reload = false,
    Uri? referer,
  }) async {
    final page = await get(
      Uri.parse(chapter.url),
      source: source,
      referer: referer,
      useCache: !reload,
    );
    final evaluator = evaluatorFor(page.url);
    final raw = evaluator.text(page.root, source.rules.content);
    final text = raw == null ? '' : normalizeChapterContent(raw);
    if (text.trim().isEmpty) {
      throw BookSourceException('「${source.name}」没取到正文，检查正文规则');
    }
    return text;
  }

  /// 拼 POST 表单体（`s={{key}}&type=articlename` 这种模板）。
  ///
  /// 编码规则与 [buildUri] 一致：`queryEncoding=gbk` 时关键字按 GBK 百分号编码。
  static String buildFormBody(
    String template,
    BookSource source,
    Map<String, String> variables,
  ) {
    final trimmed = template.trim();
    if (trimmed.isEmpty) {
      throw BookSourceException('「${source.name}」是 POST 搜索，但没有配置表单模板');
    }
    var text = trimmed;
    final gbkQuery = source.queryEncoding == queryEncodingGbk;
    variables.forEach((name, value) {
      final encoded = name == 'key' && gbkQuery
          ? encodeGbkQueryComponent(value)
          : Uri.encodeQueryComponent(value);
      text = text.replaceAll('{{$name}}', encoded);
    });
    return text;
  }

  /// 用模板拼出请求地址。
  ///
  /// 支持 `{{key}}`、`{{page}}`、`{{baseUrl}}`；`/` 开头的模板按站点地址补全。
  static Uri buildUri(
    String template,
    BookSource source,
    Map<String, String> variables,
  ) {
    final trimmed = template.trim();
    if (trimmed.isEmpty) {
      throw BookSourceException('「${source.name}」没有配置搜索地址');
    }
    var text = trimmed.replaceAll('{{baseUrl}}', source.baseUrl.trim());
    final gbkQuery = source.queryEncoding == queryEncodingGbk;
    variables.forEach((name, value) {
      // 老 CMS 的表单是 accept-charset=GBK：关键字得按 GBK 编码提交，
      // 否则服务端按 GBK 解码 UTF-8 字节，永远查不到结果。
      final encoded = name == 'key' && gbkQuery
          ? encodeGbkQueryComponent(value)
          : Uri.encodeQueryComponent(value);
      text = text.replaceAll('{{$name}}', encoded);
    });
    final base = Uri.tryParse(source.baseUrl.trim());
    if (base == null) {
      throw BookSourceException('「${source.name}」站点地址不合法');
    }
    final uri = base.resolve(text);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw BookSourceException('「${source.name}」搜索地址协议不受支持');
    }
    return uri;
  }

  /// 相对地址补全；空值返回 null，无法解析的原样返回。
  static String? absoluteUrl(String? raw, Uri base) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final direct = Uri.tryParse(trimmed);
    if (direct != null &&
        (direct.scheme == 'http' || direct.scheme == 'https')) {
      return direct.toString();
    }
    if (trimmed.startsWith('javascript:') || trimmed.startsWith('#')) {
      return null;
    }
    try {
      return base.resolve(trimmed).toString();
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  void dispose() {
    _cache.clear();
    _client.close();
  }
}

Object? _jsonPath(String path, Object root) {
  if (path.isEmpty) return root;
  Object? current = root;
  for (final rawSegment in path.split('.')) {
    var segment = rawSegment.trim();
    if (segment.isEmpty) continue;
    while (segment.isNotEmpty) {
      final bracket = segment.indexOf('[');
      if (bracket < 0) break;
      final key = segment.substring(0, bracket).trim();
      if (key.isNotEmpty) current = _jsonField(current, key);
      final closing = segment.indexOf(']', bracket);
      if (closing < 0) break;
      final indexText = segment.substring(bracket + 1, closing).trim();
      final index = int.tryParse(indexText);
      if (index != null && current is List) {
        current = index >= 0 && index < current.length ? current[index] : null;
      }
      segment = segment.substring(closing + 1);
    }
    if (segment.isNotEmpty) current = _jsonField(current, segment);
    if (current == null) return null;
  }
  return current;
}

Object? _jsonField(Object? current, String key) {
  if (current is Map) return current[key];
  return null;
}

String? _jsonText(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return jsonEncode(value);
}

/// 把脚本片段里所有引号包裹的 base64 依次解码并拼接（正文常被切成几十段）。
///
/// 没有任何引号载荷时，把整串（去空白）当 base64 试一次。
String? _decodeBase64Chunks(String value) {
  final payloads = RegExp(
    r"""['"]([A-Za-z0-9+/=]{16,})['"]""",
  ).allMatches(value).map((match) => match.group(1)!).toList();
  if (payloads.isEmpty) {
    final trimmed = value.replaceAll(RegExp(r'\s+'), '');
    if (trimmed.length >= 16 &&
        RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(trimmed)) {
      payloads.add(trimmed);
    }
  }
  if (payloads.isEmpty) return null;
  final buffer = StringBuffer();
  for (final payload in payloads) {
    try {
      buffer.write(utf8.decode(base64Decode(payload), allowMalformed: true));
    } on FormatException {
      continue;
    }
  }
  return buffer.isEmpty ? null : buffer.toString();
}
