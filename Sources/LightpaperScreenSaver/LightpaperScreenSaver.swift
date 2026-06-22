import AppKit
import ImageIO
import ScreenSaver
import SQLite3
import Vision

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

// Two tiles whose Vision feature prints are within this distance are treated as
// the same shot (a burst frame or near-identical look-alike of the same
// scene/subject) and are not placed on one screen together. Feature prints are a
// 768-dim on-device semantic embedding, so unlike a difference hash they group
// "same shoot, different pose" portraits — exactly the look-alikes that made
// dense months look repetitive. Measured on real months: genuine look-alikes sit
// below ~0.5; genuinely distinct scenes sit well above. Tuned on real months:
// 0.7 cuts a one-shoot month (61 near-identical portraits) down to ~16 varied
// frames while a varied travel month still keeps ~26 distinct scenes, because a
// semantic threshold naturally prunes monotony harder than variety. Lower = more
// aggressive removal.
private let nearDuplicateFeaturePrintDistance: Float = 0.7

// Privacy mode: a photo counts as "about a person" when a detected face or body
// box is at least this tall relative to the frame, so headshots and posed shots
// are dropped while scenery with a small, distant bystander is kept. Faces are
// smaller than bodies, so the face threshold is lower. Both are normalized
// (0..1) against image height. These start conservative ("prominent only") and
// are meant to be tuned on real months via LIGHTPAPER_HIDE_PEOPLE +
// LIGHTPAPER_FORCE_MONTH.
private let minimumProminentFaceHeightFraction: CGFloat = 0.14
private let minimumProminentBodyHeightFraction: CGFloat = 0.45

// How far a row may be enlarged past the native size of its smallest rendition.
// Lightroom's standard previews are modest-resolution, so without some headroom
// the justified rows always collapse to many tiny tiles (the row can never be
// taller than its smallest native image). Allowing a bounded upscale trades a
// little softness for far fewer, much larger tiles — the "show the photos big"
// goal. 1.0 = the old never-upscale behaviour.
private let maxRowUpscale: CGFloat = 2.4

private final class LightpaperTiledView: NSView {
    private var items: [TileItem]
    private var tileFrames: [NSRect] = []
    private var laidOutWidth: CGFloat = 0
    private var laidOutViewportHeight: CGFloat = 0
    private var laidOutScale: CGFloat = 0
    private let imageCache = NSCache<NSURL, CachedCGImage>()
    // One clipping container layer per tile (holding the drifting image layer),
    // rebuilt whenever the layout changes. Tracked so the previous set can be
    // torn down before a rebuild.
    private var tileLayers: [CALayer] = []
    private var layoutGeneration = 0

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

    /// Rebuilds the per-tile layer tree to match `tileFrames`: a clipping
    /// container per tile holding an aspect-fill image layer. Images decode
    /// off-main and their `contents` are assigned when ready. Called only when
    /// the layout actually changes.
    private func rebuildTileLayers() {
        guard let hostLayer = layer else {
            return
        }
        layoutGeneration += 1
        let generation = layoutGeneration
        let backing = max(window?.backingScaleFactor ?? laidOutScale, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        tileLayers.forEach { $0.removeFromSuperlayer() }
        tileLayers.removeAll(keepingCapacity: true)

        for (index, frame) in tileFrames.enumerated() {
            let container = CALayer()
            container.frame = frame
            container.masksToBounds = true
            container.backgroundColor = NSColor.black.cgColor

            let imageLayer = CALayer()
            imageLayer.frame = container.bounds
            imageLayer.contentsGravity = .resizeAspectFill
            imageLayer.contentsScale = backing
            imageLayer.masksToBounds = true
            container.addSublayer(imageLayer)

            hostLayer.addSublayer(container)
            tileLayers.append(container)

            let item = items[index]
            let maxPixelSize = Int(ceil(max(frame.width, frame.height) * backing))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let cached = self?.cachedImage(for: item, maxPixelSize: maxPixelSize) else {
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    // Skip if the layout was rebuilt while this decode was in flight.
                    guard let self, self.layoutGeneration == generation else {
                        return
                    }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    imageLayer.contents = cached.image
                    CATransaction.commit()
                }
            }
        }

        CATransaction.commit()
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
        // Tuned for a "looser" mosaic: ~2-3 rows of 3-4 images = ~6-12 large
        // tiles per screen, so each rendition gets real estate. The high max
        // clamps matter most — without them no row ever exceeded ~760px tall on a
        // 4K/5K display, which was the real cap on tile size. Rows still never
        // exceed the smallest native size in the row, so low-res months simply
        // pack denser (more, smaller rows) rather than upscaling.
        let targetHeights = [
            min(max(viewportHeight * 0.66, 460), 1300),
            min(max(viewportHeight * 0.50, 360), 1040),
            min(max(viewportHeight * 0.60, 420), 1180),
            min(max(viewportHeight * 0.46, 320), 940)
        ]
        // 1. Compose justified rows, packing enough images into each row that its
        //    height never exceeds `maxRowUpscale`× the smallest native size in the
        //    row — so the lowest-res image is enlarged by at most that factor.
        //    Low-res photos still end up in denser rows; the headroom is what lets
        //    a row of modest Lightroom previews stand tall instead of collapsing
        //    to tiny tiles. Stop once we have enough rows to overshoot one screen.
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
                // target and to keep the lowest-res image within the upscale bound.
                if availableWidth / rowAspect <= min(target, minNativeHeight * maxRowUpscale) {
                    settled = true
                    break
                }
            }

