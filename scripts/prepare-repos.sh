#!/bin/bash
# Prepares each tool folder as its own git repo: shared .gitignore rules, MIT license, first commit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APPS=(AppSweep Calendesk Crest DreamAtlas FolderPilot Glint Hearth HobbyAtlas InvoiceDesk Juxta Kalam NotchDock Padwise Platewise Readscape RecipeCanvas RedactIQ SiliconScope Spyglass Tapwise Tickdesk Tuck Wattline)
IGNORE=(
".DS_Store" ".build/" ".build-*/" "build/" "dist/" ".swiftpm/" "xcuserdata/" "DerivedData/"
"# secrets and signing material — never commit"
"signing/" "*.keychain-db" "keychain-password.txt" "Tools/keys/" "*.p12" "*.key" "*.mobileprovision" ".env"
"# packaged output"
"*.dmg" "*.pkg" "*.zip"
"# python"
".venv/" "__pycache__/" "*.pyc"
)
for a in "${APPS[@]}"; do
  d="$ROOT/$a"; cd "$d"
  touch .gitignore
  for line in "${IGNORE[@]}"; do grep -qxF -- "$line" .gitignore || echo "$line" >> .gitignore; done
  if [ "$a" = InvoiceDesk ]; then
    for line in "data/" "Invoice Desk.app/" "*.log"; do grep -qxF -- "$line" .gitignore || echo "$line" >> .gitignore; done
  fi
  if [ ! -f LICENSE ]; then
    cat > LICENSE <<LIC
MIT License

Copyright (c) 2026 $a contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LIC
  fi
  [ -d .git ] || git init -q -b main
  git add -A
  if git diff --cached --quiet; then echo "$a: nothing to commit"; continue; fi
  if git rev-parse -q --verify HEAD >/dev/null; then msg="Prepare $a for open-source release"; else msg="Initial open-source release of $a"; fi
  git commit -q -m "$msg

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
  echo "$a: committed $(git ls-files | wc -l | tr -d ' ') files, $(du -sh .git | cut -f1) .git"
done
