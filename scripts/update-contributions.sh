#!/usr/bin/env bash
# Regenerates the contributions section of README.md from the GitHub API.
# Idempotent: only the text between the CONTRIBUTIONS markers is replaced.
set -euo pipefail

USER="${GH_USER:-samuraixwandering}"
README="${README_PATH:-README.md}"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

# Merged PRs in repositories the user does not own.
# --paginate --slurp walks every page and yields an array of page objects,
# so this keeps working past the 100-result first page.
gh api --paginate --slurp -X GET search/issues \
  -f q="is:pr is:merged author:${USER} -user:${USER}" \
  -f per_page=100 -f sort=updated > "$TMP"

python3 - "$README" "$TMP" "$USER" <<'PY'
import json, re, sys, datetime

readme_path, json_path, USER = sys.argv[1], sys.argv[2], sys.argv[3]
pages = json.load(open(json_path))
if isinstance(pages, dict):          # tolerate a non-slurped single page
    pages = [pages]

total = pages[0].get("total_count", 0) if pages else 0
items, seen = [], set()
for page in pages:                   # dedupe: pages can overlap if data shifts mid-walk
    for it in page.get("items", []):
        if it["html_url"] not in seen:
            seen.add(it["html_url"])
            items.append(it)

# GitHub's search API hard-caps at 1000 results regardless of paging.
truncated = total > len(items)

by_repo = {}
for it in items:
    repo = "/".join(it["repository_url"].split("/")[-2:])
    by_repo.setdefault(repo, []).append(it)

RECENT_N = 10

rows = ["| Project | Merged |", "| --- | --- |"]
for repo, prs in sorted(by_repo.items(), key=lambda kv: (-len(kv[1]), kv[0])):
    rows.append(f"| [{repo}](https://github.com/{repo}) | {len(prs)} |")
table = "\n".join(rows) if by_repo else "_None yet._"

recent = sorted(items, key=lambda p: p.get("closed_at") or "", reverse=True)[:RECENT_N]
recent_md = "\n".join(
    f"- [{'/'.join(p['repository_url'].split('/')[-2:])}#{p['number']}]({p['html_url']}) "
    f"{p['title']} <sub>{(p.get('closed_at') or p['updated_at'])[:10]}</sub>"
    for p in recent
)

stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
search = ("https://github.com/search?q=is%3Apr+author%3A" + USER +
          "+is%3Amerged&type=pullrequests")
note = f" Showing {len(items)} of {total}; the API caps results." if total > len(items) else ""

section = f"""**{total}** merged PR{"s" if total != 1 else ""} in other people's repos.{note}

{table}
"""
if recent_md:
    section += f"""
**Recent**

{recent_md}
"""
section += f"""
<sub>Updated {stamp} · [all merged PRs]({search})</sub>"""

text = open(readme_path).read()
if "CONTRIBUTIONS:START" not in text:
    sys.exit("error: markers not found in README")
new = re.sub(
    r"(<!-- CONTRIBUTIONS:START -->).*?(<!-- CONTRIBUTIONS:END -->)",
    lambda m: f"{m.group(1)}\n\n{section}\n\n{m.group(2)}",
    text, flags=re.S,
)
if new == text:
    print("no change")
else:
    open(readme_path, "w").write(new)
    print(f"updated: {len(items)} of {total} merged PR(s), {len(by_repo)} repo(s)")
PY