            if !settled {
                // Ran out of images mid-row; drop this partial row unless it is
                // all we have, so the bottom never shows a stretched fragment.
                if rows.isEmpty, !entries.isEmpty {
                    let height = min(availableWidth / rowAspect, minNativeHeight * maxRowUpscale)
                    rows.append((entries, height))
                    totalHeight += height
                }
                break
            }

            // Natural justified height, capped so the lowest-res image in the row
            // is enlarged by at most `maxRowUpscale`× its native size.
            let height = min(availableWidth / rowAspect, minNativeHeight * maxRowUpscale)
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
        rebuildTileLayers()
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
    private let versionLayer = CATextLayer()
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

        // Version line, so a running saver can be told apart from a stale cached
        // install. Reads from this bundle's Info.plist (short version + build).
        let info = Bundle(for: IndexingAnimationView.self).infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        versionLayer.string = "Lightpaper \(short) (\(build))"
        versionLayer.alignmentMode = .center
        versionLayer.foregroundColor = NSColor(white: 0.5, alpha: 1).cgColor
        versionLayer.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        versionLayer.fontSize = 12
        versionLayer.contentsScale = scale
        layer?.addSublayer(versionLayer)
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
        let captionY = originY - block * 0.18 - captionHeight
        captionLayer.frame = CGRect(
            x: 0,
            y: captionY,
            width: bounds.width,
            height: captionHeight
        )

