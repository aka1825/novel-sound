//! 七猫正文：章节页 HTML 里的 `.article` 段落。

use futures::future::BoxFuture;
use serde_json::{json, Value};

use crate::endpoints::{Ctx, Params};
use crate::error::{ApiError, ApiResult};
use crate::upstream::qimao as proto;

use super::common::{browser_headers, get_text, resolve_book_id, resolve_chapter_id};

pub(super) fn handle_chapter<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = resolve_book_id(params)?;
        let chapter_id = resolve_chapter_id(params)?;
        let url = proto::chapter_page_url(&book_id, &chapter_id);
        let html = get_text(ctx, &url, browser_headers()).await?;
        let content = proto::article_text(&html);
        if content.is_empty() {
            // 付费章（`is_vip = 1`）页面不给正文；改版后选择器失效也会走到这里。
            // 两种情况都只能是「取不到」，不能编内容。
            return Err(ApiError::Internal(format!(
                "qimao content unavailable for book {book_id} chapter {chapter_id}: \
                 article block missing (VIP chapter or layout change)"
            )));
        }
        Ok(json!({
            "source": "qimao",
            "data": { "bookId": book_id, "chapterId": chapter_id, "content": content }
        }))
    })
}
