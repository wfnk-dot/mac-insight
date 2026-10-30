# NOTES

## Part A build log (cloud session, 30 Oct 2026)

### Swift toolchain: failed twice, so I stopped and switched approach

The cloud container had no Swift compiler, and I couldn't get one:

1. **swift.org download:** blocked by the session's network policy (403).
2. **Docker Hub image:** rate-limited. I pulled the official `swift:6.0-noble`
   image from Google's Docker Hub mirror (`mirror.gcr.io`) instead, but running
   it was blocked by the session's permission rules.

Following the "fails twice, stop" rule, I didn't keep trying to get around it.
Instead:

- **What I did:** wrote InsightCore and its tests, and added a GitHub Actions
  workflow (`.github/workflows/test.yml`) that builds and runs every test on
  **Linux** (the official Swift 6.0 container) and on **macOS**. The workflow
  runs on every push. The results are on the repo's **Actions** tab.
- I checked the image-hash and crop-detection test numbers separately with a
  Python copy of the same maths.

**Options for next time:**

- **A. Use the CI results (current setup).** No local toolchain needed.
- **B. Allow download.swift.org** in the cloud environment's network settings,
  so a future cloud session can run `swift test` itself.
- **C. Run the tests on the Mac in Part B:** `cd ~/Documents/mac-insight && swift test`
  (needs Xcode or the Command Line Tools).

### Decisions worth knowing

- **Idle:** once there's been no input for 2+ minutes, the whole stretch since
  the last input stops counting as focused (not just the part after 2 minutes).
  Visible time still counts, because the windows really are on screen. After
  coming back, up to 1 minute may count as focused before the next snapshot
  shows it.
- **Screens asleep or locked:** nothing counts, focused or visible.
- **Keep suggestion:** the copy in the tidiest folder wins (Documents/Pictures
  beat Downloads/Desktop, and "copy"/"(1)" names lose); if that's a tie, the
  oldest copy. It's only a suggestion and nothing is pre-selected.
- **APFS clones:** the first file in a clone family counts its full size; the
  others count only their private (changed) bytes. In Duplicates, clones are
  tagged and count as 0 wasted space.
- **SHA-256** is written in plain Swift so the package needs only Foundation.
  Part B can switch to CryptoKit for speed (see INTEGRATION.md 2.1).
- **Time Machine snapshot sizes:** `tmutil` doesn't report them, so they appear
  as part of "Not found by the scan", with the number of snapshots noted.
