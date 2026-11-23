#!/bin/bash
# Waits until just after midnight, then publishes the remaining repos one at a time,
# spacing them out so GitHub's "too many repositories, too quickly" limit isn't hit.
# Finishes by turning on GitHub Pages for the website. Log: publish-nightly.log
set -uo pipefail
cd "$(dirname "$0")/.."
LOG="$(pwd)/publish-nightly.log"
REPOS=(Kalam NotchDock Padwise Platewise Readscape RecipeCanvas RedactIQ SiliconScope Spyglass Tapwise Tickdesk Tuck Wattline WorkbenchSuite)
GAP=${GAP:-900}          # 15 minutes between repos
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

caffeinate -i -w $$ &    # keep the Mac awake while this runs (lid must stay open)

start=$(date -j -v+1d -v0H -v5M -v0S +%s)   # 00:05 tomorrow
log "Waiting until $(date -r "$start" '+%Y-%m-%d %H:%M') to start"
while [ "$(date +%s)" -lt "$start" ]; do sleep 60; done

for repo in "${REPOS[@]}"; do
  for attempt in $(seq 1 12); do
    log "Publishing $repo (attempt $attempt)"
    if out=$(VISIBILITY=public ONLY="$repo" scripts/publish.sh 2>&1); then
      echo "$out" | grep -E "github.com|already released" | tee -a "$LOG"
      log "$repo done"
      break
    fi
    echo "$out" | tail -2 | tee -a "$LOG"
    if echo "$out" | grep -q "too many repositories"; then wait=1800; else wait=600; fi
    log "$repo failed, retrying in $((wait / 60)) min"
    sleep "$wait"
  done
  [ "$repo" = WorkbenchSuite ] || sleep "$GAP"
done

OWNER=$(gh api user -q .login)
log "Turning on GitHub Pages"
gh api -X POST "repos/$OWNER/WorkbenchSuite/pages" -f "source[branch]=main" -f "source[path]=/docs" >>"$LOG" 2>&1 \
  || gh api -X PUT "repos/$OWNER/WorkbenchSuite/pages" -f "source[branch]=main" -f "source[path]=/docs" >>"$LOG" 2>&1
log "All done. Site: https://$OWNER.github.io/WorkbenchSuite/"
