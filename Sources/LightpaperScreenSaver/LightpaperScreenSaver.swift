import AppKit
import ImageIO
import ScreenSaver
import SQLite3

private enum SourceKind: Sendable {
    case original
    case preview
}

private struct SourceDirectory: Sendable {
    let source: SourceKind
    let directory: URL
}

private struct TileItem: Sendable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
    // 64-bit difference hash of a tiny grayscale rendition, used to spot
    // visually near-identical shots. `nil` when the image couldn't be decoded.
    let hash: UInt64?
}

private final class CachedCGImage {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

private struct SkylineSegment {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat

    var maxX: CGFloat {
        x + width
    }
}

private let defaultImageLimit = 6000
private let previewImageLimit = 500
// Admits 640px renditions while still excluding the tiny 320px thumbnails.
private let minimumTileLongEdge = 560

// Upper bound on photos sampled for one screen. Tiles are capped to native
// resolution (never upscaled), so a dense screen of small previews can need
// ~100; the layout uses only as many as it takes to fill the screen and ignores
// the rest.
private let photosPerScreen = 140
// Sample extra photos from the chosen month so that, after near-duplicate
// removal culls the burst frames and look-alikes a single month naturally has,
// there are still enough left to fill the screen from that one month. The layout
// uses only what it needs and ignores the surplus.
private let sampleCandidateLimit = 240
// Only previews whose long edge is at least this many pixels are eligible, so
// enlarged mosaic tiles stay reasonably crisp. 640 covers most months.
private let minimumRenditionLongSide = 640.0

// Two tiles whose 64-bit difference hashes differ by at most this many bits are
// treated as the same shot (e.g. consecutive frames from a burst) and are not
// placed on one screen together. Identical frames score 0; unrelated scenes
// typically sit well above 20, so this stays clear of false positives.
private let nearDuplicateHammingThreshold = 10

private final class LightpaperTiledView: NSView {
    private var items: [TileItem]
    private var tileFrames: [NSRect] = []
    private var laidOutWidth: CGFloat = 0
    private var laidOutViewportHeight: CGFloat = 0
    private var laidOutScale: CGFloat = 0
    private let imageCache = NSCache<NSURL, CachedCGImage>()

