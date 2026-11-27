//! 七猫小说（`api-www.qimao.com` / `www.qimao.com`）的上游构造与正文提取。
//!
//! 和书旗不同，七猫这条**不需要签名、也不需要设备注册**：
//!
//! * 搜索、目录是站点公开的 JSON 接口，实测裸 GET 即可（首页 JS 里能读到
//!   `API_BASEURL` 与 `/api/search/result`、`/api/book/chapter-list`）；
//! * 正文在章节页 HTML 里：`.chapter-detail-article .article` 下的一串 `<p>`。
//!
//! 所以这个模块只做三件纯事：拼地址、从 JSON 里挑字段、从 HTML 里抽段落。
//! 网络请求在 [`crate::endpoints::qimao`] 里按 `UpstreamMode::NoSign` 发出。

use regex::Regex;
use std::sync::OnceLock;

/// JSON 接口主机。
pub const API_HOST: &str = "https://api-www.qimao.com";
/// 网页主机（书籍页 / 章节页）。
pub const WEB_HOST: &str = "https://www.qimao.com";
/// 浏览器 UA：接口对 UA 不挑，但带上更稳。
pub const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
                      (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
/// 搜索单页条数。站点实际固定给 15 条，调大无效，保留常量便于以后跟进。
pub const PAGE_SIZE: u32 = 20;
/// 单章最多保留的段落数，防止改版后把整页导航都当正文。
const MAX_PARAGRAPHS: usize = 800;

fn query_encode(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes()).collect()
}

/// 搜索：`/api/search/result?keyword=&page=&pageSize=`。
pub fn search_url(key: &str, page: u32) -> String {
    format!(
        "{API_HOST}/api/search/result?keyword={}&page={}&pageSize={PAGE_SIZE}",
        query_encode(key),
        page.max(1)
    )
}

/// 目录：`/api/book/chapter-list?book_id=`（一次给全，不做分页）。
pub fn toc_url(book_id: &str) -> String {
    format!(
        "{API_HOST}/api/book/chapter-list?book_id={}",
        query_encode(book_id)
    )
}

/// 章节页：`/shuku/<bookId>-<chapterId>/`（格式取自搜索结果的 `latest_chapter_url`）。
pub fn chapter_page_url(book_id: &str, chapter_id: &str) -> String {
    format!("{WEB_HOST}/shuku/{book_id}-{chapter_id}/")
}

/// 书籍页：`/shuku/<bookId>/`。
pub fn book_page_url(book_id: &str) -> String {
    format!("{WEB_HOST}/shuku/{book_id}/")
}

/// 内部书籍地址，和书旗的 `/sqbook/<id>` 对齐，前端据此再解析回 bookId。
pub fn internal_book_url(book_id: &str) -> String {
    format!("/qmbook/{book_id}")
}

/// 内部章节地址。
pub fn internal_chapter_url(book_id: &str, chapter_id: &str) -> String {
    format!("/qmch/{book_id}/{chapter_id}")
}

fn article_marker_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    // 必须把 `article` 当成 class 的第一个 token：写成「包含 article」会先命中
    // 外层容器 `chapter-detail-article font-18`（`article` 后面紧跟 ` font-18"`），
    // 于是导航段的 `<p>上一章</p>` 会混进正文。站点偶尔会追加 `article font-18`
    // 这类后缀，所以允许尾随 token。
    RE.get_or_init(|| Regex::new(r#"class="article(?:\s+[^"]*)?""#).expect("article marker"))
}

fn paragraph_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?s)<p[^>]*>(.*?)</p>").expect("paragraph"))
}

fn tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?s)<[^>]+>").expect("tag"))
}

fn whitespace_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[\s\u{3000}]+").expect("whitespace"))
}

fn numeric_entity_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"&#(x?[0-9A-Fa-f]{1,8});").expect("numeric entity"))
}

fn div_token_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)</?div\b").expect("div token"))
}

/// 取出 `.article` 容器的 HTML 片段（按 `<div>` 深度配平）。
///
/// 只按 `</p>` 扫全页是不够的：章节页的文章容器后面还跟着导航/推荐区，
/// 那里也有 `<p>`，会把「上一章」这类文案混进正文。
fn article_fragment(html: &str) -> Option<&str> {
    let marker = article_marker_regex().find(html)?;
    let tag_end = marker.end() + html[marker.end()..].find('>')? + 1;
    let rest = &html[tag_end..];
    let mut depth = 1usize;
    for token in div_token_regex().find_iter(rest) {
        if rest[token.start()..].starts_with("</") {
            depth -= 1;
            if depth == 0 {
                return Some(&rest[..token.start()]);
            }
        } else {
            depth += 1;
        }
    }
    None
}

