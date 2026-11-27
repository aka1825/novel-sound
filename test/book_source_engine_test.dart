// 自定义书源的规则引擎与存储测试。
//
// 全部用本地假页面（[_FakeClient]）离线跑：不碰网络、不依赖 Rust 核心，
// 这样规则语法的行为才是可回放的。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/book_source.dart';
import 'package:fqapp/services/book_source_engine.dart';
import 'package:fqapp/services/book_source_store.dart';

const String _searchHtml = '''
<html><body>
<ul id="booklist">
  <li>
    <a class="name" href="/book/1">斗破苍穹</a>
    <span class="author">天蚕土豆</span>
    <img src="/cover/1.jpg">
    <p class="intro">少年<b>萧炎</b>的故事</p>
  </li>
  <li>
    <a class="name" href="/book/2">凡人修仙传</a>
    <span class="author">忘语</span>
    <img src="/cover/2.jpg">
    <p class="intro">一个普通山村少年</p>
  </li>
  <li>
    <a class="name" href="/book/1">斗破苍穹（重复）</a>
    <span class="author">天蚕土豆</span>
  </li>
</ul>
</body></html>
''';

const String _bookHtml = '''
<html><body>
<h1>斗破苍穹</h1>
<div class="author">天蚕土豆</div>
<div class="intro"><p>第一段简介</p><p>第二段简介</p></div>
<a class="toc" href="/book/1/toc">查看目录</a>
</body></html>
''';

const String _tocHtml = '''
<html><body>
<dl id="list">
  <dd><a href="/chapter/1">第一章 陨落的天才</a></dd>
  <dd><a href="/chapter/2">第二章 斗气大陆</a></dd>
</dl>
</body></html>
''';

const String _contentHtml = '''
<html><body>
<div id="content">
  第一段没有味道的段落<br>
  第二段<br><br><br>
  <p>第三段在 p 里</p>
  <script>var x = 1;</script>
</div>
</body></html>
''';

const String _jsonSearchBody = '''
{"data":{"list":[
  {"title":"书甲","author":"作者甲","url":"/book/a","cover":"/cover/a.jpg"},
  {"title":"书乙","author":"作者乙","url":"/book/b"}
]}}
''';

const String _jsonContentBody =
    '{"data":{"chapterName":"第一章","content":"甲段\\n\\n\\n乙段"}}';

BookSource _source({
  String baseUrl = 'https://site.test',
  BookSourceRules? rules,
}) => BookSource(
  id: 'src_test',
  name: '测试源',
  baseUrl: baseUrl,
  searchUrl: '/search?q={{key}}&page={{page}}',
  rules: rules ?? BookSourceRules.example,
);

BookSourceRules _htmlRules() => const BookSourceRules(
  searchList: 'css:#booklist li',
  searchName: 'css:a.name',
  searchAuthor: 'css:.author',
  searchCover: 'css:img@src|>abs',
  searchIntro: 'css:.intro|>stripHtml',
  searchBookUrl: 'css:a.name@href|>abs',
  detailName: 'css:h1',
  detailAuthor: 'css:.author',
  detailIntro: 'css:.intro|>stripHtml',
  detailTocUrl: 'css:a.toc@href|>abs',
  tocList: 'css:#list dd',
  tocName: 'css:a',
  tocUrl: 'css:a@href|>abs',
  content: 'css:#content',
);

class _FakeClient extends http.BaseClient {
  _FakeClient(this.pages, {this.headers = const {}});

