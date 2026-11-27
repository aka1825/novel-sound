//! 七猫接口的公共取值、参数解析与上游调用。

use regex::Regex;
use serde_json::{Map, Value};
use std::sync::OnceLock;

use crate::endpoints::base::{Upstream, UpstreamMode, UpstreamRequestSpec};
use crate::endpoints::{Ctx, Params};
use crate::error::{ApiError, ApiResult};
use crate::upstream::qimao as proto;

/// 内部书籍地址 `/qmbook/<id>`。
fn internal_book_url_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"/qmbook/(\d+)").expect("book url regex"))
}

/// 站点书籍页 `/shuku/<id>/`（也接受 `<id>-<chapterId>` 形式）。
fn site_book_url_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"/shuku/(\d+)(?:-\d+)?/").expect("site book url regex"))
}

/// query 里的 `book_id=34078` / `bookId=34078`。
fn book_id_query_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[?&]book_?[Ii]d=(\d+)").expect("book id query regex"))
}

/// 内部章节地址 `/qmch/<bookId>/<chapterId>`。
fn internal_chapter_url_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"/qmch/(\d+)/(\d+)").expect("chapter url regex"))
}

/// 站点章节页 `/shuku/<bookId>-<chapterId>/`。
fn site_chapter_url_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"/shuku/(\d+)-(\d+)/").expect("site chapter url regex"))
}

pub(super) fn pick(params: &Params, names: &[&str]) -> String {
    for name in names {
        let value = params.get_str(name);
        if !value.is_empty() {
            return value;
        }
    }
    String::new()
}

/// 从内部地址、站点地址或 query 里解析书号。
pub(super) fn resolve_book_id(params: &Params) -> ApiResult<String> {
    let raw = pick(params, &["book_id", "bookId", "bid", "url"]);
    if raw.is_empty() {
        return Err(ApiError::BadRequest("missing book_id parameter".into()));
    }
    if raw.chars().all(|c| c.is_ascii_digit()) {
        return Ok(raw);
    }
    if let Some(caps) = internal_book_url_regex().captures(&raw) {
        return Ok(caps[1].to_string());
    }
    if let Some(caps) = site_book_url_regex().captures(&raw) {
        return Ok(caps[1].to_string());
    }
    if let Some(caps) = book_id_query_regex().captures(&raw) {
        return Ok(caps[1].to_string());
    }
    Err(ApiError::BadRequest(format!(
        "cannot resolve book_id from {raw}"
    )))
}

/// 从内部地址、站点地址或 query 里解析章节号。
pub(super) fn resolve_chapter_id(params: &Params) -> ApiResult<String> {
    let raw = pick(params, &["chapter_id", "chapterId", "cid", "url"]);
    if raw.is_empty() {
        return Err(ApiError::BadRequest("missing chapter_id parameter".into()));
    }
    if raw.chars().all(|c| c.is_ascii_digit()) {
        return Ok(raw);
    }
    if let Some(caps) = internal_chapter_url_regex().captures(&raw) {
        return Ok(caps[2].to_string());
    }
    if let Some(caps) = site_chapter_url_regex().captures(&raw) {
        return Ok(caps[2].to_string());
    }
    Err(ApiError::BadRequest(format!(
        "cannot resolve chapter_id from {raw}"
    )))
}

/// 免签 GET：七猫的接口不需要签名，`NoSign` 下上游层不注入任何风控头。
pub(super) async fn get_text(
    ctx: &Ctx,
    url: &str,
    headers: Vec<(String, String)>,
) -> ApiResult<String> {
    let spec = UpstreamRequestSpec {
        mode: UpstreamMode::NoSign,
        method: Some("GET".to_string()),
        raw_url: Some(url.to_string()),
        headers,
        ..Default::default()
    };
    let raw = Upstream::new(ctx.up.clone()).raw(&spec).await?;
    Ok(String::from_utf8_lossy(&raw).into_owned())
}

pub(super) fn browser_headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), proto::UA.to_string()),
        ("Accept-Language".to_string(), "zh-CN,zh;q=0.9".to_string()),
        ("Referer".to_string(), format!("{}/", proto::WEB_HOST)),
    ]
}

pub(super) fn text_of(map: &Map<String, Value>, keys: &[&str]) -> String {
    for key in keys {
        match map.get(*key) {
            Some(Value::String(s)) => return s.clone(),
            Some(Value::Number(n)) => return n.to_string(),
            Some(Value::Bool(b)) => return b.to_string(),
            _ => {}
        }
    }
    String::new()
}

pub(super) fn as_i64(value: Option<&Value>) -> i64 {
    match value {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        Some(Value::String(s)) => s.parse().unwrap_or(0),
        _ => 0,
    }
}

/// 去标签 + 压空白。
pub(super) fn plain(input: &str) -> String {
    proto::plain(&proto::strip_tags(input))
}

/// 字数归一：`12345` → `1.2万字`。
pub(super) fn wan(value: Option<&Value>) -> String {
    let count = match value {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(Value::String(s)) => s.parse().unwrap_or(0.0),
        _ => 0.0,
    };
    if count >= 100_000_000.0 {
        format!("{}亿字", (count / 10_000_000.0).round() / 10.0)
    } else if count >= 10_000.0 {
        format!("{}万字", (count / 1_000.0).round() / 10.0)
    } else if count > 0.0 {
        format!("{}字", count as i64)
    } else {
        String::new()
    }
}
