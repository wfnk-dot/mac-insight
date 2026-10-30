# INTEGRATION: how Part B feeds macOS data into InsightCore

InsightCore is a pure Swift package (Foundation only). It never touches the
file system, windows or processes itself, except `LocalFileContentSource`,
which reads file bytes for hashing. Part B (the SwiftUI app and the tracker
agent) collects macOS data, turns it into the plain structs below, and shows
the results.

Add the package to the Xcode project: **File > Add Package Dependencies… >
Add Local…** and pick this repository folder. Link `InsightCore` into both the
app target and the tracker agent target.

```swift
import InsightCore
```

---

## 1. Disk Map

### 1.1 Scanning (app, only after the user clicks Scan)

Walk the startup disk with `getattrlistbulk` (much faster than
`FileManager.enumerator`). For every entry, make one `FileRecord`:

| `FileRecord` field | Where it comes from |
|---|---|
| `path` | Full path. Any Unicode form; InsightCore normalises to NFC. |
| `logicalSize` | `ATTR_FILE_DATALENGTH` (or `st_size`) |
| `allocatedSize` | `ATTR_FILE_ALLOCSIZE`. This is the real on-disk size, correct for sparse and compressed files. Leave nil only if unavailable. |
| `device` | `ATTR_CMN_DEVID` (or `st_dev`) |
| `inode` | `ATTR_CMN_FILEID` (or `st_ino`) |
| `linkCount` | `ATTR_FILE_LINKCOUNT` (or `st_nlink`) |
| `cloneID` | `ATTR_CMNEXT_CLONEID` (request with `ATTR_CMN_RETURNED_ATTRS` + `forkattr`/`commonattr` ext). nil if not cloned. |
| `privateSize` | `ATTR_CMNEXT_PRIVATESIZE`: bytes not shared with clones. Optional. |
| `modified` | `ATTR_CMN_MODTIME` |
| `isDirectory` | `ATTR_CMN_OBJTYPE == VDIR`. Send folders too, so empty folders show up. |

Rules for the walk:

- **Don't follow symlinks.** Record the link itself (it's tiny) and move on.
- **Stay on the startup volume group** unless the user ticked other volumes:
  skip anything under `/Volumes/` and skip mount points whose device differs
  from `/` *and* from `/System/Volumes/Data`.
- **Firmlinks:** macOS shows the Data volume both at `/Users` and at
  `/System/Volumes/Data/Users`. Either skip `/System/Volumes/Data` during the
  walk (faster) or let InsightCore fold it: `PathUtils.normalize` maps
  `/System/Volumes/Data/X` to `/X`, and records with the same device + inode +
  path count once.
- **Hard links and clones** are handled by `SpaceAccounting` (first record of
  an inode counts; later paths count 0; later members of a clone family count
  only their `privateSize`). Just pass the attributes.
- **Unreadable folders** (`EACCES`/`EPERM`): add the path to
  `VolumeFacts.unreadableFolders` and carry on.
- **Progress and cancel:** the walk is Part B's loop. Update the progress bar
  every ~2,000 entries and check a cancel flag between directories. Run it on a
  background `Task` with `.utility` priority.

Then:

```swift
let result = DiskTreeBuilder(rootPath: "/").build(records)
// result.root        -> DiskItem tree (treemap + sortable list)
// result.biggestFiles -> top 100 single files
// result.accounted   -> files with de-duplicated byte counts
```

### 1.2 Volume facts

```swift
let url = URL(fileURLWithPath: "/")
let v = try url.resourceValues(forKeys: [
    .volumeTotalCapacityKey,
    .volumeAvailableCapacityKey,
    .volumeAvailableCapacityForImportantUsageKey,
])
let used = Int64(v.volumeTotalCapacity!) - Int64(v.volumeAvailableCapacity!)
let purgeable = max(0, v.volumeAvailableCapacityForImportantUsage! - Int64(v.volumeAvailableCapacity!))
```