    init(items: [TileItem]) {
        self.items = items
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageCache.countLimit = 240
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    func appendItems(_ newItems: [TileItem]) {
        guard !newItems.isEmpty else {
            return
        }
        items.append(contentsOf: newItems)
        invalidateTileLayout()
        needsLayout = true
        needsDisplay = true
    }

    var pageCount: Int {
        updateTileLayout()
        let height = viewportHeight()
        return max(Int(floor(frame.height / height)), 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        updateTileLayout()

        let backing = max(window?.backingScaleFactor ?? laidOutScale, 1)
        for (index, frame) in tileFrames.enumerated() where frame.intersects(dirtyRect) {
            let maxPixelSize = Int(ceil(max(frame.width, frame.height) * backing))
            guard let image = cachedImage(for: items[index], maxPixelSize: maxPixelSize)?.image,
                  let context = NSGraphicsContext.current?.cgContext else {
                continue
            }
            draw(image, in: frame, context: context)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateTileLayout()
    }

    private func draw(_ image: CGImage, in frame: NSRect, context: CGContext) {
        let imageSize = NSSize(width: image.width, height: image.height)
        let scale = max(frame.width / imageSize.width, frame.height / imageSize.height)
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawFrame = NSRect(
            x: (frame.width - drawSize.width) / 2,
            y: (frame.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        context.draw(image, in: drawFrame)
        context.restoreGState()
    }

    private func updateTileLayout() {
        let availableWidth = max(enclosingScrollView?.contentView.bounds.width ?? bounds.width, 1)
        let availableHeight = viewportHeight()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        guard tileFrames.isEmpty
                || abs(availableWidth - laidOutWidth) > 0.5
                || abs(availableHeight - laidOutViewportHeight) > 0.5
                || abs(scale - laidOutScale) > 0.01 else {
            return
        }

        laidOutWidth = availableWidth
        laidOutViewportHeight = availableHeight
        laidOutScale = scale
        tileFrames.removeAll(keepingCapacity: true)
        updateEditorialLayout(availableWidth: availableWidth, scale: scale)
    }

    private func invalidateTileLayout() {
        tileFrames.removeAll(keepingCapacity: true)
        laidOutWidth = 0
        laidOutViewportHeight = 0
        laidOutScale = 0
    }

    private func updateEditorialLayout(availableWidth: CGFloat, scale: CGFloat) {
        let viewportHeight = viewportHeight()
        let targetHeights = [
            min(max(viewportHeight * 0.62, 380), 760),
            min(max(viewportHeight * 0.36, 240), 440),
            min(max(viewportHeight * 0.52, 320), 620),
            min(max(viewportHeight * 0.28, 190), 340),
            min(max(viewportHeight * 0.46, 300), 540),
            min(max(viewportHeight * 0.34, 220), 420)
        ]
        // 1. Compose justified rows, packing enough images into each row that its
        //    height never exceeds the smallest native size in the row — so no
        //    image is ever scaled above its own resolution. Low-res photos simply
        //    end up in denser rows. Stop once we have enough rows to overshoot one
        //    screen.
        typealias RowEntry = (item: TileItem, nativeWidth: CGFloat, nativeHeight: CGFloat)
        var rows: [(entries: [RowEntry], height: CGFloat)] = []
        var cursor = 0
        var rowIndex = 0
        var totalHeight: CGFloat = 0

        while cursor < items.count {
            var entries: [RowEntry] = []
            var rowAspect: CGFloat = 0
            var minNativeHeight = CGFloat.greatestFiniteMagnitude
            let target = targetHeights[rowIndex % targetHeights.count]
            var settled = false

            while cursor < items.count {
                let item = items[cursor]
                let size = nativeSize(for: item, scale: scale)
                entries.append((item, size.width, size.height))
                rowAspect += size.width / size.height
                minNativeHeight = min(minNativeHeight, size.height)
                cursor += 1

                // Settle once the row is short enough both for the aesthetic
                // target and to keep every image at or below native resolution.
                if availableWidth / rowAspect <= min(target, minNativeHeight) {
                    settled = true
                    break
                }
            }

            if !settled {
                // Ran out of images mid-row; drop this partial row unless it is
                // all we have, so the bottom never shows a stretched fragment.
                if rows.isEmpty, !entries.isEmpty {
                    let height = min(availableWidth / rowAspect, minNativeHeight)
                    rows.append((entries, height))
                    totalHeight += height
                }
                break
            }

            // Natural justified height, capped so the lowest-res image in the row
            // is never enlarged past its native size.
            let height = min(availableWidth / rowAspect, minNativeHeight)
            rows.append((entries, height))
            totalHeight += height
            rowIndex += 1

            if totalHeight >= viewportHeight {
                break
            }
        }

        // 2. Scale the rows to fill the screen, but only ever downscale. When
        //    there are enough photos the rows overshoot one screen and shrink to
        //    fit; when a month (plus spillover) is too small to fill, the bottom
        //    is left dark rather than upscaling anything.
        let fill = totalHeight > 0 ? min(1, viewportHeight / totalHeight) : 1
        var y: CGFloat = 0
        for row in rows {
            let height = row.height * fill
            appendRow(row.entries, y: y, height: height, availableWidth: availableWidth)
            y += height
        }

        frame = NSRect(x: 0, y: 0, width: availableWidth, height: viewportHeight)
    }

    private func appendRow(
        _ row: [(item: TileItem, nativeWidth: CGFloat, nativeHeight: CGFloat)],
        y: CGFloat,
        height: CGFloat,
        availableWidth: CGFloat
    ) {
        let rowAspect = row.reduce(CGFloat(0)) { result, entry in
            result + entry.nativeWidth / entry.nativeHeight
        }
        var x: CGFloat = 0

        for (index, entry) in row.enumerated() {
            let width = index == row.count - 1
                ? availableWidth - x
                : availableWidth * ((entry.nativeWidth / entry.nativeHeight) / rowAspect)
            tileFrames.append(NSRect(x: x, y: y, width: width, height: height))
            x += width
        }
    }

    private func viewportHeight() -> CGFloat {
        max(enclosingScrollView?.contentView.bounds.height ?? bounds.height, 1)
    }

    private func nativeSize(for item: TileItem, scale: CGFloat) -> NSSize {
        NSSize(
            width: max(CGFloat(item.pixelWidth) / scale, 1),
            height: max(CGFloat(item.pixelHeight) / scale, 1)
        )
    }

    private func cachedImage(for item: TileItem, maxPixelSize: Int) -> CachedCGImage? {
        let key = item.url as NSURL
        // Decode only as large as the tile needs, and never larger than the
        // image's own resolution — keeps decoding fast and memory bounded across
        // a dense screenful of tiles.
        let target = max(min(maxPixelSize, max(item.pixelWidth, item.pixelHeight)), 1)

        if let image = imageCache.object(forKey: key),
           max(image.image.width, image.image.height) >= Int(Double(target) * 0.9) {
            return image
        }

        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else {
            return nil
        }

        let image = CachedCGImage(cgImage)
        imageCache.setObject(image, forKey: key)
        return image
    }
}

/// A self-running "indexing your library" placeholder: a centered mosaic of
/// pastel tiles that shimmer in a diagonal wave, with a caption beneath. Shown
/// while images are read off disk so the screen is never just black.
private final class IndexingAnimationView: NSView {
    private var tileLayers: [CALayer] = []
    private let captionLayer = CATextLayer()
    private let columns = 7
    private let rows = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        captionLayer.string = "Indexing your library…"
        captionLayer.alignmentMode = .center
        captionLayer.foregroundColor = NSColor(white: 0.78, alpha: 1).cgColor
        captionLayer.font = NSFont.systemFont(ofSize: 17, weight: .medium)
        captionLayer.fontSize = 17
        captionLayer.contentsScale = scale
        layer?.addSublayer(captionLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        rebuildTiles()
    }

    private func rebuildTiles() {
        guard let hostLayer = layer, bounds.width > 1, bounds.height > 1 else {
            return
        }

        tileLayers.forEach { $0.removeFromSuperlayer() }
        tileLayers.removeAll(keepingCapacity: true)

        let block = min(bounds.width, bounds.height) * 0.32
        let spacing = block * 0.06
        let tileSize = (block - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let gridWidth = tileSize * CGFloat(columns) + spacing * CGFloat(columns - 1)
        let gridHeight = tileSize * CGFloat(rows) + spacing * CGFloat(rows - 1)
        let originX = (bounds.width - gridWidth) / 2
        let originY = (bounds.height - gridHeight) / 2 + block * 0.12

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for row in 0..<rows {
            for col in 0..<columns {
                let tile = CALayer()
                let x = originX + CGFloat(col) * (tileSize + spacing)
                let y = originY + CGFloat(row) * (tileSize + spacing)
                tile.frame = CGRect(x: x, y: y, width: tileSize, height: tileSize)
                tile.cornerRadius = tileSize * 0.18

                // Soft pastel gradient from cyan through violet to pink.
                let hue = (0.55 + CGFloat(col) / CGFloat(columns) * 0.5)
                    .truncatingRemainder(dividingBy: 1)
                tile.backgroundColor = NSColor(hue: hue, saturation: 0.45, brightness: 0.96, alpha: 1).cgColor
                tile.opacity = 0.18
                hostLayer.insertSublayer(tile, below: captionLayer)
                tileLayers.append(tile)

                let shimmer = CABasicAnimation(keyPath: "opacity")
                shimmer.fromValue = 0.16
                shimmer.toValue = 0.95
                shimmer.duration = 0.9
                shimmer.autoreverses = true
                shimmer.repeatCount = .infinity
                shimmer.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                shimmer.timeOffset = Double(col + row) * 0.16
                tile.add(shimmer, forKey: "shimmer")
            }
        }

        let captionHeight: CGFloat = 24
        captionLayer.frame = CGRect(
            x: 0,
            y: originY - block * 0.18 - captionHeight,
            width: bounds.width,
            height: captionHeight
        )

        CATransaction.commit()
    }
}

@objc(LightpaperScreenSaverView)
public final class LightpaperScreenSaverView: ScreenSaverView {
    private var indexingView: IndexingAnimationView?
    private var currentGallery: NSScrollView?
    private var monthCatalog: MonthCatalog?
    private var fallbackPool: [URL] = []
    private var lastMonth: String?
    private var isLoading = false
    private var isSwapping = false
    private var didStart = false

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    public override var hasConfigureSheet: Bool {
        false
    }

    public override var configureSheet: NSWindow? {
        nil
    }

    public override func startAnimation() {
        super.startAnimation()
        if !didStart && !isLoading {
            didStart = true
            buildCatalog()
        }
    }

    public override func animateOneFrame() {
        showNextMonth(animated: true)
    }

    public override func layout() {
        super.layout()
        indexingView?.frame = bounds
        currentGallery?.frame = bounds
        currentGallery?.documentView?.layoutSubtreeIfNeeded()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = isPreview ? 6 : 9
    }

    private func buildCatalog() {
        isLoading = true
        showIndexingAnimation()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let accounts = findCatalogAccounts()
            var catalog = buildMonthCatalog(accounts: accounts, minLongSide: minimumRenditionLongSide)

            if let catalog {
                // Persist the index whenever Lightroom's previews.db is readable,
                // so we can keep grouping by month later.
                saveCatalogCache(catalog)
            } else {
                // previews.db is gone (Lightroom removes it while running). Reuse
                // the last index we saved so screens stay grouped by month instead
                // of dropping to random sampling.
                catalog = loadCatalogCache()
            }

            // Fall back to whole-library random sampling only if neither a fresh
            // nor a cached catalog is available, so the saver still shows something.
            var pool: [URL] = []
            if catalog == nil {
                let sources = collectSourceDirectories()
                pool = collectCandidateURLs(from: sources, limit: defaultImageLimit, excluding: [])
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isLoading = false
                self.monthCatalog = catalog
                self.fallbackPool = pool
                self.showNextMonth(animated: false)
            }
        }
    }

    /// Picks a fresh month at random (different from the one currently shown),
    /// samples photos from it, and cross-fades them in as the new screen.
    private func showNextMonth(animated: Bool) {
        guard !isSwapping else {
            return
        }
        let sample = nextSampleURLs()
        guard !sample.isEmpty else {
            return
        }
        isSwapping = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = deduplicateByLook(sample.compactMap(loadTileItem))
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isSwapping = false
                guard !items.isEmpty else {
                    return
                }
                self.presentGallery(items: items, animated: animated)
            }
        }
    }

    private func nextSampleURLs() -> [URL] {
        guard let catalog = monthCatalog, !catalog.months.isEmpty else {
            return Array(fallbackPool.shuffled().prefix(photosPerScreen))
        }

        let months = catalog.months
        let month = randomMonth(excluding: lastMonth, from: months)
        lastMonth = month

        var result = (catalog.pathsByMonth[month] ?? []).shuffled()
        // If the chosen month is too small to fill the screen without upscaling,
        // overrun into the nearest neighbouring months (closest first) until
        // there are enough photos.
        if let center = months.firstIndex(of: month) {
            var step = 1
            while result.count < photosPerScreen, step < months.count {
                for neighbor in [center - step, center + step] where neighbor >= 0 && neighbor < months.count {
                    result.append(contentsOf: (catalog.pathsByMonth[months[neighbor]] ?? []).shuffled())
                    if result.count >= photosPerScreen {
                        break
                    }
                }
                step += 1
            }
        }

        return Array(result.prefix(sampleCandidateLimit))
    }

    private func randomMonth(excluding excluded: String?, from months: [String]) -> String {
        guard months.count > 1, let excluded else {
            return months.randomElement() ?? months[0]
        }
        let candidates = months.filter { $0 != excluded }
        return candidates.randomElement() ?? months[0]
    }

    private func presentGallery(items: [TileItem], animated: Bool) {
        hideIndexingAnimation()

        let gallery = makeGallery(items: items)
        gallery.frame = bounds
        gallery.autoresizingMask = [.width, .height]
        addSubview(gallery)
        gallery.documentView?.layoutSubtreeIfNeeded()

        let previous = currentGallery
        currentGallery = gallery

        if animated {
            gallery.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1.0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                gallery.animator().alphaValue = 1
                previous?.animator().alphaValue = 0
            } completionHandler: {
                previous?.removeFromSuperview()
            }
        } else {
            previous?.removeFromSuperview()
        }
    }

    private func makeGallery(items: [TileItem]) -> NSScrollView {
        let tiledView = LightpaperTiledView(items: items)
        let scrollView = NSScrollView(frame: bounds)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = tiledView
        return scrollView
    }

    private func showIndexingAnimation() {
        guard indexingView == nil else {
            return
        }
        let view = IndexingAnimationView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        indexingView = view
    }

    private func hideIndexingAnimation() {
        guard let view = indexingView else {
            return
        }
        indexingView = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            view.animator().alphaValue = 0
        } completionHandler: {
            view.removeFromSuperview()
        }
    }
}

// MARK: - Lightroom catalog (month index)

/// Preview URLs grouped by capture month ("YYYY-MM"), read from the Lightroom
/// catalog. The capture date is not stored in the preview files themselves
/// (they are hash-named and EXIF-stripped), so it is recovered from the
/// `Managed Catalog.mcat` SQLite database and joined to on-disk previews via
/// `previews.db`.
private struct MonthCatalog {
    let months: [String]
    let pathsByMonth: [String: [URL]]
}

/// On-disk form of `MonthCatalog` (URLs flattened to paths) so the last good
/// index survives across launches — and across periods when Lightroom is running
/// and has removed `previews.db`.
private struct CachedCatalog: Codable {
    let months: [String]
    let pathsByMonth: [String: [String]]
}

private func catalogCacheURL() -> URL? {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
        return nil
    }
    return caches
        .appendingPathComponent("dev.lightpaper.Lightpaper", isDirectory: true)
        .appendingPathComponent("month-catalog.json")
}

/// Best-effort: writes the freshly built index to disk so it can be reused while
/// Lightroom is running. Failures are ignored — the cache is an optimisation.
private func saveCatalogCache(_ catalog: MonthCatalog) {
    guard let url = catalogCacheURL() else {
        return
    }
    let payload = CachedCatalog(
        months: catalog.months,
        pathsByMonth: catalog.pathsByMonth.mapValues { $0.map(\.path) }
    )
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
    } catch {
        // Ignore: a missing cache just means we rebuild or fall back next time.
    }
}