  final Map<String, String> pages;
  final Map<String, String> headers;
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final body = pages[request.url.toString()];
    if (body == null) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('missing')),
        404,
        request: request,
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'text/html; charset=utf-8', ...headers},
      request: request,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('规则取值', () {
    final page = BookSourcePage(
      url: Uri.parse('https://site.test/search?q=x'),
      body: _searchHtml,
    );

    test('css 取内文与属性', () {
      final evaluator = BookSourceRuleEvaluator(baseUrl: page.url);
      expect(evaluator.text(page.root, 'css:a.name'), '斗破苍穹');
      expect(evaluator.text(page.root, 'css:a.name@href'), '/book/1');
      expect(evaluator.text(page.root, 'css:img@src'), '/cover/1.jpg');
      // 没有前缀时按 css 处理。
      expect(evaluator.text(page.root, '#booklist li'), isNotNull);
    });

    test('没有 css: 前缀的选择器也能取到', () {
      final evaluator = BookSourceRuleEvaluator(baseUrl: page.url);
      expect(evaluator.text(page.root, '.author'), '天蚕土豆');
    });

    test('|> 步骤 stripHtml 与 abs', () {
      final evaluator = BookSourceRuleEvaluator(baseUrl: page.url);
      expect(
        evaluator.text(page.root, 'css:.intro|>stripHtml'),
        contains('萧炎'),
      );
      expect(
        evaluator.text(page.root, 'css:img@src|>abs'),
        'https://site.test/cover/1.jpg',
      );
    });

    test('|> 步骤 lower / upper', () {
      final evaluator = BookSourceRuleEvaluator(
        baseUrl: Uri.parse('https://site.test/x'),
      );
      expect(evaluator.text(r'AbC-123', r'regex:(\w+-\d+)|>lower'), 'abc-123');
      expect(evaluator.text(r'AbC-123', r'regex:(\w+-\d+)|>upper'), 'ABC-123');
    });

    test('prefix / suffix / tpl 拼地址', () {
      final evaluator = BookSourceRuleEvaluator(
        baseUrl: Uri.parse('https://api.test/x'),
        vars: const {'bookId': '10007988'},
      );
      expect(
        evaluator.text(r'42', r'regex:(\d+)|>prefix:id-|>suffix:/end'),
        'id-42/end',
      );
      expect(
        evaluator.text(
          r'17697840140001',
          r'regex:(\d+)|>tpl:https://www.site.test/shuku/{{bookId}}-{{value}}/',
        ),
        'https://www.site.test/shuku/10007988-17697840140001/',
      );
    });

    test('regex 取第一个非空分组', () {
      final evaluator = BookSourceRuleEvaluator(
        baseUrl: Uri.parse('https://site.test/search'),
      );
      const subject = '书名：斗破苍穹\n作者：天蚕土豆';
      expect(evaluator.text(subject, r'regex:作者：(\S+)'), '天蚕土豆');
    });

    test('json 路径支持数组下标', () {
      final json = BookSourcePage(
        url: Uri.parse('https://json.test/search'),
        body: _jsonSearchBody,
      );
      final evaluator = BookSourceRuleEvaluator(baseUrl: json.url);
      expect(evaluator.text(json.root, 'json:data.list[0].title'), '书甲');
      expect(evaluator.text(json.root, 'json:data.list[1].author'), '作者乙');
      expect(evaluator.text(json.root, 'json:data.list[9].title'), isNull);
    });

    test('块级标签与 br 保留换行', () {
      final content = BookSourcePage(
        url: Uri.parse('https://site.test/chapter/1'),
        body: _contentHtml,
      );
      final evaluator = BookSourceRuleEvaluator(baseUrl: content.url);
      final text = evaluator.text(content.root, 'css:#content');
      expect(text, contains('第一段'));
      expect(text!.split('\n').length >= 3, isTrue);
      expect(text, isNot(contains('var x')));
    });

    test('不认识的步骤会明确报错', () {
      final evaluator = BookSourceRuleEvaluator(baseUrl: page.url);
      expect(
        () => evaluator.text(page.root, 'css:.author|>unknownStep'),
        throwsA(isA<BookSourceException>()),
      );
    });
  });

  group('书源抓取', () {
    test('搜索去重并按元素作用域取值', () async {
      final client = _FakeClient({
        'https://site.test/search?q=%E6%96%97%E7%A0%B4&page=1': _searchHtml,
      });
      final engine = BookSourceEngine(client: client);
      final items = await engine.search(_source(rules: _htmlRules()), '斗破');
      expect(items.length, 2);
      expect(items.first.name, '斗破苍穹');
      expect(items.first.bookUrl, 'https://site.test/book/1');
      expect(items.first.coverUrl, 'https://site.test/cover/1.jpg');
      expect(items.first.author, '天蚕土豆');
      expect(items.first.sourceName, '测试源');
      engine.dispose();
    });

    test('详情 → 目录 → 正文串起来', () async {
      final client = _FakeClient({
        'https://site.test/search?q=%E6%96%97%E7%A0%B4&page=1': _searchHtml,
        'https://site.test/book/1': _bookHtml,
        'https://site.test/book/1/toc': _tocHtml,
        'https://site.test/chapter/1': _contentHtml,
      });
      final source = _source(rules: _htmlRules());
      final engine = BookSourceEngine(client: client);

      final items = await engine.search(source, '斗破');
      final book = await engine.book(source, items.first);
      expect(book.name, '斗破苍穹');
      expect(book.tocUrl, 'https://site.test/book/1/toc');

      final chapters = await engine.chapters(source, book);
      expect(chapters.length, 2);
      expect(chapters.first.title, '第一章 陨落的天才');
      expect(chapters.first.url, 'https://site.test/chapter/1');

      final text = await engine.content(source, chapters.first);
      expect(text, contains('第一段'));
      expect(text, contains('第三段'));
      // 连续空行被折叠，脚本内容不进来。
      expect(text, isNot(contains('\n\n\n')));
      expect(text, isNot(contains('var x')));
      engine.dispose();
    });

    test('JSON 接口书源：列表、字段、正文', () async {
      final rules = const BookSourceRules(
        searchList: 'json:data.list',
        searchName: 'json:title',
        searchAuthor: 'json:author',
        searchCover: 'json:cover|>abs',
        searchBookUrl: 'json:url|>abs',
        content: 'json:data.content',
      );
      final client = _FakeClient({
        'https://api.test/search?q=ab&page=1': _jsonSearchBody,
        'https://api.test/book/a': _jsonContentBody,
      });
      final source = _source(baseUrl: 'https://api.test', rules: rules);
      final engine = BookSourceEngine(client: client);

      final items = await engine.search(source, 'ab');
      expect(items.length, 2);
      expect(items.first.name, '书甲');
      expect(items.first.bookUrl, 'https://api.test/book/a');

      final text = await engine.content(
        source,
        const BookSourceChapter(title: '第一章', url: 'https://api.test/book/a'),
      );
      expect(text, contains('甲段'));
      expect(text, contains('乙段'));
      engine.dispose();
    });

    test('GBK 站点给出明确错误而不是乱码', () async {
      final client = _FakeClient(
        {'https://site.test/search?q=a&page=1': '<html>正文</html>'},
        headers: {'content-type': 'text/html; charset=gbk'},
      );
      final engine = BookSourceEngine(client: client);
      await expectLater(
        engine.search(_source(rules: _htmlRules()), 'a'),
        throwsA(
          isA<BookSourceException>().having(
            (error) => error.message,
            'message',
            contains('GBK'),
          ),
        ),
      );
      engine.dispose();
    });

    test('HTTP 404 转成可读错误', () async {
      final client = _FakeClient({});
      final engine = BookSourceEngine(client: client);
      await expectLater(
        engine.search(_source(rules: _htmlRules()), 'a'),
        throwsA(
          isA<BookSourceException>().having(
            (error) => error.message,
            'message',
            contains('HTTP 404'),
          ),
        ),
      );
      engine.dispose();
    });

    test('模板拼地址与相对补全', () {
      final source = _source(rules: _htmlRules());
      final uri = BookSourceEngine.buildUri(
        '/search?q={{key}}&page={{page}}',
        source,
        {'key': '斗破 苍穹', 'page': '2'},
      );
      expect(uri.host, 'site.test');
      expect(uri.queryParameters['q'], '斗破 苍穹');
      expect(uri.queryParameters['page'], '2');

      final relative = BookSourceEngine.buildUri(
        'search.php?q={{key}}',
        source,
        {'key': 'a'},
      );
      expect(relative.toString(), 'https://site.test/search.php?q=a');

      expect(
        BookSourceEngine.absoluteUrl(
          '/book/9',
          Uri.parse('https://x.test/a/b'),
        ),
        'https://x.test/book/9',
      );
      expect(
        BookSourceEngine.absoluteUrl(
          'javascript:void(0)',
          Uri.parse('https://x.test'),
        ),
        isNull,
      );
    });

    test('取不到正文时抛出可读错误', () async {
      final client = _FakeClient({
        'https://site.test/chapter/9':
            '<html><body><div id="empty"></div></body></html>',
      });
      final engine = BookSourceEngine(client: client);
      await expectLater(
        engine.content(
          _source(rules: _htmlRules()),
          const BookSourceChapter(
            title: '空章',
            url: 'https://site.test/chapter/9',
          ),
        ),
        throwsA(
          isA<BookSourceException>().having(
            (error) => error.message,
            'message',
            contains('没取到正文'),
          ),
        ),
      );
      engine.dispose();
    });
  });

  group('模型与持久化', () {
    test('legado 书源子集能导入成规则', () {
      final source = BookSource.fromLegadoJson({
        'bookSourceName': '某站',
        'bookSourceUrl': 'https://legado.test',
        'searchUrl': '/search?q={{key}}',
        'ruleSearch': {
          'bookList': '@css:#list li',
          'name': '@css:a',
          'bookUrl': '@css:a@href',
        },
        'ruleToc': {
          'chapterList': '@css:#toc dd',
          'chapterName': '@css:a',
          'chapterUrl': '@css:a@href',
        },
        'ruleContent': {'content': '@css:#content'},
        'header': 'Cookie: a=b',
      });
      expect(source.name, '某站');
      expect(source.baseUrl, 'https://legado.test');
      expect(source.rules.searchList, 'css:#list li');
      expect(source.rules.searchBookUrl, 'css:a@href');
      expect(source.rules.content, 'css:#content');
      expect(source.headers['Cookie'], 'a=b');
    });

    test('legado 里不支持的规则整条拒绝', () {
      expect(
        () => BookSource.fromLegadoJson({
          'bookSourceName': 'x',
          'bookSourceUrl': 'https://x.test',
          'ruleSearch': {'bookList': '@XPath://div'},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('校验会挡住明显填错的必填项', () {
      final broken = _source(
        rules: const BookSourceRules(searchList: 'css:li'),
      );
      expect(broken.validate(), isNotNull);
      expect(_source(rules: _htmlRules()).validate(), isNull);
      expect(
        _source(baseUrl: 'ftp://x.test', rules: _htmlRules()).validate(),
        isNotNull,
      );
    });

    test('保存、开关、删除与导出回读', () async {
      SharedPreferences.setMockInitialValues({});
      final store = BookSourceStore();
      await store.load();
      expect(store.sources, isEmpty);

      await store.upsert(_source(rules: _htmlRules()));
      expect(store.sources.length, 1);
      expect(store.enabledSources.length, 1);

      await store.setEnabled('src_test', false);
      expect(store.enabledSources, isEmpty);

      final reloaded = BookSourceStore();
      await reloaded.load();
      expect(reloaded.sources.single.name, '测试源');
      expect(reloaded.sources.single.enabled, isFalse);
      expect(reloaded.exportJson(), contains('测试源'));

      await reloaded.remove('src_test');
      expect(reloaded.sources, isEmpty);
    });

    test('导入支持数组、单对象与导出的整包', () async {
      SharedPreferences.setMockInitialValues({});
      final store = BookSourceStore();
      await store.load();

      final count = await store.importJson(
        jsonEncode([
          {
            'id': 'a1',
            'name': '源一',
            'baseUrl': 'https://a.test',
            'searchUrl': '/s?q={{key}}',
            'rules': _htmlRules().toJson(),
          },
          {
            'bookSourceName': '源二',
            'bookSourceUrl': 'https://b.test',
            'searchUrl': '/s?q={{key}}',
            'ruleSearch': {
              'bookList': '@css:#list li',
              'name': '@css:a',
              'bookUrl': '@css:a@href',
            },
            'ruleToc': {
              'chapterList': '@css:#toc dd',
              'chapterName': '@css:a',
              'chapterUrl': '@css:a@href',
            },
            'ruleContent': {'content': '@css:#content'},
          },
        ]),
      );
      expect(count, 2);
      expect(store.sources.length, 2);

      await expectLater(
        store.importJson('{ not json'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        store.importJson('[{"name":"缺地址"}]'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('接口型书源（七猫式：JSON 搜索/目录 + HTML 正文）', () {
    const searchJson = '''
{"data":{"search_list":[
  {"book_id":"10007988","title":"斗破：破晓","author":"天蚕土豆",
   "image_link":"https://cdn.wtzw.com/cover/1.png","intro":"斗气大陆的故事",
   "read_url":"https://www.qimao.test/shuku/10007988/"}
]}}''';

    const tocJson = '''
{"data":{"chapters":[
  {"id":"17697840140001","title":"第1章 穿越者之一","index":"1"},
  {"id":"17697840140002","title":"第2章 系统的声音","index":"2"}
]}}''';

    const bookHtml = '''
<html><body>
<div class="book-information-txt">
  <span class="s-title">斗破：破晓</span>
  <div class="txt"><span class="s-des">作者：天蚕土豆</span></div>
</div>
</body></html>''';

    const chapterHtml = '''
<html><body>
<div class="chapter-detail-article"><div class="article">
  <p>第一段：我叫萧炎。</p><p>第二段：斗气大陆。</p>
</div></div>
</body></html>''';

    test('搜索 → 详情 → 目录 → 正文全链路', () async {
      final client = _FakeClient({
        'https://api.test/api/search/result?keyword=%E6%96%97%E7%A0%B4&page=1&pageSize=20':
            searchJson,
        'https://www.qimao.test/shuku/10007988/': bookHtml,
        'https://api.test/api/book/chapter-list?book_id=10007988': tocJson,
        'https://www.qimao.test/shuku/10007988-17697840140001/': chapterHtml,
      });
      final source = BookSource(
        id: 'src_qimao',
        name: '七猫小说',
        baseUrl: 'https://api.test',
        searchUrl: '/api/search/result?keyword={{key}}&page=1&pageSize=20',
        rules: const BookSourceRules(
          searchList: 'json:data.search_list',
          searchName: 'json:title',
          searchAuthor: 'json:author',
          searchCover: 'json:image_link',
          searchIntro: 'json:intro',
          searchBookUrl: 'json:read_url',
          detailName: 'css:.book-information-txt .s-title',
          detailTocUrl:
              'tpl:https://api.test/api/book/chapter-list?book_id={{bookId}}',
          tocList: 'json:data.chapters',
          tocName: 'json:title',
          tocUrl: 'tpl:https://www.qimao.test/shuku/{{bookId}}-{{value}}/',
          content: 'css:.chapter-detail-article .article',
        ),
      );
      final engine = BookSourceEngine(client: client);

      final items = await engine.search(source, '斗破');
      expect(items.length, 1);
      expect(items.first.name, '斗破：破晓');
      expect(items.first.bookUrl, 'https://www.qimao.test/shuku/10007988/');

      final book = await engine.book(source, items.first);
      expect(book.name, '斗破：破晓');
      expect(
        book.tocUrl,
        'https://api.test/api/book/chapter-list?book_id=10007988',
      );

      final chapters = await engine.chapters(source, book);
      expect(chapters.length, 2);
      expect(
        chapters.first.url,
        'https://www.qimao.test/shuku/10007988-17697840140001/',
      );

      final text = await engine.content(source, chapters.first);
      expect(text, contains('萧炎'));
      expect(text, contains('斗气大陆'));
      engine.dispose();
    });

    test('bookIdFrom 从书籍地址里抠书号', () {
      expect(
        BookSourceEngine.bookIdFrom('https://www.qimao.test/shuku/10007988/'),
        '10007988',
      );
      expect(BookSourceEngine.bookIdFrom('https://x.test/a/1/b'), '');
    });
  });
}
