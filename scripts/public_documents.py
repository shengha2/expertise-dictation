#!/usr/bin/env python3
"""The public, offline-readable documentation shared by source exports and DMGs."""
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
# Explicitly reviewed public files only. Operator release evidence is a separate,
# optional allowlist and is never required by a public-source build.
DOCUMENTS = (
    "README.md", "MINT.md", "LICENSE", "THIRD_PARTY_NOTICES.md",
    "docs/evidence/1.1.11/final-build-validation.json",
    "docs/evidence/1.1.11/lists/README.md", "docs/evidence/1.1.11/lists/b1-results.json",
    "docs/evidence/1.1.11/lists/final-guard-results.json", "docs/evidence/1.1.11/lists/prompt-reset-review.md",
    "docs/evidence/1.1.11/lists/guard-corrections-b3.json",
    "docs/evidence/1.1.11/lists/guard-corrections-b4.json", "docs/evidence/1.1.11/lists/final-results.json",
    "docs/evidence/1.1.11/lists/b4-results.json", "docs/evidence/1.1.11/lists/final-focused-results.json",
    "docs/evidence/1.1.11/lists/guard-corrections-b6.json",
    "docs/evidence/1.1.11/preference-review/README.md", "docs/evidence/1.1.11/preference-review/fixtures.json",
    "docs/evidence/1.1.11/preference-review/review-b2.json", "docs/evidence/1.1.11/ui/preview-checks.json",
    "docs/evidence/1.1.11/preference-review/review-b4.json",
    "docs/evidence/1.1.11/preference-review/review-b5.json",
    "docs/evidence/1.1.11/latency/provider-comparison/manifest.json",
    "docs/evidence/1.1.11/latency/provider-comparison/source-comparison.json",
    "docs/rewrite-design.md", "docs/release-1.1.9.md", "docs/release-1.1.10.md", "docs/release-1.1.11.md", "Resources/Brand/README.md", "docs/LICENSE-Sparkle.txt",
    "Resources/Fonts/LICENSE-Inter.txt", "Resources/Sounds/LICENSE-UI-SFX.txt",
    "Resources/Sounds/SOURCE.md", "prompts/README.md", "prompts/full-rewrite.txt",
    "prompts/light-cleanup.txt", "prompts/punctuation.txt", "prompts/rewrite-verifier.txt",
    "evals/rewrite-quality.json", "evals/rewrite-long-quality.json", "service/README.md",
    "service/evidence/local-tests.log", "service/evidence/validation.json",
)
# These are our inspected guide screenshots, not downloaded research references.
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".svg"}


def document_paths(root=ROOT):
    """Fail before packaging if a required document or local inline link is absent."""
    root = root.resolve()
    names = set(DOCUMENTS)
    images = root / "docs/images"
    if images.exists():
        names.update(str(path.relative_to(root)) for path in images.rglob("*")
                     if path.suffix.lower() in IMAGE_SUFFIXES)
    paths = []
    for name in sorted(names):
        path = root / name
        if (not path.is_file() or not path.resolve().is_relative_to(root)
                or any(parent.is_symlink() for parent in (path, *path.parents) if parent != root)):
            raise ValueError("missing or linked public document: " + name)
        paths.append(path)
    included = {path.resolve() for path in paths}
    for path in paths:
        if path.suffix != ".md":
            continue
        # The bundled guides use inline Markdown links/images. Ignore code examples.
        content = re.sub(r"```.*?```", "", path.read_text(), flags=re.S)
        for match in re.finditer(r"!?\[[^\]]*\]\((?:<([^>]+)>|([^\s)]+))(?:\s+\"[^\"]*\")?\)", content):
            target = urlsplit(match.group(1) or match.group(2))
            if target.scheme or target.netloc or not target.path:
                continue
            linked = (path.parent / unquote(target.path)).resolve()
            if linked not in included:
                raise ValueError(f"unbundled local link in {path.relative_to(root)}: {target.path}")
    return paths


if __name__ == "__main__":
    try:
        print("\n".join(str(path.relative_to(ROOT)) for path in document_paths()))
    except ValueError as error:
        raise SystemExit("error: " + str(error))
