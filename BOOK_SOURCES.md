# 自定义书源

fqapp 原本只有两条写死的书源（番茄 / 书旗）。这套功能补上第三条腿：
**用户自己写规则的第三方站点**——搜索、详情、目录、正文全部由一份 JSON 描述，
不经过 Rust 核心，也不改动番茄/书旗的任何链路。

入口：**我的 → 书源管理**。页面按产品稿排版：顶部返回 + 居中标题 + 右上「导入 / 导出」；
列表先是两条内置书源（番茄 / 书旗，右侧「内置」标记，规则随包提供不可改），
接着是自建书源（开关 = 是否参与多源搜索，铅笔 = 改规则，垃圾桶 = 删除），
再是「AI 编写指南」，最后一行规则说明；右下角悬浮「添加书源」。

点自建书源的整行 = **用这个书源搜书**（直接进搜索页，只搜它一条）。

## 目录结构

| 文件 | 作用 |
| --- | --- |
| `lib/models/book_source.dart` | 书源模型、规则字段、校验、legado JSON 子集导入 |
| `lib/services/book_source_engine.dart` | 抓取 + 规则求值（css / regex / json + `\|>` 加工）|
| `lib/services/book_source_store.dart` | `shared_preferences` 持久化、导入导出、增删改 |
| `lib/pages/book_sources_page.dart` | 书源管理（内置源 / 自建源 / AI 指南 / 导入导出）|
| `lib/pages/book_source_editor_page.dart` | 规则编辑 + 就地测试搜索 |
| `lib/pages/book_source_search_page.dart` | 多书源并发搜索（可从管理页锁定单源进来）|
| `lib/pages/book_source_book_page.dart` | 详情 + 目录 |
| `lib/pages/book_source_reader_page.dart` | 正文阅读（上一章 / 下一章 / 目录）|
| `test/book_source_engine_test.dart` | 规则引擎与存储的单测（全离线）|

入口是 `lib/widgets/mine/mine_entries.dart` 里的第一张卡片（我的 → 书源管理）。

## 规则语法

一条规则串 = **取值原语** + 若干 **`|>` 加工步骤**。

### 取值原语

| 写法 | 含义 |
| --- | --- |
| `css:.selector` | 第一个命中元素的**内文**（块级标签与 `<br>` 转成换行）|
| `css:.selector@text` | 同上 |
| `css:.selector@html` | 该元素的 `innerHtml` |
| `css:.selector@outer` | 该元素的 `outerHtml`（含自身标签）|
| `css:.selector@href` | 取属性，属性名不区分大小写 |
| `.selector` | 省略 `css:` 前缀，等同第一条 |
| `regex:模式` | 在整页文本（或当前元素文本）上匹配，取**第一个非空分组**；没有分组取整段匹配 |
| `json:a.b[0].c` | 在 JSON 响应上取值，支持数组下标 |

### 加工步骤（用 `|>` 串联，从左到右）

| 步骤 | 作用 |
| --- | --- |
| `trim`（或 `text`）| 每行去首尾空格、行内连续空白压成一个空格 |
| `stripHtml` | 去掉残留标签并解码实体（简介、作者这类字段常用）|
| `abs` | 相对地址补全成绝对地址（封面、详情页、章节地址常用）|
| `lower` / `upper` | 转小写 / 大写（作者名、标签归一用）|

示例：

```
css:#booklist li            搜索结果的每一项（列表规则）
css:a.name@href|>abs        详情页地址，补成绝对地址
css:.intro|>stripHtml       简介，去标签
json:data.list[0].title     JSON 接口的书名
```

### 列表规则 vs 单值规则

* **列表规则**（搜索结果列表、目录列表）只认 `css:` 选择器或 `json:` 数组路径，
  命中一个元素/一项 = 一条结果；它们不参与 `|>` 加工。
* **单值规则**（书名、作者、封面、地址、正文）以列表项的**元素为根**求值，
  所以 `css:a` 是「这一项里的 a」，不是全页第一个 a。

## URL 模板

`搜索地址`、`目录页地址` 支持占位符：

| 占位符 | 值 |
| --- | --- |
| `{{key}}` | 搜索关键词（自动 URL 编码）|
| `{{page}}` | 页码，目前固定为 `1` |
| `{{baseUrl}}` | 书源的站点地址 |

