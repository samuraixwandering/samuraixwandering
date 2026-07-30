#!/usr/bin/env bash
# Regenerates the contributions section of README.md from the GitHub API.
# Idempotent: only the text between the CONTRIBUTIONS markers is replaced.
set -euo pipefail

USER="${GH_USER:-samuraixwandering}"
README="${README_PATH:-README.md}"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

# Merged PRs in repositories the user does not own.
gh api -X GET search/issues \
  -f q="is:pr is:merged author:${USER} -user:${USER}" \
  -f per_page=100 -f sort=updated > "$TMP"

python3 - "$README" "$TMP" <<'PY'
import json, re, sys, datetime

readme_path, json_path = sys.argv[1], sys.argv[2]
data = json.load(open(json_path))
total, items = data.get("total_count", 0), data.get("items", [])

by_repo = {}
for it in items:
    repo = "/".join(it["repository_url"].split("/")[-2:])
    by_repo.setdefault(repo, []).append(it)

blocks = []
for repo, prs in sorted(by_repo.items(), key=lambda kv: (-len(kv[1]), kv[0])):
    prs.sort(key=lambda p: p.get("closed_at") or "", reverse=True)
    lines = [f"**{repo}** ({len(prs)})", ""]
    lines += [
        f"- [#{p['number']}]({p['html_url']}) {p['title']} "
        f"<sub>{(p.get('closed_at') or p['updated_at'])[:10]}</sub>"
        for p in prs
    ]
    blocks.append("\n".join(lines))

stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
section = (
    f"{total} merged pull request(s) in repositories I do not own.\n\n"
    + ("\n\n".join(blocks) if blocks else "_None yet._")
    + f"\n\n<sub>Updated {stamp} by "
      f"[update-contributions.yml](.github/workflows/update-contributions.yml).</sub>"
)

text = open(readme_path).read()
new = re.sub(
    r"(<!-- CONTRIBUTIONS:START -->).*?(<!-- CONTRIBUTIONS:END -->)",
    lambda m: f"{m.group(1)}\n\n{section}\n\n{m.group(2)}",
    text, flags=re.S,
)
if "CONTRIBUTIONS:START" not in text:
    sys.exit("error: markers not found in README")
if new == text:
    print("no change")
else:
    open(readme_path, "w").write(new)
    print(f"updated: {total} merged PR(s) across {len(by_repo)} repo(s)")
PY