/// Reads the last index we saved. Stale preview paths are harmless — `loadTileItem`
/// skips any file that no longer exists.
private func loadCatalogCache() -> MonthCatalog? {
    guard let url = catalogCacheURL(),
          let data = try? Data(contentsOf: url),
          let payload = try? JSONDecoder().decode(CachedCatalog.self, from: data),
          !payload.months.isEmpty else {
        return nil
    }
    let pathsByMonth = payload.pathsByMonth.mapValues { paths in
        paths.map { URL(fileURLWithPath: $0) }
    }
    return MonthCatalog(months: payload.months, pathsByMonth: pathsByMonth)
}

/// Account folders that contain both the rendition map and the catalog.
private func findCatalogAccounts() -> [URL] {
    guard let libraryURL = defaultLibraryCandidates().first(where: { url in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }) else {
        return []
    }

    guard let children = try? FileManager.default.contentsOfDirectory(
        at: libraryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    return children.filter { child in
        FileManager.default.fileExists(atPath: child.appendingPathComponent("previews.db").path)
            && FileManager.default.fileExists(atPath: child.appendingPathComponent("Managed Catalog.mcat").path)
    }
}

private func openReadOnlyDatabase(_ url: URL) -> OpaquePointer? {
    var db: OpaquePointer?
    // `immutable=1` skips locking and the -wal, so we can read even while
    // Lightroom holds the database open.
    let uri = url.absoluteString + "?immutable=1"
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return nil
    }
    return db
}