以 `/` 开头按站点地址补全；不带协议的相对地址同理。

## 一个能直接导入的示例

```json
{
  "schemaVersion": 1,
  "sources": [
    {
      "id": "src_demo",
      "name": "示例站",
      "baseUrl": "https://www.example.com",
      "searchUrl": "/search.php?q={{key}}&page={{page}}",
      "enabled": true,
      "headers": {},
      "rules": {
        "searchList": "css:#booklist li",
        "searchName": "css:.book-name",
        "searchAuthor": "css:.book-author|>stripHtml",
        "searchCover": "css:img@src|>abs",
        "searchIntro": "css:.intro|>stripHtml",
        "searchBookUrl": "css:a@href|>abs",
        "detailName": "css:h1",
        "detailAuthor": "css:.author|>stripHtml",
        "detailCover": "css:.cover img@src|>abs",
        "detailIntro": "css:.intro|>stripHtml",
        "detailTocUrl": "css:a.toc@href|>abs",
        "tocList": "css:#chapterlist li",
        "tocName": "css:a",
        "tocUrl": "css:a@href|>abs",
        "content": "css:#content"
      }
    }
  ]
}
```

新建议书源时编辑器会预填同一组示例值，把它改成目标站点的选择器即可。

## AI 编写指南

管理页的「AI 编写指南」卡片打开一个弹层，里面是给 AI 用的完整提示词（规则语法、
JSON 形状、必填项、硬性限制）。点「复制」后把提示词和站点地址一起粘给 AI，
它输出的 JSON 可以直接从右上「导入」粘回来。

提示词文本在 `lib/pages/book_sources_page.dart` 的 `_aiPrompt` 里，和引擎实现
放在同一个仓库，改语法时记得一起改——两边口径漂移会直接变成「导入成功但抓不到」。

## legado 书源兼容

`导入书源` 接受 legado 书源 JSON 的一个子集：

* 字段：`bookSourceName`、`bookSourceUrl`、`searchUrl`、
  `ruleSearch.{bookList,name,author,coverUrl,intro,bookUrl}`、
  `ruleBookInfo.{name,author,coverUrl,intro,tocUrl}`、
  `ruleToc.{chapterList,chapterName,chapterUrl}`、`ruleContent.content`、
  `header`、`enabled`；
* 规则里 `@css:` 前缀会被翻译成本项目的 `css:`，`@text:` 直接去掉。

**不支持**（遇到会让那条书源导入失败，而不是导入一个抓不到东西的空壳）：
`@XPath:`、`@json:`、`@js:`、`&&` 组合、`{{js ...}}` 表达式、翻页规则。

## 已知边界

* **只支持 UTF-8**：页面声明 GBK/GB2312/GB18030/Big5 时会直接报「编码站点」错误，
  不做乱码猜测。
* **不执行 JS**：纯 HTTP 抓取，前端渲染出来的内容抓不到。
* **单页正文**：不做「下一页」拼接；分页正文的站点只能读到第一页。
* **不带登录态**：需要登录的站点自行在「请求头」里填 Cookie。
* **不进书架**：自定义书源的书不进番茄书架、不做离线缓存、不接朗读；
  正文清洗可以复用已有的「正文替换」规则。
* **有内存缓存**：同一 URL 在一次会话里只抓一次（最近 24 个页面）。

## 验证

```bash
flutter pub get
flutter analyze lib/models/book_source.dart lib/services/book_source_engine.dart \
  lib/services/book_source_store.dart lib/pages/book_source_*.dart \
  lib/pages/book_sources_page.dart
flutter test test/book_source_engine_test.dart
flutter run   # 我的 → 书源管理 → 添加书源 → 填站点地址 → 运行测试
```

调试一条新站点时的顺序建议：

1. 编辑页填站点地址 + 搜索地址，先点「运行测试」确认列表和书名能出来；
2. 再补「详情页地址」「目录列表」「正文」三条，用测试结果里的 URL 手动打开
   对照选择器；
3. 规则写错时引擎只报一句可读原因（超时 / HTTP 状态 / 没解析出结果），
   不会把整页 HTML 贴到界面上。
