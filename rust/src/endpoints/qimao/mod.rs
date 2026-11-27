//! 七猫小说数据源：`qimao_search` / `qimao_toc` / `qimao_chapter`。
//!
//! 与书旗一样是独立源，但**没有签名、没有设备注册**（七猫这两个接口是公开的
//! JSON，正文是章节页 HTML），所以三条路由全部走 [`UpstreamMode::NoSign`]。
//!
//! 链路（都实测通过，见 `upstream::qimao` 的地址构造函数）：
//!
//! * 搜索 `api-www.qimao.com/api/search/result?keyword=&page=&pageSize=`
//!   → `data.search_list[]`，每条带 `book_id / title / author / image_link /
//!   intro / read_url`；
//! * 目录 `api-www.qimao.com/api/book/chapter-list?book_id=`
//!   → `data.chapters[]`，一次给全，每条带 `id / title / index / is_vip`；
//! * 正文 `www.qimao.com/shuku/<bookId>-<chapterId>/`
//!   → `.chapter-detail-article .article` 下的 `<p>` 段落。

mod common;
mod content;
mod search;
mod toc;

use crate::endpoints::Server;

pub fn register(s: &mut Server) {
    s.add_route("qimao_search", search::handle_search);
    s.add_route("qimao_toc", toc::handle_toc);
    s.add_route("qimao_chapter", content::handle_chapter);
}

#[cfg(test)]
mod tests {
    use super::common::{plain, resolve_book_id, resolve_chapter_id};
    use crate::endpoints::Params;
    use crate::error::ApiError;

    fn params(pairs: &[(&str, &str)]) -> Params {
        Params::from_pairs(
            pairs
                .iter()
                .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
                .collect(),
        )
    }

    #[test]
    fn resolves_book_id_from_internal_url_query_and_raw_digits() {
        assert_eq!(
            resolve_book_id(&params(&[("book_id", "10007988")])).unwrap(),
            "10007988"
        );
        assert_eq!(
            resolve_book_id(&params(&[("url", "/qmbook/10007988")])).unwrap(),
            "10007988"
        );
        assert_eq!(
            resolve_book_id(&params(&[("url", "https://www.qimao.com/shuku/10007988/")])).unwrap(),
            "10007988"
        );
        assert!(matches!(
            resolve_book_id(&params(&[("book_id", "abc")])),
            Err(ApiError::BadRequest(_))
        ));
    }

    #[test]
    fn resolves_chapter_id_from_internal_url_and_query() {
        assert_eq!(
            resolve_chapter_id(&params(&[("chapter_id", "17697840140001")])).unwrap(),
            "17697840140001"
        );
        assert_eq!(
            resolve_chapter_id(&params(&[("url", "/qmch/10007988/17697840140001")])).unwrap(),
            "17697840140001"
        );
    }

    #[test]
    fn plain_collapses_whitespace() {
        assert_eq!(plain("  斗破\u{3000} 苍穹 \n"), "斗破 苍穹");
    }
}
