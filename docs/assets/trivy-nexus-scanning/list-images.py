#!/usr/bin/env python3
"""Read Nexus Docker components and write digest-pinned image targets."""
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def main():
    scan_dir = Path(os.environ["SCAN_DIR"])
    output_dir = Path(os.environ.get("SCAN_OUTPUT_DIR", str(scan_dir)))
    base = os.environ["NEXUS_URL"].rstrip("/")
    parsed = urllib.parse.urlsplit(base)
    if parsed.scheme != "https" or not parsed.netloc or parsed.path or parsed.username:
        raise ValueError("NEXUS_URL must be an HTTPS base URL without a path or credentials")
    registry = os.environ.get("REGISTRY", parsed.netloc)
    if registry != parsed.netloc:
        raise ValueError("REGISTRY must match NEXUS_URL for this path-based Nexus example")
    repository = os.environ.get("DOCKER_REPOSITORY", "docker-hosted")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", repository):
        raise ValueError("Invalid repository name")
    config_dir = Path(os.environ.get("DOCKER_CONFIG", str(scan_dir / "auth")))
    config = json.loads((config_dir / "config.json").read_text())
    credentials = next((entry for key, entry in config.get("auths", {}).items()
                        if key.removeprefix("https://").rstrip("/") == registry), {})
    auth = credentials.get("auth")
    if not isinstance(auth, str) or not re.fullmatch(r"[A-Za-z0-9+/]+=*", auth):
        raise ValueError("A registry-specific login with inline auth is required in DOCKER_CONFIG")
    context = ssl.create_default_context(cafile=os.environ["NEXUS_CA"])

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, fp, code, message, headers, newurl):
            raise ValueError("Nexus redirected a credentialed request; check NEXUS_URL")

    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=context), NoRedirect())

    def request(path, method="GET"):
        accept = "application/json"
        if path.startswith("/v2/"):
            accept = ", ".join([
                "application/vnd.oci.image.index.v1+json",
                "application/vnd.oci.image.manifest.v1+json",
                "application/vnd.docker.distribution.manifest.list.v2+json",
                "application/vnd.docker.distribution.manifest.v2+json",
            ])
        return opener.open(urllib.request.Request(base + path, method=method, headers={
            "Authorization": "Basic " + auth, "Accept": accept}), timeout=30)

    items, token, seen_tokens = [], None, set()
    while True:
        query = {"repository": repository}
        if token:
            query["continuationToken"] = token
        with request("/service/rest/v1/components?" + urllib.parse.urlencode(query)) as response:
            page = json.load(response)
        items.extend(page["items"])
        token = page.get("continuationToken")
        if not token:
            break
        if token in seen_tokens:
            raise ValueError("Nexus pagination token repeated")
        seen_tokens.add(token)

    rows = []
    for item in sorted(items, key=lambda entry: (entry["name"], entry["version"])):
        name, tag = item["name"], item["version"]
        if any(character in name + tag for character in "\t\r\n"):
            raise ValueError("Unexpected control character in image name/tag")
        path = ("/v2/" + repository + "/" + urllib.parse.quote(name, safe="/")
                + "/manifests/" + urllib.parse.quote(tag, safe=""))
        with request(path, method="HEAD") as response:
            digest = response.headers.get("Docker-Content-Digest", "")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise ValueError("Missing or invalid manifest digest: " + name + ":" + tag)
        rows.append((name, tag, digest, f"{registry}/{repository}/{name}@{digest}"))
    if not rows:
        raise ValueError("No Docker images found; an empty target list is not a successful inventory")
    output_dir.mkdir(parents=True, exist_ok=True)
    targets = list(dict.fromkeys(row[3] for row in rows))
    (output_dir / "images.txt").write_text("".join(target + "\n" for target in targets))
    (output_dir / "image-tags.tsv").write_text(
        "name\ttag\tdigest\timage\n" + "".join("\t".join(row) + "\n" for row in rows))
    (output_dir / "image-inventory.json").write_text(json.dumps({
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "repository": repository, "components": len(items),
        "tags": len(rows), "scan_targets": len(targets),
        "platform": "linux/amd64",
    }, indent=2) + "\n")
    print(f"Tags={len(rows)}, digest-pinned targets={len(targets)}")
    print("Target list:", output_dir / "images.txt")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, urllib.error.URLError) as error:
        print("Inventory failed:", error, file=sys.stderr)
        sys.exit(1)
