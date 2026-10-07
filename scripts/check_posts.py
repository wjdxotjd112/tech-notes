#!/usr/bin/env python3
"""Journal post checks. Local and CI use this before mkdocs build --strict."""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
from datetime import date, datetime
from html.parser import HTMLParser
from pathlib import Path

import yaml

CATEGORIES = ("트러블슈팅", "구축설계", "자동화 CI/CD", "성능 튜닝")
ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
GUIDE_FILES = [
    ROOT / "README.md",
    ROOT / "AGENTS.md",
    ROOT / "CLAUDE.md",
    *sorted((ROOT / "guides").glob("*.md")),
]
PLACEHOLDER_MARKERS = ("{{", "작성 후 삭제", "PLACEHOLDER")
SECRET_PATTERNS = (
    (re.compile(r"AKIA[0-9A-Z]{16}"), "aws-access-key"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private-key"),
    (re.compile(r"ghp_[A-Za-z0-9]{20,}"), "github-token"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "github-token"),
    (re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"), "slack-token"),
    (
        re.compile(
            r"(?i)(api[_-]?key|secret|password|token)\s*[:=]\s*['\"][^'\"]{8,}"
        ),
        "credential-assignment",
    ),
)
LINK_RE = re.compile(r"!\[[^\]]*\]\(([^)]+)\)|\[[^\]]*\]\(([^)]+)\)")
# Existing pages retain their original format. Never add new posts to this set.
LEGACY_SUMMARY_POSTS = frozenset({
    "automation/2026-10-04-sample-pages-flow.md",
    "cheatsheets/git-status.md",
    "design/2026-10-06-sample-ovn-roles.md",
    "labs/2026-10-05-sample-local-preview.md",
    "troubleshooting/2026-10-07-sample-log-hypothesis.md",
})


class SummaryHTML(HTMLParser):
    """Collect real HTML nodes; fenced examples are removed before parsing."""

    def __init__(self):
        super().__init__()
        self.nodes = []
        self.stack = []

    def handle_starttag(self, tag, attrs):
        node = {"tag": tag, "attrs": dict(attrs), "parent": self.stack[-1] if self.stack else None}
        self.nodes.append(node)
        if tag not in {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index]["tag"] == tag:
                del self.stack[index:]
                break


def has_class(node, name):
    return name in (node["attrs"].get("class") or "").split()


def inside(node, parent):
    current = node["parent"]
    while current is not None:
        if current is parent:
            return True
        current = current["parent"]
    return False


def check_summary(path: Path, data: dict, body: str, docs: Path) -> list[str]:
    errors = []
    style = data.get("summary_style")
    legacy = path.relative_to(docs).as_posix() in LEGACY_SUMMARY_POSTS
    if style is not None and style != "editorial":
        return [f"{path}: summary_style must be editorial"]
    parser = SummaryHTML()
    parser.feed(without_fences(body))
    roots = [n for n in parser.nodes if n["tag"] == "section" and has_class(n, "editorial-summary")]
    if style != "editorial":
        if roots or not legacy:
            errors.append(f"{path}: summary_style: editorial is required for an editorial summary or a new post")
        return errors
    if len(roots) != 1:
        return [f"{path}: editorial summary must contain exactly one section.editorial-summary"]
    root = roots[0]
    nodes = [n for n in parser.nodes if inside(n, root)]
    for name, tag in (("editorial-summary-layout", "div"), ("editorial-summary-copy", "div"), ("editorial-summary-label", "span"), ("editorial-summary-title", "h2"), ("editorial-summary-result", "p")):
        if len([n for n in nodes if n["tag"] == tag and has_class(n, name)]) != 1:
            errors.append(f"{path}: editorial summary requires one {tag}.{name}")
    titles = [n for n in nodes if has_class(n, "editorial-summary-title")]
    if titles:
        title_id = titles[0]["attrs"].get("id")
        if not title_id or root["attrs"].get("aria-labelledby") != title_id:
            errors.append(f"{path}: editorial summary aria-labelledby must match the title id")
        elif len([n for n in parser.nodes if n["attrs"].get("id") == title_id]) != 1:
            errors.append(f"{path}: editorial summary title id must be unique")
    copies = [n for n in nodes if has_class(n, "editorial-summary-copy")]
    if copies and not any(n["tag"] == "p" and n["parent"] is copies[0] for n in nodes):
        errors.append(f"{path}: editorial summary copy requires a description paragraph")
    results = [n for n in nodes if has_class(n, "editorial-summary-result")]
    if results and not any(n["tag"] == "span" and n["parent"] is results[0] for n in nodes):
        errors.append(f"{path}: editorial summary result requires an inner span")
    facts = [n for n in nodes if n["tag"] == "aside" and has_class(n, "editorial-summary-facts")]
    if has_class(root, "editorial-summary--text-only"):
        if facts:
            errors.append(f"{path}: text-only editorial summary must omit the facts aside")
    elif len(facts) != 1:
        errors.append(f"{path}: editorial summary needs a facts aside or the text-only class")
    if facts:
        fact_nodes = [n for n in nodes if inside(n, facts[0])]
        labels = [n for n in fact_nodes if has_class(n, "editorial-fact-label")]
        values = [n for n in fact_nodes if has_class(n, "editorial-fact-value")]
        if not facts[0]["attrs"].get("aria-label") or not 1 <= len(values) <= 2 or len(labels) != len(values):
            errors.append(f"{path}: editorial facts require aria-label and one or two labelled values")
    if any(has_class(n, "incident-summary") for n in parser.nodes):
        errors.append(f"{path}: do not combine editorial and legacy card summaries")
    return errors


def split_front_matter(text: str) -> tuple[dict | None, str]:
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---", 4)
    if end == -1:
        return None, text
    raw = text[4:end]
    data = yaml.safe_load(raw)
    body = text[end + 4 :]
    if data is None:
        data = {}
    if not isinstance(data, dict):
        raise ValueError("front matter is not a mapping")
    return data, body


def date_text(value) -> str | None:
    if isinstance(value, datetime):
        return None
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        try:
            date.fromisoformat(value)
        except ValueError:
            return None
        return value
    return None


def iter_posts(docs: Path):
    if not docs.is_dir():
        return
    for path in sorted(docs.rglob("*.md")):
        if path.name == "index.md":
            continue
        data, body = split_front_matter(path.read_text(encoding="utf-8"))
        if not data or "category" not in data:
            continue
        yield path, data, body


def target_of(link: str, source: Path, docs: Path) -> Path | None:
    link = link.strip().split()[0]
    if link.startswith(("#", "mailto:", "http://", "https://")):
        return None
    path_part = link.split("#", 1)[0]
    if not path_part:
        return None
    if path_part.startswith("/tech-notes/"):
        return docs / path_part.removeprefix("/tech-notes/")
    return (source.parent / path_part).resolve()


def without_fences(text: str) -> str:
    return re.sub(r"```.*?```", "", text, flags=re.S)


def check_links(path: Path, text: str, docs: Path) -> list[str]:
    errors = []
    for match in LINK_RE.finditer(without_fences(text)):
        link = match.group(1) or match.group(2)
        target = target_of(link, path, docs)
        if target is None:
            continue
        if not target.exists():
            errors.append(f"{path}: missing link target {link.split('#', 1)[0]}")
    return errors


def check_secrets(path: Path, text: str) -> list[str]:
    errors = []
    for number, line in enumerate(text.splitlines(), start=1):
        for pattern, kind in SECRET_PATTERNS:
            if pattern.search(line):
                errors.append(f"{path}:{number}: secret pattern {kind}")
    return errors


def check_posts(docs: Path) -> list[str]:
    errors: list[str] = []
    featured: list[Path] = []
    for path, data, body in iter_posts(docs):
        rel = path
        title = data.get("title")
        summary = data.get("summary")
        if not isinstance(title, str) or not title.strip():
            errors.append(f"{rel}: title must be a non-empty string")
        if not isinstance(summary, str) or not summary.strip():
            errors.append(f"{rel}: summary must be a non-empty string")
        parsed_date = date_text(data.get("date"))
        if parsed_date is None:
            errors.append(f"{rel}: date must be YYYY-MM-DD")
        else:
            match = re.match(r"(\d{4}-\d{2}-\d{2})-", path.name)
            if match and match.group(1) != parsed_date:
                errors.append(f"{rel}: filename date and date differ")
        category = data.get("category")
        if category not in CATEGORIES:
            errors.append(f"{rel}: category is not one of the four names")
        tags = data.get("tags")
        if isinstance(tags, str):
            tags_ok = bool(tags.strip())
        elif isinstance(tags, list) and tags and all(isinstance(item, str) and item.strip() for item in tags):
            tags_ok = True
        else:
            tags_ok = False
        if not tags_ok:
            errors.append(f"{rel}: tags must be a non-empty string or list of strings")
        if "featured" in data:
            if not isinstance(data["featured"], bool):
                errors.append(f"{rel}: featured must be true or false")
            elif data["featured"]:
                featured.append(path)
        if "sample" in data and not isinstance(data["sample"], bool):
            errors.append(f"{rel}: sample must be true or false")
        for key in ("figure_label", "spotlight_note"):
            if key in data and not isinstance(data[key], str):
                errors.append(f"{rel}: {key} must be a string")
        if "figure_lines" in data and not isinstance(data["figure_lines"], list):
            errors.append(f"{rel}: figure_lines must be a list")
        if "spotlight" in data and not isinstance(data["spotlight"], bool):
            errors.append(f"{rel}: spotlight must be true or false")
        errors.extend(check_summary(path, data, body, docs))
        blob = f"{title or ''}\n{summary or ''}\n{body}"
        for marker in PLACEHOLDER_MARKERS:
            if marker in blob:
                errors.append(f"{rel}: template placeholder remains ({marker})")
        errors.extend(check_links(path, body, docs))
        errors.extend(check_secrets(path, path.read_text(encoding="utf-8")))
    if len(featured) > 1:
        joined = ", ".join(str(path) for path in featured)
        errors.append(f"featured: true on more than one post: {joined}")
    return errors


def check_guide_files(paths: list[Path], docs: Path) -> list[str]:
    errors = []
    for path in paths:
        if not path.is_file():
            errors.append(f"missing guide file: {path}")
            continue
        text = path.read_text(encoding="utf-8")
        errors.extend(check_links(path, text, docs))
        errors.extend(check_secrets(path, text))
    return errors


def valid_body(category: str) -> str:
    return ('<section class="editorial-summary editorial-summary--text-only" aria-labelledby="summary-title">'
            '<div class="editorial-summary-layout"><div class="editorial-summary-copy">'
            '<span class="editorial-summary-label">핵심</span>'
            '<h2 class="editorial-summary-title" id="summary-title">확인 내용</h2><p>근거와 설명</p>'
            '</div></div><p class="editorial-summary-result"><span>확인 범위</span></p></section>'
            f"\n\n## 참고 자료\n\n공식 문서 기준. 실행 결과는 없음.\n\n분류: {category}\n")


def write_post(docs: Path, name: str, meta: str, body: str) -> None:
    path = docs / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"---\nsummary_style: editorial\n{meta}\n---\n\n{body}", encoding="utf-8")


def expect_fail(docs: Path, label: str) -> str | None:
    errors = check_posts(docs)
    if errors:
        secretish = "ghp_"
        if any(secretish in error for error in errors):
            return f"{label}: secret value leaked into the message"
        return None
    return f"{label}: expected a failure"


def self_test() -> int:
    failures: list[str] = []
    token = "ghp_" + ("a" * 24)
    with tempfile.TemporaryDirectory() as tmp:
        docs = Path(tmp)
        write_post(
            docs,
            "ok/2026-10-07-note.md",
            "title: 확인 메모\nsummary: 짧은 요약\ndate: 2026-10-07\ncategory: 트러블슈팅\ntags:\n  - Linux\n",
            valid_body("트러블슈팅"),
        )
        if check_posts(docs):
            failures.append("valid post was rejected: " + "; ".join(check_posts(docs)))
        (docs / "index.md").write_text("---\ntitle: 기록\n---\n\n홈\n", encoding="utf-8")
        (docs / "note.md").write_text("category 없는 일반 페이지\n", encoding="utf-8")
        if check_posts(docs):
            failures.append("non-post page was treated as a post")

        cases = {
            "bad-category": (
                "bad/2026-10-07-bad.md",
                "title: 제목\nsummary: 요약\ndate: 2026-10-07\ncategory: 기타\ntags:\n  - Linux\n",
                valid_body("기타"),
            ),
            "bad-date": (
                "bad/2026-10-07-date.md",
                "title: 제목\nsummary: 요약\ndate: 2026/10/07\ncategory: 구축설계\ntags:\n  - Linux\n",
                valid_body("구축설계"),
            ),
            "placeholder": (
                "bad/2026-10-08-placeholder.md",
                "title: '{{title}}'\nsummary: 요약\ndate: 2026-10-08\ncategory: 자동화 CI/CD\ntags:\n  - CI/CD\n",
                valid_body("자동화 CI/CD") + "작성 후 삭제\n",
            ),
            "missing-image": (
                "bad/2026-10-09-image.md",
                "title: 제목\nsummary: 요약\ndate: 2026-10-09\ncategory: 성능 튜닝\ntags:\n  - Linux\n",
                valid_body("성능 튜닝") + "![그림](../assets/missing.png)\n",
            ),
        }
        for label, (name, meta, body) in cases.items():
            isolated = Path(tmp) / label
            if isolated.exists():
                shutil.rmtree(isolated)
            write_post(isolated, name, meta, body)
            message = expect_fail(isolated, label)
            if message:
                failures.append(message)

        featured_docs = Path(tmp) / "featured"
        for index, category in enumerate(CATEGORIES[:2], start=1):
            write_post(
                featured_docs,
                f"a/2026-10-0{index}-one.md",
                f"title: 글 {index}\nsummary: 요약\ndate: 2026-10-0{index}\ncategory: {category}\ntags:\n  - Linux\nfeatured: true\n",
                valid_body(category),
            )
        message = expect_fail(featured_docs, "two-featured")
        if message:
            failures.append(message)

        secret_docs = Path(tmp) / "secret"
        write_post(
            secret_docs,
            "sec/2026-10-07-secret.md",
            "title: 제목\nsummary: 요약\ndate: 2026-10-07\ncategory: 트러블슈팅\ntags:\n  - Linux\n",
            valid_body("트러블슈팅") + f"token = '{token}'\n",
        )
        secret_errors = check_posts(secret_docs)
        if not secret_errors:
            failures.append("secret pattern was not blocked")
        elif any(token in error for error in secret_errors):
            failures.append("secret value leaked into the message")

        category_docs = Path(tmp) / "categories"
        for index, category in enumerate(CATEGORIES, start=1):
            write_post(
                category_docs,
                f"notes/2026-10-0{index}-sample.md",
                f"title: 확인 {index}\nsummary: 짧은 요약\ndate: 2026-10-0{index}\ncategory: {category}\ntags:\n  - Linux\n",
                valid_body(category),
            )
        category_errors = check_posts(category_docs)
        if category_errors:
            failures.append("valid categories rejected: " + "; ".join(category_errors))

        summary_path = docs / "notes/2026-10-07-summary.md"
        text_only = valid_body("구축설계")
        fact = ('<div><span class="editorial-fact-label">대상</span>'
                '<p class="editorial-fact-value">1<span>단위</span></p></div>')
        with_facts = text_only.replace(" editorial-summary--text-only", "").replace(
            '</div></div><p class="editorial-summary-result">',
            '</div><aside class="editorial-summary-facts" aria-label="관측값">' + fact + '</aside></div><p class="editorial-summary-result">',
        )
        for name, body in (("text-only", text_only), ("one-fact", with_facts),
                           ("two-facts", with_facts.replace(fact, fact * 2))):
            if check_summary(summary_path, {"summary_style": "editorial"}, body, docs):
                failures.append("valid editorial summary rejected: " + name)
        summary_cases = (
            ({}, text_only, "summary_style: editorial"),
            ({}, "요약 없음", "summary_style: editorial"),
            ({"summary_style": "other"}, text_only, "summary_style must"),
            ({"summary_style": "editorial"}, "```html\n" + text_only + "\n```", "exactly one"),
            ({"summary_style": "editorial"}, text_only * 2, "exactly one"),
            ({"summary_style": "editorial"}, text_only.replace('aria-labelledby="summary-title"', 'aria-labelledby="missing"'), "aria-labelledby"),
            ({"summary_style": "editorial"}, text_only.replace('editorial-summary-result', 'other-result'), "p.editorial-summary-result"),
            ({"summary_style": "editorial"}, text_only.replace('<span>확인 범위</span>', '확인 범위'), "inner span"),
            ({"summary_style": "editorial"}, text_only.replace(' editorial-summary--text-only', ''), "facts aside"),
            ({"summary_style": "editorial"}, with_facts.replace(fact, fact * 3), "one or two"),
            ({"summary_style": "editorial"}, with_facts.replace('aria-label="관측값"', ''), "aria-label"),
            ({"summary_style": "editorial"}, with_facts.replace('class="editorial-summary"', 'class="editorial-summary editorial-summary--text-only"'), "must omit"),
        )
        for meta, body, expected in summary_cases:
            actual = check_summary(summary_path, meta, body, docs)
            if not any(expected in error for error in actual):
                failures.append("summary check did not reject: " + expected)
        for legacy in LEGACY_SUMMARY_POSTS:
            if check_summary(docs / legacy, {}, "기존 본문", docs):
                failures.append("existing post format was rejected: " + legacy)

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print("self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--docs", type=Path, default=DOCS)
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    errors = check_posts(args.docs)
    if args.docs.resolve() == DOCS.resolve():
        errors.extend(check_guide_files(GUIDE_FILES, DOCS))
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"post check passed: {args.docs}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
