import AppKit
import ImageIO
import ScreenSaver

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
private let minimumTileLongEdge = 900

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

        for (index, frame) in tileFrames.enumerated() where frame.intersects(dirtyRect) {
            guard let image = cachedImage(for: items[index])?.image,
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
        var y: CGFloat = 0
        var cursor = 0
        var rowIndex = 0

        while cursor < items.count {
            var row: [(item: TileItem, nativeWidth: CGFloat, nativeHeight: CGFloat)] = []
            var rowAspect: CGFloat = 0
            let target = targetHeights[rowIndex % targetHeights.count]
            var settled = false

            while cursor < items.count {
                let item = items[cursor]
                let size = nativeSize(for: item, scale: scale)
                row.append((item, size.width, size.height))
                rowAspect += size.width / size.height
                cursor += 1

                let projectedHeight = availableWidth / rowAspect
                if projectedHeight <= target {
                    settled = true
                    break
                }
            }

            guard settled else {
                break
            }

            let rowHeight = availableWidth / rowAspect
            appendRow(row, y: y, height: rowHeight, availableWidth: availableWidth)
            y += rowHeight
            rowIndex += 1
        }

        frame = NSRect(x: 0, y: 0, width: availableWidth, height: max(y, viewportHeight))
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

    private func cachedImage(for item: TileItem) -> CachedCGImage? {
        let key = item.url as NSURL
        if let image = imageCache.object(forKey: key) {
            return image
        }

        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(item.pixelWidth, item.pixelHeight),
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else {
            return nil
        }

        let image = CachedCGImage(cgImage)
        imageCache.setObject(image, forKey: key)
        return image
    }
}

@objc(LightpaperScreenSaverView)
public final class LightpaperScreenSaverView: ScreenSaverView {
    private var scrollView: NSScrollView?
    private var tiledView: LightpaperTiledView?
    private var loadedURLs = Set<URL>()
    private var currentPage = 0

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
        if tiledView == nil {
            installImages()
        }
    }

    public override func animateOneFrame() {
        advancePage()
    }

    public override func layout() {
        super.layout()
        scrollView?.frame = bounds
        tiledView?.layoutSubtreeIfNeeded()
        scrollToCurrentPage(animated: false)
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = isPreview ? 5 : 8
    }

    private func installImages() {
        let sourceDirectories = collectSourceDirectories()
        guard !sourceDirectories.isEmpty else {
            return
        }

        let targetLimit = isPreview ? previewImageLimit : defaultImageLimit
        let initialLimit = isPreview ? previewImageLimit : min(defaultImageLimit, 700)
        let items = collectTileItems(from: sourceDirectories, limit: initialLimit, excluding: [])
        guard !items.isEmpty else {
            return
        }
        loadedURLs = Set(items.map(\.url))

        let tiledView = LightpaperTiledView(items: items)
        let scrollView = NSScrollView(frame: bounds)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = tiledView

        addSubview(scrollView)
        self.scrollView = scrollView
        self.tiledView = tiledView
        scrollToCurrentPage(animated: false)
        loadAdditionalItems(from: sourceDirectories, targetLimit: targetLimit)
    }

    private func loadAdditionalItems(from sourceDirectories: [SourceDirectory], targetLimit: Int) {
        let loadedURLs = loadedURLs
        let needed = targetLimit - loadedURLs.count
        guard needed > 0 else {
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self, sourceDirectories, loadedURLs, needed] in
            let candidateLimit = max(needed * 4, needed + 1000)
            let candidates = collectCandidateURLs(
                from: sourceDirectories,
                limit: candidateLimit,
                excluding: loadedURLs
            )

            var seenURLs = loadedURLs
            var batch: [TileItem] = []
            var usable = 0
            let batchSize = 60

            func dispatchBatch() {
                guard !batch.isEmpty else {
                    return
                }
                let toAppend = batch
                batch.removeAll(keepingCapacity: true)
                DispatchQueue.main.async { [weak self] in
                    self?.appendAdditionalItems(toAppend)
                }
            }

            for url in candidates {
                guard usable < needed else {
                    break
                }
                guard !seenURLs.contains(url) else {
                    continue
                }
                seenURLs.insert(url)
                guard let item = loadTileItem(url: url) else {
                    continue
                }
                batch.append(item)
                usable += 1

                if batch.count >= batchSize {
                    dispatchBatch()
                }
            }

            dispatchBatch()
        }
    }

    private func appendAdditionalItems(_ items: [TileItem]) {
        loadedURLs.formUnion(items.map(\.url))
        tiledView?.appendItems(items)
    }

    private func advancePage() {
        guard let tiledView else {
            return
        }

        let pageCount = tiledView.pageCount
        guard pageCount > 1 else {
            currentPage = 0
            scrollToCurrentPage(animated: false)
            return
        }

        currentPage = (currentPage + 1) % pageCount
        scrollToCurrentPage(animated: true)
    }

    private func scrollToCurrentPage(animated: Bool) {
        guard let scrollView else {
            return
        }

        tiledView?.layoutSubtreeIfNeeded()
        let pageHeight = max(scrollView.contentView.bounds.height, 1)
        let target = NSPoint(x: 0, y: CGFloat(currentPage) * pageHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.contentView.animator().setBoundsOrigin(target)
            } completionHandler: {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
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

private func collectTileItems(from sourceDirectories: [SourceDirectory], limit: Int, excluding excludedURLs: Set<URL>) -> [TileItem] {
    var items: [TileItem] = []
    var seenURLs = Set<URL>()
    seenURLs.formUnion(excludedURLs)
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
            guard items.count < limit else {
                return items
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
            guard let item = loadTileItem(url: url) else {
                continue
            }
            items.append(item)
        }
    }

    return items
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
