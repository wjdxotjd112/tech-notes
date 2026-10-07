#!/usr/bin/env python3
"""Journal post checks. Local and CI use this before mkdocs build --strict."""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
from datetime import date, datetime
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
    *sorted((ROOT / "templates").glob("*.md")),
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
    return f"확인 내용.\n\n## 참고 자료\n\n공식 문서 기준. 실행 결과는 없음.\n\n분류: {category}\n"


def write_post(docs: Path, name: str, meta: str, body: str) -> None:
    path = docs / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"---\n{meta}\n---\n\n{body}", encoding="utf-8")


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
                "작성 후 삭제\n",
            ),
            "missing-image": (
                "bad/2026-10-09-image.md",
                "title: 제목\nsummary: 요약\ndate: 2026-10-09\ncategory: 성능 튜닝\ntags:\n  - Linux\n",
                "![그림](../assets/missing.png)\n",
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
            f"token = '{token}'\n",
        )
        secret_errors = check_posts(secret_docs)
        if not secret_errors:
            failures.append("secret pattern was not blocked")
        elif any(token in error for error in secret_errors):
            failures.append("secret value leaked into the message")

        template_docs = Path(tmp) / "templates"
        for category, folder in (
            ("트러블슈팅", "troubleshooting"),
            ("구축설계", "design"),
            ("자동화 CI/CD", "automation"),
            ("성능 튜닝", "performance"),
        ):
            raw = (ROOT / "templates" / f"{folder}.md").read_text(encoding="utf-8")
            copied = template_docs / folder / "2026-10-07-sample.md"
            copied.parent.mkdir(parents=True, exist_ok=True)
            copied.write_text(raw, encoding="utf-8")
        message = expect_fail(template_docs, "raw-templates")
        if message:
            failures.append(message)
        filled = Path(tmp) / "filled"
        for index, (category, folder) in enumerate(
            (
                ("트러블슈팅", "troubleshooting"),
                ("구축설계", "design"),
                ("자동화 CI/CD", "automation"),
                ("성능 튜닝", "performance"),
            ),
            start=1,
        ):
            raw = (ROOT / "templates" / f"{folder}.md").read_text(encoding="utf-8")
            text = raw.replace("{{title}}", f"확인 {index}")
            text = text.replace("{{summary}}", "짧은 요약")
            text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
            text = re.sub(r"\{\{[^}]+\}\}", "확인 내용", text)
            path = filled / folder / "2026-10-07-filled.md"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        filled_errors = check_posts(filled)
        if filled_errors:
            failures.append("filled templates rejected: " + "; ".join(filled_errors))

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
