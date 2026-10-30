# Mac Insight

A personal Mac app that answers three questions:

1. **What is actually eating my SSD?** Including hidden files and "System Data".
2. **What are my duplicate files?** Exact copies, with similar/cropped versions tagged separately.
3. **Where does my time go?** Real app names, per screen, focused vs just open.

This repository currently holds **Part A: `InsightCore`**, the engine with all
the logic, as a Swift package with tests. Part B (the actual app and the tiny
time tracker) is built on the Mac and plugs into it; see
[INTEGRATION.md](INTEGRATION.md).

## What's inside

| Folder | What it does |
|---|---|
| `Sources/InsightCore/Disk` | Builds the disk map from scanned files, counts real on-disk size, avoids double-counting hard links and APFS clones, sorts files into "Explain my storage" buckets with a plain note each, lists the 100 biggest files, works out "changed since last scan", saves the cache, and lays out the treemap. |
| `Sources/InsightCore/Duplicates` | Finds exact duplicates (size → quick hash → full SHA-256), tags APFS clones, spots the same image at a different size (dHash/pHash), checks for crops, groups similar videos, and suggests which copy to keep. |
| `Sources/InsightCore/AppTime` | Turns app switches and once-a-minute snapshots into focused and visible time per app and per screen. It handles idle, sleep and screen lock, works out real app names (ExoCharts rather than "java"), and gives today/week/month in UK time, the hours-of-day chart and the day timeline. |
| `Tests/InsightCoreTests` | Tests with made-up data for every rule above. |

## Checking that it works (plain steps)

**Option 1: on GitHub (nothing to install)**

1. Open the repository on github.com.
2. Click the **Actions** tab.
3. Click the latest run called **InsightCore tests**.
4. A green tick next to **linux** and **macos** means every test passed.
   A red cross means something failed: click it to see which test.

**Option 2: on your Mac**

1. Open **Terminal** (Applications > Utilities > Terminal).
2. Paste this and press Return (only needed once, if you haven't already got it):
   ```bash
   git clone https://github.com/wfnk-dot/mac-insight.git ~/Documents/mac-insight
   ```
3. Then paste this and press Return:
   ```bash
   cd ~/Documents/mac-insight && swift test
   ```
4. Wait a minute. The last line should say something like
   **"Executed 100 tests, with 0 failures"**.

If macOS asks to install developer tools, click **Install** and try step 3 again.

## Promises the app keeps

- Does nothing unless you open it; scans only when you click Scan.
- Never deletes anything by itself. The only actions are Reveal in Finder and
  Move to Trash, always with a confirm. It never empties the Trash.
- The time tracker is tiny, event-driven and doesn't record your screen.
- Nothing leaves your Mac.
