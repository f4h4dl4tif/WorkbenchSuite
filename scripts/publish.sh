#!/bin/bash
# Creates a GitHub repo for every tool (and this suite repo), pushes it, and publishes a release
# with the tool's installers so the launcher and website can find them.
#   VISIBILITY=private|public (default private)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUITE="$ROOT/WorkbenchSuite"
VIS="${VISIBILITY:-private}"

gh auth status >/dev/null 2>&1 || { echo "Run: gh auth login"; exit 1; }
OWNER=$(gh api user -q .login)
echo "Publishing as $OWNER ($VIS)"

# Point the catalog at this account.
python3 - "$SUITE/catalog.json" "$OWNER" <<'PY'
import json, sys
p, owner = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d["owner"] = owner
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False); open(p, "a").write("\n")
PY
"$SUITE/scripts/build-site.sh" >/dev/null

json() { python3 -c "import json,sys; d=json.load(open('$SUITE/catalog.json')); a=[x for x in d['apps'] if x['repo']=='$1'][0]; print(a['$2'])"; }

ensure_repo() { # dir repo description
  local dir=$1 repo=$2 desc=$3
  cd "$dir"
  if gh repo view "$OWNER/$repo" >/dev/null 2>&1; then
    git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$OWNER/$repo.git"
    git push -u origin main
  else
    gh repo create "$OWNER/$repo" "--$VIS" --description "$desc" --source . --remote origin --push
  fi
}

release() { # dir repo version files...
  local dir=$1 repo=$2 version=$3; shift 3
  cd "$dir"
  if gh release view "v$version" -R "$OWNER/$repo" >/dev/null 2>&1; then echo "  v$version already released"; return; fi
  gh release create "v$version" -R "$OWNER/$repo" --title "$repo $version" \
    --notes "Download the .dmg (drag to Applications) or the .pkg installer. Not notarized: see How to Install.txt if macOS blocks it. Or install and update it with the Workbench launcher." "$@"
}

for dir in "$ROOT"/*/; do
  repo=$(basename "$dir")
  grep -q "\"repo\": \"$repo\"" "$SUITE/catalog.json" || continue
  echo "== $repo"
  ensure_repo "$dir" "$repo" "$(json "$repo" tagline)"

  files=()
  shopt -s nullglob
  for f in "$dir"dist/*.dmg "$dir"dist/*.pkg "$dir"dist/*.zip "$dir"dist/"How to Install.txt"; do [ -f "$f" ] && files+=("$f"); done
  shopt -u nullglob
  if [ ${#files[@]} -gt 0 ]; then
    version=$(basename "${files[0]}" | sed -E "s/^[A-Za-z]+-([0-9][0-9.]*[0-9]).*/\1/")
  else
    # No packaged installer yet: ship a zip of the most recent local build.
    app=$(ls -d "$dir"build/*.app 2>/dev/null | head -1 || true)
    [ -n "$app" ] || { echo "  no build to release"; continue; }
    version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
    zip="$(mktemp -d)/$repo-$version.zip"
    ditto -c -k --keepParent "$app" "$zip"
    files=("$zip")
  fi
  release "$dir" "$repo" "$version" "${files[@]}"
done

echo "== WorkbenchSuite"
cd "$SUITE"
[ -d .git ] || git init -q -b main
git add -A
git diff --cached --quiet || git commit -q -m "Update Workbench Suite catalog and site

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
ensure_repo "$SUITE" WorkbenchSuite "Capable, open-source tools for your Mac, with one launcher to install and update them all."
LV=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$SUITE/launcher/Resources/Info.plist")
release "$SUITE" WorkbenchSuite "$LV" "$SUITE"/launcher/dist/Workbench-"$LV".{dmg,pkg,zip} "$SUITE/launcher/dist/How to Install.txt"
echo "Done: https://github.com/$OWNER/WorkbenchSuite"