/// Extracts the capture month ("YYYY-MM") from an asset's MessagePack content
/// blob. The value is stored as `captureDate` followed by a MessagePack
/// fixstr (`0xA0...0xBF` length marker) holding an ISO 8601 timestamp.
private func captureMonth(in bytes: UnsafeRawBufferPointer) -> String? {
    let key = Array("captureDate".utf8)
    let buffer = bytes.bindMemory(to: UInt8.self)
    let count = buffer.count
    let keyCount = key.count
    guard count > keyCount + 8 else {
        return nil
    }

    var i = 0
    let limit = count - keyCount
    while i <= limit {
        if buffer[i] == key[0] {
            var k = 1
            while k < keyCount && buffer[i + k] == key[k] {
                k += 1
            }
            if k == keyCount {
                let marker = buffer[i + keyCount]
                guard marker >= 0xA0, marker <= 0xBF else {
                    return nil
                }
                let length = Int(marker - 0xA0)
                let start = i + keyCount + 1
                guard length >= 7, start + 7 <= count else {
                    return nil
                }
                var chars = [UInt8](repeating: 0, count: 7)
                for j in 0..<7 {
                    chars[j] = buffer[start + j]
                }
                guard chars[4] == UInt8(ascii: "-"),
                      let month = String(bytes: chars, encoding: .ascii) else {
                    return nil
                }
                return month
            }
        }
        i += 1
    }
    return nil
}

