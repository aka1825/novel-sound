//! 七猫目录：`chapter-list` 接口一次给全，章节地址按 `/qmch/<bookId>/<chapterId>` 生成。

use futures::future::BoxFuture;
use serde_json::{json, Value};

use crate::endpoints::util::raw_json;
use crate::endpoints::{Ctx, Params};
use crate::error::{ApiError, ApiResult};
use crate::upstream::qimao as proto;

use super::common::{as_i64, browser_headers, get_text, plain, resolve_book_id, text_of};

pub(super) fn handle_toc<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = resolve_book_id(params)?;
        let url = proto::toc_url(&book_id);
        let body = get_text(ctx, &url, browser_headers()).await?;
        let payload = raw_json(body.as_bytes())?;
        let list = payload
            .get("data")
            .and_then(|data| data.get("chapters"))
            .and_then(|value| value.as_array())
            .cloned()
            .unwrap_or_default();

        let mut rows: Vec<Value> = Vec::with_capacity(list.len());
        for entry in &list {
            let Some(map) = entry.as_object() else {
                continue;
            };
            let chapter_id = text_of(map, &["id", "chapter_id"]);
            let title = plain(&text_of(map, &["title", "chapter_name"]));
            if chapter_id.is_empty() || title.is_empty() {
                continue;
            }
            // 站点用 `is_vip: "1"` 标记付费章；付费章页面不下发正文。
            let is_vip = text_of(map, &["is_vip"]) == "1";
            let chapter_url = proto::internal_chapter_url(&book_id, &chapter_id);
            rows.push(json!({
                "id": chapter_id,
                "title": title,
                "index": as_i64(map.get("index")),
                "isVip": is_vip,
                "isPay": is_vip,
                "url": chapter_url,
            }));
        }

        if rows.is_empty() {
            return Err(ApiError::Internal(format!(
                "qimao toc empty for book {book_id}: layout change or removed book"
            )));
        }

        let total = rows.len();
        Ok(json!({
            "source": "qimao",
            "data": { "bookId": book_id, "total": total, "chapters": rows }
        }))
    })
}
