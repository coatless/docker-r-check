#!/bin/bash
# Delete published images that are older than a number of days.
#
#   eval/prune.sh <30|60|90|never> [--dry-run]
#
# An image is a version of the container package ghcr.io/<owner>/<repository>.
# One is kept when it is younger than the limit, or when it carries a tag
# that names no date and no R revision, such as openblas or openblas-stable.
# That tag is the arm's newest image, so every arm keeps one image however
# long ago it was last built. An image with no tag at all is kept as well
# when it was pushed within a day of one that is kept for its tag, because it
# may be a part of that image.
#
# Needs gh, with a token that may delete versions of the package. GitHub
# keeps a deleted version for 30 days, and it can be restored from the
# package's settings page in that time.
set -euo pipefail

keep="${1:?usage: $0 <30|60|90|never> [--dry-run]}"
dry="${2:-}"
case "$keep" in
never) echo "KEEP_DAYS is never, so nothing is deleted"; exit 0 ;;
30|60|90) ;;
*) echo "$0: '$keep' is not one of 30, 60, 90 or never" >&2; exit 2 ;;
esac

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
owner="${repo%%/*}"
pkg="$(printf '%s' "${repo#*/}" | tr '[:upper:]' '[:lower:]')"
case "$(gh api "/users/$owner" --jq .type)" in
Organization) base="/orgs/$owner/packages/container/$pkg" ;;
*)            base="/users/$owner/packages/container/$pkg" ;;
esac

gh api --paginate "$base/versions?per_page=100" \
    --jq '.[] | [.id, .created_at, (.metadata.container.tags | join(","))] | @tsv' > versions.tsv
echo "$(wc -l < versions.tsv | tr -d ' ') images in ghcr.io/$owner/$pkg, keeping $keep days"

python3 - "$keep" versions.tsv > delete.tsv <<'EOF'
import re, sys
from datetime import datetime, timedelta, timezone

keep, path = int(sys.argv[1]), sys.argv[2]
now = datetime.now(timezone.utc)
limit = now - timedelta(days=keep)
dated = re.compile(r"-(r\d+|\d{4}-\d{2}-\d{2})$")
rows = []
for line in open(path):
    vid, created, tags = (line.rstrip("\n").split("\t") + [""])[:3]
    when = datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    rows.append((vid, when, [t for t in tags.split(",") if t]))
# When the images kept for their tag were pushed.
current = [when for _, when, tags in rows if any(not dated.search(t) for t in tags)]
day = timedelta(days=1)
for vid, when, tags in rows:
    if when >= limit or any(not dated.search(t) for t in tags):
        continue
    if not tags and any(abs(when - c) <= day for c in current):
        continue
    print(vid, when.strftime("%Y-%m-%d"), ",".join(tags) or "(no tag)", sep="\t")
EOF

if [ ! -s delete.tsv ]; then
    echo "nothing is older than $keep days"
    exit 0
fi
while IFS=$'\t' read -r id day tags; do
    if [ "$dry" = --dry-run ]; then
        echo "would delete $id of $day ($tags)"
    else
        echo "deleting $id of $day ($tags)"
        gh api -X DELETE "$base/versions/$id" > /dev/null
    fi
done < delete.tsv