private func buildMonthCatalog(accounts: [URL], minLongSide: Double) -> MonthCatalog? {
    var pathsByMonth: [String: [URL]] = [:]

    for account in accounts {
        let previewsURL = account.appendingPathComponent("previews.db")
        let catalogURL = account.appendingPathComponent("Managed Catalog.mcat")

        // 1. Best (largest) qualifying rendition path per asset id.
        guard let previewsDB = openReadOnlyDatabase(previewsURL) else {
            continue
        }
        var bestLongSide: [Int64: Double] = [:]
        var bestPath: [Int64: String] = [:]
        var pathStmt: OpaquePointer?
        if sqlite3_prepare_v2(previewsDB, "SELECT localAssetId, longSide, path FROM RenditionPath", -1, &pathStmt, nil) == SQLITE_OK {
            while sqlite3_step(pathStmt) == SQLITE_ROW {
                let longSide = sqlite3_column_double(pathStmt, 1)
                guard longSide >= minLongSide else {
                    continue
                }
                let assetId = Int64(sqlite3_column_double(pathStmt, 0))
                if let existing = bestLongSide[assetId], existing >= longSide {
                    continue
                }
                guard let cString = sqlite3_column_text(pathStmt, 2) else {
                    continue
                }
                bestLongSide[assetId] = longSide
                bestPath[assetId] = String(cString: cString)
            }
        }
        sqlite3_finalize(pathStmt)
        sqlite3_close(previewsDB)

        guard !bestPath.isEmpty else {
            continue
        }

        // 2. Capture month per asset, joined to the rendition paths above.
        guard let catalogDB = openReadOnlyDatabase(catalogURL) else {
            continue
        }
        let query = """
        SELECT d.localDocId, r.content FROM docs d \
        JOIN revs r ON r.sequence = d.winningRevSequence \
        WHERE d.type = 'asset'
        """
        var assetStmt: OpaquePointer?
        if sqlite3_prepare_v2(catalogDB, query, -1, &assetStmt, nil) == SQLITE_OK {
            while sqlite3_step(assetStmt) == SQLITE_ROW {
                let assetId = sqlite3_column_int64(assetStmt, 0)
                guard let path = bestPath[assetId],
                      let blob = sqlite3_column_blob(assetStmt, 1) else {
                    continue
                }
                let length = Int(sqlite3_column_bytes(assetStmt, 1))
                guard length > 0 else {
                    continue
                }
                let month = captureMonth(in: UnsafeRawBufferPointer(start: blob, count: length))
                guard let month, !month.hasPrefix("0000") else {
                    continue
                }
                pathsByMonth[month, default: []].append(URL(fileURLWithPath: path))
            }
        }
        sqlite3_finalize(assetStmt)
        sqlite3_close(catalogDB)
    }

    let months = pathsByMonth.keys.sorted()
    guard !months.isEmpty else {
        return nil
    }
    return MonthCatalog(months: months, pathsByMonth: pathsByMonth)
}