/// 章节页正文：取 `.article` 容器里的所有 `<p>`，逐段去标签、压空白、跳过空段。
///
/// 找不到容器时返回空串——调用方据此报「正文没取到」，而不是把整页导航当正文。
pub fn article_text(html: &str) -> String {
    let Some(body) = article_fragment(html) else {
        return String::new();
    };
    let mut out: Vec<String> = Vec::new();
    for caps in paragraph_regex().captures_iter(body) {
        if out.len() >= MAX_PARAGRAPHS {
            break;
        }
        let text = plain(&decode_entities(&strip_tags(&caps[1])));
        if !text.is_empty() {
            out.push(text);
        }
    }
    out.join("\n")
}

/// 去标签（不保留标签内的文本边界，段落级已经由 `<p>` 分开）。
pub fn strip_tags(input: &str) -> String {
    tag_regex().replace_all(input, "").into_owned()
}

/// 解码常见实体：`&nbsp; &amp; &lt; &gt; &quot; &apos; &#39;` 与数字实体。
pub fn decode_entities(input: &str) -> String {
    let replaced = input
        .replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&#39;", "'")
        .replace("&amp;", "&");
    if !replaced.contains("&#") {
        return replaced;
    }
    numeric_entity_regex()
        .replace_all(&replaced, |caps: &regex::Captures<'_>| {
            let raw = &caps[1];
            let parsed = if let Some(hex) = raw.strip_prefix('x').or_else(|| raw.strip_prefix('X'))
            {
                u32::from_str_radix(hex, 16).ok()
            } else {
                raw.parse::<u32>().ok()
            };
            parsed
                .and_then(char::from_u32)
                .map(String::from)
                .unwrap_or_default()
        })
        .into_owned()
}

/// 压空白（含全角空格）成单空格并 trim。
pub fn plain(input: &str) -> String {
    whitespace_regex()
        .replace_all(input, " ")
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const ARTICLE_FIXTURE: &str = r#"
<div class="chapter-detail-wrap-content">
  <div class="chapter-detail-article font-18">
    <div class="article">
      <p>第一段：我叫萧炎。</p>
      <p>第二段：斗气大陆&nbsp;没有魔法。</p>
      <p>  </p>
      <p>第三段：<b>加粗</b>&#39;引号&#39;与&amp;符号。</p>
    </div>
  </div>
  <div class="chapter-detail-nav"><p>上一章</p></div>
</div>
"#;

    #[test]
    fn extracts_paragraphs_and_decodes_entities() {
        let text = article_text(ARTICLE_FIXTURE);
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 3, "空段落应被跳过，导航不应混进来: {text}");
        assert_eq!(lines[0], "第一段：我叫萧炎。");
        assert_eq!(lines[1], "第二段：斗气大陆 没有魔法。");
        assert!(lines[2].contains("加粗"));
        assert!(lines[2].contains("'引号'"));
        assert!(lines[2].contains("&符号"));
        // 文章容器之后的导航区同样带 <p>，必须靠 div 深度配平挡在外面。
        assert!(!text.contains("上一章"), "导航段落混进正文了: {text}");
    }

    #[test]
    fn missing_article_returns_empty() {
        assert!(article_text("<html><body><p>广告</p></body></html>").is_empty());
    }

    #[test]
    fn url_builders_match_the_live_shapes() {
        let search = search_url("斗破 苍穹", 1);
        assert!(search.starts_with("https://api-www.qimao.com/api/search/result?keyword="));
        // 关键词按 form-urlencoded 编码：至少中文必须变成百分号形式。
        assert!(search.contains("%E6%96%97%E7%A0%B4"));
        assert!(search.contains("%E8%8B%8D%E7%A9%B9"));
        assert!(search.ends_with("&page=1&pageSize=20"));
        assert_eq!(
            toc_url("10007988"),
            "https://api-www.qimao.com/api/book/chapter-list?book_id=10007988"
        );
        assert_eq!(
            chapter_page_url("10007988", "17697840140001"),
            "https://www.qimao.com/shuku/10007988-17697840140001/"
        );
        assert_eq!(internal_book_url("42"), "/qmbook/42");
        assert_eq!(internal_chapter_url("42", "7"), "/qmch/42/7");
    }

    #[test]
    fn decodes_numeric_entities() {
        assert_eq!(decode_entities("&#39;x&#x27;"), "'x'");
    }
}