Time Machine local snapshots: run `/usr/bin/tmutil listlocalsnapshots /` with
`Process`, and parse with `TMUtilParser.parseLocalSnapshots(output)`. tmutil
does not report snapshot sizes; leave `snapshotBytes` nil and the unexplained
remainder appears as "Not found by the scan" with the snapshot count noted.

Full Disk Access: there is no API to ask. Test by trying to read a protected
path, e.g. `FileManager.default.isReadableFile(atPath: NSHomeDirectory() + "/Library/Mail")`
or opening `~/Library/Safari/Bookmarks.plist`. If it fails, set
`hasFullDiskAccess: false`, and show the explanation with a button that opens
`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.

```swift
let facts = VolumeFacts(
    usedBytes: used,
    purgeableBytes: purgeable,
    snapshots: TMUtilParser.parseLocalSnapshots(tmutilOutput),
    hasFullDiskAccess: fdaOK,
    unreadableFolders: unreadable
)
let summary = StorageSummary.make(
    files: result.accounted,
    classifier: BucketClassifier(home: NSHomeDirectory()),  // obsFolders: optional
    facts: facts
)
// summary.warning      -> banner at the top (nil when complete)
// summary.buckets      -> "Explain my storage" rows: title, note, advice, bytes
// summary.coverage     -> e.g. 0.97 = the scan explains 97% of used space
```

If OBS records somewhere other than `~/Movies/OBS`, read OBS's setting from
`~/Library/Application Support/obs-studio/basic/profiles/*/basic.ini`
(`RecFilePath=`) and pass it as `obsFolders`. OBS's default file names
("2026-10-30 14-05-33.mkv") directly in `~/Movies` are recognised anyway.

### 1.3 Treemap

```swift
let rects = Treemap.layout(sizes: item.children.map { Double($0.size) },
                           in: TreemapRect(x: 0, y: 0, width: w, height: h))
```

Rectangles come back in the same order as `children`. Zoom = show
`root.descendant(breadcrumbNames)`; the breadcrumb is just the list of names.

### 1.4 Cache and "changed since last scan"

```swift
let cache = DiskScanCache(result: result, summary: summary, scannedAt: Date(), hadFullDiskAccess: fdaOK)
try cache.encoded().write(to: cacheURL, options: .atomic)
// ~/Library/Application Support/Mac Insight/last-scan.json
```

On launch, `try DiskScanCache.decode(data)`. If it throws, ignore the cache
(and say "No scan yet"). Before overwriting with a new scan:

```swift
let grew = oldCache.grewSince(newFolderSizes: result.root.folderSizes(maxDepth: oldCache.folderDepth))
```

### 1.5 Actions

Only two: **Reveal in Finder** (`NSWorkspace.shared.activateFileViewerSelecting`)
and **Move to Trash** (`FileManager.default.trashItem`), always after an
`NSAlert` confirm listing the items and total size. Never empty the Trash.
Never delete anything automatically.

---

## 2. Duplicates (app, only after the user clicks Scan)

### 2.1 Exact duplicates

Build `DuplicateCandidate`s for regular files in the chosen folders (default:
home minus `~/Library`). Skip packages' insides if you like (`.photoslibrary`,
`.imovielibrary`), since their contents must be managed by their app.

| field | source |
|---|---|
| `path`, `size` | as for the disk scan (`logicalSize`) |
| `created` | `ATTR_CMN_CRTIME` |
| `modified` | `ATTR_CMN_MODTIME` |
| `device`, `inode`, `cloneID` | as for the disk scan |

```swift
var finder = DuplicateFinder(home: NSHomeDirectory())
finder.progress = { stage, done, total in /* update UI on main actor */ }
finder.isCancelled = { cancelFlag.isSet }
let found = try finder.find(candidates)
// found.summary -> "4.2 GB in exact duplicates"
```

`LocalFileContentSource` reads with `FileHandle`. For speed on the Mac, wrap it
and override `fullHash` with CryptoKit; digests are identical:

```swift
struct FastSource: FileContentSource {
    let base = LocalFileContentSource()
    func read(path: String, offset: Int64, length: Int) throws -> Data { try base.read(path: path, offset: offset, length: length) }
    func fullHash(path: String, size: Int64) throws -> String {
        var h = SHA256()
        let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? fh.close() }
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { h.update(data: chunk) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

### 2.2 Same image, different size or format

For each image (one per exact group, so exact copies aren't repeated):

1. Make a small thumbnail with ImageIO: `CGImageSourceCreateThumbnailAtIndex`
   with `kCGImageSourceThumbnailMaxPixelSize: 256` and
   `kCGImageSourceCreateThumbnailFromImageAlways: true`.
2. Draw it into an 8-bit greyscale `CGContext` (`CGColorSpaceCreateDeviceGray()`,
   `CGImageAlphaInfo.none.rawValue`), copy the bytes row by row (watch
   `bytesPerRow` padding) into `[UInt8]`, and make `GreyImage(width:height:pixels:)`.
3. `ImageFingerprint(file: candidate, image: grey, pixelWidth: realW, pixelHeight: realH)`.

Then `SimilarMedia.sameImageGroups(fingerprints, home: NSHomeDirectory())`.
`ImageMatchPolicy` defaults: dHash ≤ 10 and pHash ≤ 10 bits (inclusive).

### 2.3 Cropped / edited versions

Only for pictures not already grouped above. Use Vision:

```swift
let req = VNGenerateImageFeaturePrintRequest()
try VNImageRequestHandler(cgImage: thumb).perform([req])
let print = req.results!.first!
var distance: Float = 0
try printA.computeDistance(&distance, to: printB)
```

Compare pairs whose distance is ≤ 0.5 (tune on Wyn's photos). For those,
run `CropMatcher().findCrop(smallerGrey, in: largerGrey)` (`isCrop` = result
is non-nil). Feed `VisualPairCheck`s to
`SimilarMedia.croppedOrEditedGroups(checks, files:, excludePairsWithin: sameImageGroups)`.
To keep it quick, only compare pictures with similar capture dates or within
the same folder tree, and cache feature prints by path + modified date.

### 2.4 Similar videos

With AVFoundation: `AVURLAsset(url:).load(.duration)` and the first frame via
`AVAssetImageGenerator.image(at: .zero)` (thumbnail size ~256), then
`PerceptualHash.dHash(grey)`. Feed `VideoFingerprint`s to
`SimilarMedia.similarVideoGroups(_:)` (±1 s, frame hash ≤ 10 bits). Tag only.

### 2.5 Showing groups

`DuplicateFilters()` starts with **Exact only** on and **Show similar images**
off. Bind the two toggles to `setExactOnly(_:)` and `setShowSimilarImages(_:)`,
and show `filters.visible(allGroups)`. In each group, `files[0]` is the
suggested keeper (`keepReason` says why); show a "Keep" badge on it. Nothing
is pre-selected. Thumbnails: `QLThumbnailGenerator`.

---

## 3. App Time

### 3.1 The tracker agent (always on, must stay tiny)

A login item (`SMAppService.loginItem(identifier:)`), `LSUIElement = YES`
(no Dock icon, no menu bar icon). It does only this:

- **App switches:** observe `NSWorkspace.didActivateApplicationNotification`.
  Resolve the name (below) and write an `ActivationEvent`. Write one for the
  current frontmost app at start-up too.
- **Once a minute** (`DispatchSourceTimer`, 60 s, `leeway` 10 s so macOS can
  coalesce wake-ups) take one snapshot:
  - `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`.
    Keep windows with `kCGWindowLayer == 0` and alpha > 0. For each window,
    find the screens its `kCGWindowBounds` intersects (`NSScreen.screens`
    frames, flipped to CG coordinates); the list is already front-to-back, so
    the first app seen on a screen is its frontmost.
  - The focused window's screen: the screen of the first layer-0 window owned
    by the frontmost app's pid.
  - Idle: `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)`.
  - Screen IDs: `CGDisplayCreateUUIDFromDisplayID(displayID)` as a string, so
    names survive reboots and re-plugging. `screenName`: `NSScreen.localizedName`.
  - Write a `MinuteSnapshot`.
- **System events:** `NSWorkspace.willSleepNotification` (`.sleep`),
  `didWakeNotification` (`.wake`), `screensDidSleepNotification`
  (`.screensSlept`), `screensDidWakeNotification` (`.screensWoke`),
  distributed `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`
  (`.screenLocked` / `.screenUnlocked`), and `.trackerStarted` /
  `.trackerStopped` at launch / quit.
- **Pause the minute timer while asleep or screens are off**, so it does
  nothing at all then.

No screen recording, no Accessibility needed for window *owners and bounds*
(window titles are not used).

### 3.2 Real app names

For each activation, build `ProcessRecord`s for the app's pid and its
ancestors:

| field | source |
|---|---|
| `pid`, `localizedName`, `bundleIdentifier` | `NSRunningApplication` |
| `executablePath` | `proc_pidpath(pid, …)` |
| `parentPID` | `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)` → `pbi_ppid` |
| `responsiblePID` | `responsibility_get_pid_responsible_for_pid(pid)` (private libSystem symbol; load with `dlsym`, and skip if missing) |
| `arguments` | `sysctl([CTL_KERN, KERN_PROCARGS2, pid])`; only for processes whose name is generic (`AppNameResolver.genericNames`) |

```swift
let name = resolver.resolve(pid: app.processIdentifier, processes: records)
```

Cache the result per pid so each app is resolved once. Overrides live in
`~/Library/Application Support/Mac Insight/app-names.json` as
`[AppNameOverride]` (JSON-codable); the app's report screen lets Wyn add one
with a click ("Rename this app…").

### 3.3 Storage (SQLite)

`~/Library/Application Support/Mac Insight/time.sqlite`, opened with the
system `libsqlite3` (`import SQLite3`). Create with `TrackerStorage.schema`.
For each record:

```swift
let row = try TrackerStorage.encode(record)  // time REAL, kind TEXT, payload TEXT
// INSERT INTO records (time, kind, payload) VALUES (?, ?, ?)
```

Use WAL mode, one prepared statement, and no transaction batching needed at
this rate (~1 row a minute plus app switches). Once a day (at the first
snapshot after midnight) run `TrackerStorage.pruneSQL(now:)` to keep one year.

### 3.4 The report (in the app)

```swift
let rows = /* SELECT time, kind, payload FROM records WHERE time >= ? ORDER BY time */
let records = try rows.map(TrackerStorage.decode)
let agg = TimeAggregator()                    // UK time, idle 2 min
let tracked = agg.track(records)
let today = agg.report(tracked, .today, now: Date(), screenNames: savedNames)
let week  = agg.report(tracked, .thisWeek, now: Date(), screenNames: savedNames)
let month = agg.report(tracked, .thisMonth, now: Date(), screenNames: savedNames)
let bars  = agg.dayTimeline(tracked, day: Date(), screenNames: savedNames)
```

- `report.apps`: per app, `focused` and `visible` seconds (`DurationFormat.string`).
- `report.screens[i].summaryLine()`: "Widescreen: TradingView 31h, ExoCharts 6h".
- `report.hoursOfDay`: 24 values of focused seconds, for the "when am I at the desk" chart.
- `bars.screens[i].segments`: one horizontal bar per screen.

Load from one day before the period start, so focus that began before the
period is known. `savedNames` is Wyn's own names for screens (e.g. Arzopa),
keyed by display UUID.

---

## 4. Rules Part B must keep

- The app does nothing until opened; scans only on a click.
- The tracker: event-driven, one cheap snapshot a minute, < 0.5% CPU,
  < 25 MB RAM. Verify with Activity Monitor and `top -pid <pid>` over an hour.
- Never delete automatically. Only Reveal in Finder and Move to Trash (with
  confirm). Never empty the Trash.
- Mouse only: no keyboard shortcuts (don't add `.keyboardShortcut`).
- No cloud upload, no screen recording, no browser history, no notifications.