private func defaultLibraryCandidates() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
    var candidates = [
        pictures.appendingPathComponent("Lightroom Library.lrlibrary", isDirectory: true)
    ]

    if let contents = try? FileManager.default.contentsOfDirectory(
        at: pictures,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) {
        for url in contents where url.pathExtension == "lrlibrary" && !candidates.contains(url) {
            candidates.append(url)
        }
    }

    return candidates
}

private func collectSourceDirectories() -> [SourceDirectory] {
    guard let libraryURL = defaultLibraryCandidates().first(where: { url in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }) else {
        return []
    }

    guard let children = try? FileManager.default.contentsOfDirectory(
        at: libraryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var sourceDirectories: [SourceDirectory] = []
    for child in children {
        let managedCatalog = child.appendingPathComponent("Managed Catalog.mcat")
        let previews = child.appendingPathComponent("previews", isDirectory: true)
        let originals = child.appendingPathComponent("originals", isDirectory: true)

        guard FileManager.default.fileExists(atPath: managedCatalog.path)
                || FileManager.default.fileExists(atPath: previews.path)
                || FileManager.default.fileExists(atPath: originals.path) else {
            continue
        }
        if FileManager.default.fileExists(atPath: previews.path) {
            sourceDirectories.append(SourceDirectory(source: .preview, directory: previews))
        }
    }

    return sourceDirectories
}

private func collectCandidateURLs(from sourceDirectories: [SourceDirectory], limit: Int, excluding excludedURLs: Set<URL>) -> [URL] {
    var urls: [URL] = []
    var seenURLs = excludedURLs
    let leafDirectories = sourceDirectories
        .flatMap { candidateDirectories(for: $0.source, under: $0.directory) }
        .shuffled()

    for directory in leafDirectories {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            continue
        }

        for url in contents.shuffled() {
            guard urls.count < limit else {
                return urls
            }
            guard !seenURLs.contains(url) else {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  isLikelyImageURL(url) else {
                continue
            }
            seenURLs.insert(url)
            urls.append(url)
        }
    }

    return urls
}

private func candidateDirectories(for source: SourceKind, under root: URL) -> [URL] {
    switch source {
    case .preview:
        return [root] + childDirectories(under: root)
    case .original:
        let years = childDirectories(under: root)
        let dates = years.flatMap(childDirectories)
        return [root] + years + dates
    }
}

private func childDirectories(under root: URL) -> [URL] {
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    return contents.filter { url in
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
            return false
        }
        return values.isDirectory == true
    }
}