        let versionHeight: CGFloat = 18
        versionLayer.frame = CGRect(
            x: 0,
            y: captionY - versionHeight - 6,
            width: bounds.width,
            height: versionHeight
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
    private var indexingShownAt: Date?
    // Keep the indexing screen (which shows the version) up long enough to read,
    // even when the cached index loads almost instantly.
    private let minimumIndexingDuration: TimeInterval = 2.5

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

                // Hold the indexing/version screen for a readable minimum even
                // when the index was ready immediately.
                let elapsed = self.indexingShownAt.map { Date().timeIntervalSince($0) } ?? 0
                let remaining = max(0, self.minimumIndexingDuration - elapsed)
                if remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                        self?.showNextMonth(animated: false)
                    }
                } else {
                    self.showNextMonth(animated: false)
                }
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
            let hidePeople = hidePeopleEnabled()
            let items = deduplicateByLook(sample.compactMap(loadTileItem), hidePeople: hidePeople)
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
        // Debug aid: `LIGHTPAPER_FORCE_MONTH=2016-03` pins every screen to one
        // month so a specific month can be inspected (e.g. de-dup tuning). Falls
        // back to the normal random pick when unset or the month isn't present.
        let forcedMonth = ProcessInfo.processInfo.environment["LIGHTPAPER_FORCE_MONTH"]
            .flatMap { months.contains($0) ? $0 : nil }
        let month = forcedMonth ?? randomMonth(excluding: lastMonth, from: months)
        lastMonth = month

        var result = (catalog.pathsByMonth[month] ?? []).shuffled()
        // Top the candidate pool up to the full dedup buffer (sampleCandidateLimit),
        // overrunning into the nearest neighbouring months (closest first). A month
        // can have enough raw previews yet still dedup down below a screenful when
        // it is full of look-alikes (e.g. a month of similar landscapes), so we
        // always pull neighbouring-month variety up to the buffer rather than
        // stopping at photosPerScreen — otherwise the layout, which only ever
        // downscales, leaves the bottom of the screen black.
        if let center = months.firstIndex(of: month) {
            var step = 1
            while result.count < sampleCandidateLimit, step < months.count {
                for neighbor in [center - step, center + step] where neighbor >= 0 && neighbor < months.count {
                    result.append(contentsOf: (catalog.pathsByMonth[months[neighbor]] ?? []).shuffled())
                    if result.count >= sampleCandidateLimit {
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
                context.duration = 1.6
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
        indexingShownAt = Date()
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
        pixelHeight: displayHeight
    )
}

private struct PhotoAnalysis {
    /// A 768-dim on-device semantic embedding; `nil` when the image couldn't be
    /// decoded or the request failed.
    let featurePrint: VNFeaturePrintObservation?
    /// True when privacy detection ran and found a face or body large enough to
    /// make the photo "about a person".
    let hasProminentPerson: Bool
}

/// Decodes the image once (a small thumbnail) and runs the Vision requests it
/// needs in a single pass. The feature print is always computed; face and body
/// detection only run when `detectPeople` is set, so default behaviour keeps the
/// exact same cost. Distances between feature prints reflect how alike the
/// scenes/subjects look (not just composition), so frames from the same shoot
/// land close together.
private func analyzePhoto(at url: URL, detectPeople: Bool) -> PhotoAnalysis {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 360,
              kCGImageSourceShouldCache: false
          ] as CFDictionary) else {
        return PhotoAnalysis(featurePrint: nil, hasProminentPerson: false)
    }

    let printRequest = VNGenerateImageFeaturePrintRequest()
    var requests: [VNRequest] = [printRequest]
    let faceRequest = detectPeople ? VNDetectFaceRectanglesRequest() : nil
    let bodyRequest = detectPeople ? VNDetectHumanRectanglesRequest() : nil
    if let faceRequest {
        requests.append(faceRequest)
    }
    if let bodyRequest {
        requests.append(bodyRequest)
    }

    let handler = VNImageRequestHandler(cgImage: thumbnail, options: [:])
    try? handler.perform(requests)

    // VN*Observation boundingBox is normalized to the image, so .height is the
    // fraction of frame height the subject occupies.
    let prominent =
        (faceRequest?.results ?? []).contains { $0.boundingBox.height >= minimumProminentFaceHeightFraction }
        || (bodyRequest?.results ?? []).contains { $0.boundingBox.height >= minimumProminentBodyHeightFraction }

    return PhotoAnalysis(
        featurePrint: printRequest.results?.first as? VNFeaturePrintObservation,
        hasProminentPerson: prominent
    )
}

/// Drops tiles that look near-identical to one already kept, preserving order so
/// the (already shuffled) sample stays varied. With `hidePeople`, also drops any
/// photo that prominently features a person (privacy mode). Items whose feature
/// print can't be computed are always kept rather than risk discarding something
/// we couldn't compare — but a confirmed prominent person is always dropped.
/// Vision requests run here, on the background queue that calls this, and never
/// escape — so `TileItem` stays cheap and `Sendable`.
private func deduplicateByLook(_ items: [TileItem], hidePeople: Bool) -> [TileItem] {
    var kept: [TileItem] = []
    var keptPrints: [VNFeaturePrintObservation] = []

    for item in items {
        let analysis = analyzePhoto(at: item.url, detectPeople: hidePeople)
        if hidePeople && analysis.hasProminentPerson {
            continue
        }
        guard let print = analysis.featurePrint else {
            kept.append(item)
            continue
        }
        let isNearDuplicate = keptPrints.contains { existing in
            var distance: Float = 0
            guard (try? existing.computeDistance(&distance, to: print)) != nil else {
                return false
            }
            return distance <= nearDuplicateFeaturePrintDistance
        }
        if !isNearDuplicate {
            kept.append(item)
            keptPrints.append(print)
        }
    }

    return kept
}

/// Privacy mode: when on, photos that prominently feature a person are skipped.
/// `LIGHTPAPER_HIDE_PEOPLE=1` overrides for testing (mirrors LIGHTPAPER_FORCE_MONTH);
/// otherwise the persisted screen-saver default is read.
private func hidePeopleEnabled() -> Bool {
    if let raw = ProcessInfo.processInfo.environment["LIGHTPAPER_HIDE_PEOPLE"] {
        return (raw as NSString).boolValue
    }
    let defaults = ScreenSaverDefaults(forModuleWithName: "dev.lightpaper.Lightpaper.ScreenSaver")
    return defaults?.bool(forKey: "hidePeople") ?? false
}
