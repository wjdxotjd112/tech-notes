"""Collect journal posts from Markdown front matter."""

from __future__ import annotations

from mkdocs.utils import meta

CATEGORY_ORDER = [
    "트러블슈팅",
    "구축설계",
    "자동화 CI/CD",
    "성능 튜닝",
]

POSTS: list[dict] = []


def _date_text(value) -> str:
    if value is None:
        return ""
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return str(value)


def _tags(value) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    return [str(item) for item in value]


def on_nav(nav, config, files):
    posts: list[dict] = []
    for file in files.documentation_pages():
        if file.src_uri == "index.md":
            continue
        markdown, data = meta.get_data(file.content_string)
        if not data.get("category"):
            continue
        posts.append(
            {
                "title": data.get("title") or file.name,
                "url": file.url,
                "summary": data.get("summary") or "",
                "date": _date_text(data.get("date")),
                "category": str(data.get("category")),
                "tags": _tags(data.get("tags")),
                "featured": bool(data.get("featured")),
                "sample": bool(data.get("sample")),
                "figure_label": data.get("figure_label") or "",
                "figure_lines": data.get("figure_lines") or [],
                "spotlight": bool(data.get("spotlight")),
                "spotlight_note": data.get("spotlight_note") or "",
            }
        )
    posts.sort(key=lambda post: post["date"], reverse=True)
    global POSTS
    POSTS = posts
    return nav


def on_env(env, config, files):
    categories = list(CATEGORY_ORDER)
    tags: list[str] = []
    for post in POSTS:
        for tag in post["tags"]:
            if tag not in tags:
                tags.append(tag)
    env.globals["journal_posts"] = POSTS
    env.globals["journal_categories"] = categories
    env.globals["journal_tags"] = tags
    return env


def on_page_context(context, page, config, nav):
    tags = set(_tags((page.meta or {}).get("tags")))
    related = [
        post
        for post in POSTS
        if post["url"] != page.url and tags.intersection(post["tags"])
    ]
    context["related_posts"] = related[:3]
    return context