private func isLikelyImageURL(_ url: URL) -> Bool {
    let extensionName = url.pathExtension.lowercased()
    guard !extensionName.isEmpty else {
        return true
    }
    return ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"].contains(extensionName)
}

private func loadTileItem(url: URL) -> TileItem? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
        return nil
    }

    let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
    let swapsAxes = [5, 6, 7, 8].contains(orientation)
    let displayWidth = swapsAxes ? height : width
    let displayHeight = swapsAxes ? width : height
    guard max(displayWidth, displayHeight) >= minimumTileLongEdge else {
        return nil
    }
    return TileItem(
        url: url,
        pixelWidth: displayWidth,
        pixelHeight: displayHeight,
        hash: perceptualHash(for: source)
    )
}

/// Computes a 64-bit difference hash (dHash): a 9×8 grayscale rendition where
/// each bit records whether a pixel is brighter than its right-hand neighbour.
/// Robust to scaling, light compression, and small exposure shifts, so frames
/// from the same burst land within a few bits of each other.
private func perceptualHash(for source: CGImageSource) -> UInt64? {
    let width = 9
    let height = 8
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 32,
        kCGImageSourceShouldCache: false
    ] as CFDictionary) else {
        return nil
    }

    var pixels = [UInt8](repeating: 0, count: width * height)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else {
        return nil
    }
    context.interpolationQuality = .low
    context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))

    var hash: UInt64 = 0
    var bit: UInt64 = 0
    for row in 0..<height {
        for col in 0..<(width - 1) {
            if pixels[row * width + col] > pixels[row * width + col + 1] {
                hash |= (1 << bit)
            }
            bit += 1
        }
    }
    return hash
}

/// Drops tiles that look near-identical to one already kept, preserving order so
/// the (already shuffled) sample stays varied. Items without a hash are always
/// kept rather than risk discarding something we couldn't compare.
private func deduplicateByLook(_ items: [TileItem]) -> [TileItem] {
    var kept: [TileItem] = []
    var keptHashes: [UInt64] = []

    for item in items {
        guard let hash = item.hash else {
            kept.append(item)
            continue
        }
        let isNearDuplicate = keptHashes.contains { existing in
            (existing ^ hash).nonzeroBitCount <= nearDuplicateHammingThreshold
        }
        if !isNearDuplicate {
            kept.append(item)
            keptHashes.append(hash)
        }
    }

    return kept
}
