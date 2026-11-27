//! 七猫搜索：公开 JSON 接口 → 搜索结果列表。

use std::collections::HashSet;

use futures::future::BoxFuture;
use serde_json::{json, Value};

use crate::endpoints::util::raw_json;
use crate::endpoints::{Ctx, Params};
use crate::error::{ApiError, ApiResult};
use crate::upstream::qimao as proto;

use super::common::{browser_headers, get_text, pick, plain, text_of, wan};

pub(super) fn handle_search<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let key = pick(params, &["key", "query", "q", "keyword"]);
        if key.is_empty() {
            return Err(ApiError::BadRequest("missing key parameter".into()));
        }
        let page = params.get_int("page", 1).clamp(1, 50) as u32;
        let url = proto::search_url(&key, page);
        let body = get_text(ctx, &url, browser_headers()).await?;
        let payload = raw_json(body.as_bytes())?;
        let list = payload
            .get("data")
            .and_then(|data| data.get("search_list"))
            .and_then(|value| value.as_array())
            .cloned()
            .unwrap_or_default();

        let mut seen: HashSet<String> = HashSet::new();
        let mut items: Vec<Value> = Vec::new();
        for entry in &list {
            let Some(map) = entry.as_object() else {
                continue;
            };
            let book_id = text_of(map, &["book_id", "bookId"]);
            let name = plain(&text_of(map, &["title", "book_name"]));
            if book_id.is_empty() || name.is_empty() || !seen.insert(book_id.clone()) {
                continue;
            }
            let book_url = proto::internal_book_url(&book_id);
            items.push(json!({
                "bookId": book_id,
                "name": name,
                "author": plain(&text_of(map, &["author"])),
                "bookUrl": book_url,
                "coverUrl": text_of(map, &["image_link", "cover"]),
                "intro": plain(&text_of(map, &["intro"])),
                "wordCount": wan(map.get("words_num")),
                // 站点给的是「连载中 / 已完结」这类文案，原样透传。
                "status": plain(&text_of(map, &["is_over_txt"])),
                "lastChapter": plain(&text_of(map, &["latest_chapter_title"])),
                "kind": plain(&text_of(map, &["category2_name", "category_name"])),
                "source": "qimao",
            }));
            if items.len() >= 60 {
                break;
            }
        }

        // 空结果不算失败：接口会对生僻词正常回空列表，前端显示「没找到」即可。
        Ok(json!({ "source": "qimao", "data": items }))
    })
}
