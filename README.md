# Workbench Suite

Capable, open-source tools for your Mac, and one launcher to install and update them all.

Every tool is a small, native SwiftUI app that runs locally and is MIT-licensed. Each one lives in its own repository with its own releases. **Workbench**, the launcher in this repo, reads those releases and installs, updates, opens and uninstalls the tools for you.

## Get started

Download the latest **Workbench** from [Releases](../../releases/latest). The `.pkg` is the recommended option; a `.dmg` is also provided. It isn't notarized, so read `How to Install.txt` if macOS blocks it the first time.

## The tools

| Tool | What it does | Category |
| --- | --- | --- |
| [AppSweep](../../../AppSweep) | Uninstall apps and every file they leave behind | System |
| [Crest](../../../Crest) | 29 tools that drop out of your MacBook's notch | System |
| [NotchDock](../../../NotchDock) | Hidden docks and widgets that live in the notch | System |
| [Glint](../../../Glint) | A radial, type-to-switch app switcher | System |
| [Tuck](../../../Tuck) | A drag-and-drop shelf at the edge of your screen | System |
| [Tapwise](../../../Tapwise) | Double-tap your MacBook to trigger 50 actions | System |
| [Wattline](../../../Wattline) | See what each app costs your battery | System |
| [SiliconScope](../../../SiliconScope) | An Apple silicon performance observatory | System |
| [Spyglass](../../../Spyglass) | A file browser that sits alongside Finder | Files & Code |
| [FolderPilot](../../../FolderPilot) | Rules that rename, tag and file things for you | Files & Code |
| [Padwise](../../../Padwise) | A fast, native source-code editor | Files & Code |
| [Juxta](../../../Juxta) | Compare and merge files, folders, tables and images | Files & Code |
| [RedactIQ](../../../RedactIQ) | Private, on-device PDF redaction | Files & Code |
| [Calendesk](../../../Calendesk) | A calendar pinned to your desktop | Productivity |
| [Tickdesk](../../../Tickdesk) | Flip, LCD, minimal and analog desktop clocks | Productivity |
| [Hearth](../../../Hearth) | A cozy, local-first personal dashboard | Productivity |
| [HobbyAtlas](../../../HobbyAtlas) | A project manager built for hobbies | Productivity |
| [Invoice Desk](../../../InvoiceDesk) | Invoicing and inventory in one Excel file | Productivity |
| [Kalam](../../../Kalam) | A quiet daily journal | Life & Creativity |
| [DreamAtlas](../../../DreamAtlas) | A private dream journal and pattern explorer | Life & Creativity |
| [Readscape](../../../Readscape) | Visual reading intelligence for your bookshelf | Life & Creativity |
| [RecipeCanvas](../../../RecipeCanvas) | A studio for recipes and cooking experiments | Life & Creativity |
| [Platewise](../../../Platewise) | Snap a dish, get the recipe, plan the week | Life & Creativity |

## What's in this repo

```
catalog.json        the list of tools (shared by the launcher and the website)
icons/              tool icons used by both
launcher/           Workbench, the SwiftUI launcher app (macOS 14+)
docs/               the website, served by GitHub Pages
scripts/            repo preparation, site build and publish scripts
```

### Build the launcher

```bash
cd launcher
./build.sh       # build/Workbench.app
./package.sh     # dist/Workbench-<version>.pkg, .dmg, .zip and How to Install.txt
```

Building needs Xcode installed, because SwiftUI's macro plugin ships only with Xcode.

### Add a tool to the suite

1. Publish the tool in its own repo, with a GitHub release that has a `.dmg`, a `.zip` containing the `.app`, or a `.pkg`.
2. Add an entry to `catalog.json` and an icon to `icons/<repo>.png`.
3. Run `scripts/build-site.sh` and push. Installed launchers pick up the new catalog the next time they check for updates.

### Website

The site in `docs/` is plain HTML. To publish it, open the repo's **Settings → Pages** and serve from `main` / `docs`. To preview it locally:

```bash
python3 -m http.server --directory docs 8790
```

## License

MIT. Each tool has its own LICENSE in its repo.
