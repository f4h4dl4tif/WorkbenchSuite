#!/usr/bin/env python3
"""Writes docs/releases.js: the latest release of every tool (and the launcher) for the website.

Uses GITHUB_TOKEN if set (GitHub Actions), else `gh auth token` if gh is signed in, else no token.
Keeps the previous value for any repo that can't be read, so a hiccup never blanks the site.
"""
import json, os, subprocess, sys, urllib.request, datetime

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
catalog = json.load(open(os.path.join(root, "catalog.json")))
out_path = os.path.join(root, "docs", "releases.js")

token = os.environ.get("GITHUB_TOKEN")
if not token:
    try:
        token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=10).stdout.strip() or None
    except Exception:
        token = None

previous = {}
if os.path.exists(out_path):
    try:
        text = open(out_path).read()
        previous = json.loads(text[text.index("{"):text.rindex("}") + 1]).get("releases", {})
    except Exception:
        previous = {}

def latest(repo):
    req = urllib.request.Request(f"https://api.github.com/repos/{catalog['owner']}/{repo}/releases/latest",
                                 headers={"Accept": "application/vnd.github+json", "User-Agent": "WorkbenchSite"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=20) as r:
        d = json.load(r)
    assets = [a for a in d.get("assets", []) if "windows" not in a["name"].lower()]
    pick = next((a for ext in (".dmg", ".pkg", ".zip") for a in assets if a["name"].endswith(ext)), None)
    return {
        "version": d["tag_name"].lstrip("vV"),
        "date": d.get("published_at") or "",
        "url": d["html_url"],
        "download": pick["browser_download_url"] if pick else None,
        "file": pick["name"] if pick else None,
        "size": pick["size"] if pick else None,
    }

repos = [a["repo"] for a in catalog["apps"]] + [catalog["launcherRepo"]]
releases, failed = {}, []
for repo in repos:
    try:
        releases[repo] = latest(repo)
    except Exception as e:
        failed.append(f"{repo}: {e}")
        if repo in previous:
            releases[repo] = previous[repo]

payload = {"updated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "releases": releases}
# Only rewrite when a version or download actually changed, so scheduled runs don't make empty commits.
if releases == previous and os.path.exists(out_path):
    print("releases.js unchanged")
else:
    with open(out_path, "w") as f:
        f.write("window.RELEASES = " + json.dumps(payload, indent=2) + ";\n")
    print(f"releases.js updated ({len(releases)} repos)")
for line in failed:
    print("  could not read", line, file=sys.stderr)
sys.exit(1 if failed and not releases else 0)
