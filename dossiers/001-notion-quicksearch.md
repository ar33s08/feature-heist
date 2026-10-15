# TEARDOWN #001 — Notion Desktop's ⌘K Quick Search
### What you pay for in a desktop app, and what it actually is. Produced with REA (open-source), rebuilt clean-room.

---

## The verdict in one line
Notion Desktop for macOS (v7.0.0) is a **thin Electron shell around the same web app you get free in a browser**. Its entire native value is five features — and the flagship one, global-hotkey Quick Search, is ~one overlay window + one OS hotkey. We rebuilt ours from observed behavior in a day. It's called **CommandOpen**, and it's faster.

## Scale of the teardown
| Metric | Value |
|---|---|
| Evidence graph | 147 MB JSON, 2,730 structural nodes, 45,396 semantic nodes |
| JS modules parsed | 2,209 |
| Browser windows defined | 14 |
| Context-bridge APIs | 19 (212 exposed members) |
| Native addons | 5 (better_sqlite3, mac_utils, win_utils, cf-prefs, progress_bar) |

## What we found (all with byte-offset receipts in `evidence.json`)

**1. Quick Search = a borderless always-on-top window + `globalShortcut.register`.**
The main bundle at offset 530694 (verbatim from the shipped binary):
```js
etState()),r=t.isQuickSearchEnabled,n=t.quickSearchShortcut,a=t.notionAiShortcut;
n&&(e&&r&&!o.globalShortcut.isRegistered(n)&&o.globalShortcut.register(n,()=>this.handleGlobalCommandSearchShortcutPres
```
Translation: if a shortcut is configured and enabled and not already taken, register the OS hotkey; on fire, show the overlay. There is no magic. Eight IPC channels (`notion:quick-search-open-result`, `-ready`, `-refresh`, `-set-search-assistant-mode`, …) exist to choreograph show/hide between main and renderer processes.

**2. "Offline mode" = a SQLite file + a sidecar server.**
A dedicated `SqliteServer.js` spawns a child process running better-sqlite3; the app even ships its own SQL inspection tool ("Sqlite Browser": `Table List`, `Table Contents`, `data-table` — found in the renderer bundle). Impressive-sounding, architecturally: one database and a `SELECT`.

**3. The rest of the "desktop app" is webchrome management.**
Tabs, preload bridges (`__desktopConfig`, `__platform`, `__mediaApi`, `__opener`, `__activityMonitorApi`), clipboard format negotiation, and auto-update plumbing. The documents themselves are rendered by a webcontents view of notion.so.

## What we rebuilt (clean-room, original code, one day)
**CommandOpen** — a native Swift overlay for any Mac:
- global ⌥Space hotkey (`RegisterEventHotKey`, same OS primitive the teardown found)
- borderless non-activating panel, floats over every app and full-screen space
- apps + Spotlight (`mdfind`) + fuzzy ranking + DuckDuckGo escape hatch
- **680×386 px, ~146 KB binary, zero Electron, ~5 MB RAM**
- engine test suite: 7/7 PASS on a real dev machine's app set

Run `./CommandOpen --engine-test` to see it, or just press ⌥Space anywhere.

## Legal posture
We read *behavior and structure*, we wrote every line ourselves, we ship no Notion code, assets, or trademarks, and this report is protected expression/commentary. Same posture every teardown publication takes. You are buying understanding and a working alternative, never a copy.

## Buy
Want a teardown + clean-room rebuild of a feature you love (or hate paying for)? **$49 per feature teardown dossier, $99 with the working standalone rebuild.** → heist.example.com *(swap: gum.co link)*

*Evidence: `evidence.json` (byte-offset slices), tool: `rea analyze-javascript-application app.asar --integrity-policy record-and-continue`.*
