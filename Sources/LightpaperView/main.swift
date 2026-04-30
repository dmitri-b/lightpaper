import AppKit
import Foundation
import ImageIO

enum SourceKind: String, CaseIterable, Sendable {
    case original
    case preview
}

enum MediaFormat: Sendable {
    case jpeg
    case png
    case heif
    case tiff
    case unknown
}

enum ViewMode: String, Sendable {
    case collage
    case mosaic
    case tile
    case slideshow
}

let defaultImageLimit = 6000
let initialImageURLLimit = 500
let backgroundAppendBatchSize = 100
let minimumTileLongEdge = 900

struct ViewOptions: Sendable {
    var libraryPath: String?
    var sourceFilter: Set<SourceKind> = [.preview]
    var mode: ViewMode = .mosaic
    var interval: TimeInterval = 8
    var windowed = false
    var limit: Int? = defaultImageLimit
    var quitAfter: TimeInterval?
}

struct ScanRoot: Sendable {
    let accountURL: URL
}

struct MediaCandidate: Sendable {
    let url: URL
}

struct SourceDirectory: Sendable {
    let source: SourceKind
    let directory: URL
}

enum ViewError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case noLibraryFound
    case unreadableLibrary(String)
    case noImagesFound

    var description: String {
        switch self {
        case .invalidArgument(let message):
            return message
        case .noLibraryFound:
            return "No Lightroom .lrlibrary package found. Pass --library /path/to/Lightroom\\ Library.lrlibrary."
        case .unreadableLibrary(let path):
            return "Cannot read Lightroom library at \(path)."
        case .noImagesFound:
            return "No readable Lightroom local cache images were found."
        }
    }
}

final class SlideshowWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

enum NavigationAction {
    case quit
    case next
    case previous
}

func navigationAction(for event: NSEvent) -> NavigationAction? {
    switch event.keyCode {
    case 53:
        return .quit
    case 49, 124, 125:
        return .next
    case 123, 126:
        return .previous
    default:
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "q":
            return .quit
        case "l":
            return .next
        case "j":
            return .previous
        default:
            return nil
        }
    }
}

final class SlideshowView: NSView {
    var onAdvance: (() -> Void)?
    var onBack: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch navigationAction(for: event) {
        case .quit:
            NSApp.terminate(nil)
        case .next:
            onAdvance?()
        case .previous:
            onBack?()
        case nil:
            super.keyDown(with: event)
        }
    }
}

func windowedFrame(on screen: NSScreen?, width: CGFloat, height: CGFloat) -> NSRect {
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    return NSRect(
        x: visible.midX - width / 2,
        y: visible.midY - height / 2,
        width: width,
        height: height
    )
}

func fullscreenFrame(on screen: NSScreen?) -> NSRect {
    screen?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
}

@MainActor
func configureFullscreenAppWindow(_ window: NSWindow) {
    NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
    window.level = .screenSaver
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.hidesOnDeactivate = false
    NSCursor.hide()
}

@MainActor
func restoreAppPresentation() {
    NSApp.presentationOptions = []
    NSCursor.unhide()
}

struct TileItem: Sendable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
}

final class CachedCGImage {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

struct SkylineSegment {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat

    var maxX: CGFloat {
        x + width
    }
}

final class TiledImageView: NSView {
    var onAdvance: (() -> Void)?
    var onBack: (() -> Void)?

    private var items: [TileItem]
    private let overlapFraction: CGFloat
    private let justifiesRows: Bool
    private let editorialLayout: Bool
    private var tileFrames: [NSRect] = []
    private var laidOutWidth: CGFloat = 0
    private var laidOutViewportHeight: CGFloat = 0
    private var laidOutScale: CGFloat = 0
    private let imageCache = NSCache<NSURL, CachedCGImage>()

    init(
        items: [TileItem],
        overlapFraction: CGFloat = 0,
        justifiesRows: Bool = false,
        editorialLayout: Bool = false
    ) {
        self.items = items
        self.overlapFraction = overlapFraction
        self.justifiesRows = justifiesRows
        self.editorialLayout = editorialLayout
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageCache.countLimit = 300
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch navigationAction(for: event) {
        case .quit:
            NSApp.terminate(nil)
        case .next:
            onAdvance?()
        case .previous:
            onBack?()
        case nil:
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else {
            super.scrollWheel(with: event)
            return
        }

        if event.scrollingDeltaY < 0 {
            onAdvance?()
        } else if event.scrollingDeltaY > 0 {
            onBack?()
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
        return max(Int(ceil(frame.height / height)), 1)
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

        if editorialLayout {
            updateEditorialLayout(availableWidth: availableWidth, scale: scale)
            return
        } else if justifiesRows {
            updateJustifiedLayout(availableWidth: availableWidth, scale: scale)
            return
        }

        var skyline = [SkylineSegment(x: 0, y: 0, width: availableWidth)]
        var contentHeight: CGFloat = 0

        for item in items {
            let width = max(CGFloat(item.pixelWidth) / scale, 1)
            let height = max(CGFloat(item.pixelHeight) / scale, 1)
            let packingWidth = max(width * (1 - overlapFraction), 1)
            let packingHeight = max(height * (1 - overlapFraction), 1)
            let packed = packedFrame(width: packingWidth, height: packingHeight, availableWidth: availableWidth, skyline: &skyline)
            let frame = NSRect(x: packed.minX, y: packed.minY, width: width, height: height)
            tileFrames.append(frame)
            contentHeight = max(contentHeight, frame.maxY)
        }

        frame = NSRect(x: 0, y: 0, width: availableWidth, height: pagedContentHeight(for: contentHeight))
    }

    private func invalidateTileLayout() {
        tileFrames.removeAll(keepingCapacity: true)
        laidOutWidth = 0
        laidOutViewportHeight = 0
        laidOutScale = 0
    }

    private func updateJustifiedLayout(availableWidth: CGFloat, scale: CGFloat) {
        let viewportHeight = viewportHeight()
        let targetRowHeight = max(min(viewportHeight * 0.28, 360), 180)
        var y: CGFloat = 0
        var pageBottom = viewportHeight
        var row: [(item: TileItem, nativeWidth: CGFloat, nativeHeight: CGFloat)] = []
        var rowAspect: CGFloat = 0

        func flushRow(fillRemaining: Bool) {
            guard !row.isEmpty else {
                return
            }

            let remaining = max(pageBottom - y, 1)
            let exactHeight = min(availableWidth / rowAspect, remaining)
            let rowHeight = fillRemaining ? remaining : min(exactHeight, targetRowHeight, remaining)
            appendRow(row, y: y, height: rowHeight, availableWidth: availableWidth)

            y += rowHeight
            if pageBottom - y < 1 {
                y = pageBottom
                pageBottom += viewportHeight
            }

            row.removeAll(keepingCapacity: true)
            rowAspect = 0
        }

        for item in items {
            if pageBottom - y < targetRowHeight * 0.7 {
                flushRow(fillRemaining: true)
            }

            let nativeWidth = max(CGFloat(item.pixelWidth) / scale, 1)
            let nativeHeight = max(CGFloat(item.pixelHeight) / scale, 1)
            row.append((item, nativeWidth, nativeHeight))
            rowAspect += nativeWidth / nativeHeight

            let projectedHeight = availableWidth / rowAspect
            if projectedHeight <= targetRowHeight {
                flushRow(fillRemaining: false)
            }
        }

        if !row.isEmpty {
            flushRow(fillRemaining: true)
        }
        frame = NSRect(x: 0, y: 0, width: availableWidth, height: pagedContentHeight(for: y))
    }

    private func updateEditorialLayout(availableWidth: CGFloat, scale: CGFloat) {
        let viewportHeight = viewportHeight()
        let targetHeights = [
            min(max(viewportHeight * 0.62, 380), 720),
            min(max(viewportHeight * 0.38, 260), 460),
            min(max(viewportHeight * 0.52, 330), 620),
            min(max(viewportHeight * 0.28, 190), 340),
            min(max(viewportHeight * 0.46, 300), 540)
        ]
        var y: CGFloat = 0
        var pageBottom = viewportHeight
        var cursor = 0
        var rowIndex = 0

        while cursor < items.count {
            let remaining = max(pageBottom - y, 1)
            var row: [(item: TileItem, nativeWidth: CGFloat, nativeHeight: CGFloat)] = []
            var rowAspect: CGFloat = 0
            let targetHeight = min(targetHeights[rowIndex % targetHeights.count], remaining)

            while cursor < items.count {
                let item = items[cursor]
                let size = nativeSize(for: item, scale: scale)
                row.append((item, size.width, size.height))
                rowAspect += size.width / size.height
                cursor += 1

                let projectedHeight = availableWidth / rowAspect
                if projectedHeight <= targetHeight {
                    break
                }
            }

            let exactHeight = availableWidth / rowAspect
            let shouldFillPage = pageBottom - y - exactHeight < targetHeights.last ?? 240
            let rowHeight = shouldFillPage ? remaining : min(exactHeight, remaining)
            appendRow(row, y: y, height: rowHeight, availableWidth: availableWidth)

            y += rowHeight
            if pageBottom - y < 1 {
                y = pageBottom
                pageBottom += viewportHeight
            }

            rowIndex += 1
        }

        frame = NSRect(x: 0, y: 0, width: availableWidth, height: pagedContentHeight(for: y))
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

    private func pagedContentHeight(for contentHeight: CGFloat) -> CGFloat {
        let pageHeight = viewportHeight()
        return max(ceil(max(contentHeight, 1) / pageHeight) * pageHeight, pageHeight)
    }

    private func nativeSize(for item: TileItem, scale: CGFloat) -> NSSize {
        NSSize(
            width: max(CGFloat(item.pixelWidth) / scale, 1),
            height: max(CGFloat(item.pixelHeight) / scale, 1)
        )
    }

    private func packedFrame(
        width requestedWidth: CGFloat,
        height: CGFloat,
        availableWidth: CGFloat,
        skyline: inout [SkylineSegment]
    ) -> NSRect {
        let width = min(requestedWidth, availableWidth)
        var bestIndex = 0
        var bestX: CGFloat = 0
        var bestY = CGFloat.greatestFiniteMagnitude
        var bestBottom = CGFloat.greatestFiniteMagnitude

        for index in skyline.indices {
            let x = skyline[index].x
            guard x + width <= availableWidth + 0.5 else {
                continue
            }

            var remainingWidth = width
            var y: CGFloat = 0
            var scanIndex = index

            while remainingWidth > 0, scanIndex < skyline.count {
                y = max(y, skyline[scanIndex].y)
                remainingWidth -= skyline[scanIndex].width
                scanIndex += 1
            }

            guard remainingWidth <= 0 else {
                continue
            }

            let bottom = y + height
            if bottom < bestBottom || (bottom == bestBottom && (y < bestY || (y == bestY && x < bestX))) {
                bestIndex = index
                bestX = x
                bestY = y
                bestBottom = bottom
            }
        }

        let placed = NSRect(x: bestX, y: bestY, width: width, height: height)
        insertSkylineNode(at: bestIndex, frame: placed, skyline: &skyline)
        return placed
    }

    private func insertSkylineNode(at index: Int, frame: NSRect, skyline: inout [SkylineSegment]) {
        let node = SkylineSegment(x: frame.minX, y: frame.maxY, width: frame.width)
        skyline.insert(node, at: index)

        let nextIndex = index + 1
        while nextIndex < skyline.count {
            let previous = skyline[nextIndex - 1]
            let current = skyline[nextIndex]
            guard current.x < previous.maxX else {
                break
            }

            let overlap = previous.maxX - current.x
            skyline[nextIndex].x += overlap
            skyline[nextIndex].width -= overlap

            if skyline[nextIndex].width <= 0.5 {
                skyline.remove(at: nextIndex)
            } else {
                break
            }
        }

        var mergeIndex = 0
        while mergeIndex + 1 < skyline.count {
            if abs(skyline[mergeIndex].y - skyline[mergeIndex + 1].y) < 0.5 {
                skyline[mergeIndex].width += skyline[mergeIndex + 1].width
                skyline.remove(at: mergeIndex + 1)
            } else {
                mergeIndex += 1
            }
        }
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

@MainActor
final class TileController: NSObject, NSApplicationDelegate {
    private let imageURLs: [URL]
    private let sourceDirectories: [SourceDirectory]
    private let options: ViewOptions
    private let overlapFraction: CGFloat
    private let justifiesRows: Bool
    private let editorialLayout: Bool
    private var window: SlideshowWindow?
    private var tiledView: TiledImageView?
    private var scrollView: NSScrollView?
    private var currentPage = 0
    private var lastScrollWheelPageAt = Date.distantPast
    private var loadedURLs: Set<URL> = []

    init(
        imageURLs: [URL],
        sourceDirectories: [SourceDirectory],
        options: ViewOptions,
        overlapFraction: CGFloat,
        justifiesRows: Bool = false,
        editorialLayout: Bool = false
    ) {
        self.imageURLs = imageURLs
        self.sourceDirectories = sourceDirectories
        self.options = options
        self.overlapFraction = overlapFraction
        self.justifiesRows = justifiesRows
        self.editorialLayout = editorialLayout
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let screen = NSScreen.main
        let frame: NSRect
        let style: NSWindow.StyleMask

        if options.windowed {
            frame = windowedFrame(on: screen, width: 1120, height: 760)
            style = [.titled, .closable, .miniaturizable, .resizable]
        } else {
            frame = fullscreenFrame(on: screen)
            style = [.borderless]
        }

        let tileItems = imageURLs.compactMap(loadTileItem)
        loadedURLs = Set(tileItems.map(\.url))
        let tiledView = TiledImageView(
            items: tileItems,
            overlapFraction: overlapFraction,
            justifiesRows: justifiesRows,
            editorialLayout: editorialLayout
        )
        tiledView.onAdvance = { [weak self] in self?.advancePage(step: 1) }
        tiledView.onBack = { [weak self] in self?.advancePage(step: -1) }

        let scrollView = NSScrollView(frame: frame)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = tiledView

        let window = SlideshowWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.title = "Lightpaper"
        window.backgroundColor = .black
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tiledView)

        if !options.windowed {
            configureFullscreenAppWindow(window)
        }

        self.window = window
        self.tiledView = tiledView
        self.scrollView = scrollView
        scrollToCurrentPage(animated: false)
        startBackgroundLoading(excluding: Set(imageURLs), usableInitialCount: tileItems.count)

        if let quitAfter = options.quitAfter {
            Timer.scheduledTimer(withTimeInterval: quitAfter, repeats: false) { _ in
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func startBackgroundLoading(excluding excludedURLs: Set<URL>, usableInitialCount: Int) {
        guard let targetCount = options.limit, targetCount > usableInitialCount else {
            return
        }

        let sourceDirectories = sourceDirectories
        Task.detached(priority: .utility) { [weak self, sourceDirectories, excludedURLs, targetCount, usableInitialCount] in
            let targetCandidateCount = max(targetCount * 4, targetCount + 1000)
            let candidates = collectCandidateURLs(
                from: sourceDirectories,
                limit: targetCandidateCount,
                excluding: excludedURLs
            )
            var seenURLs = excludedURLs
            var batch: [TileItem] = []
            var usableCount = usableInitialCount

            func flushBatch() async {
                guard !batch.isEmpty else {
                    return
                }
                let items = batch
                batch.removeAll(keepingCapacity: true)
                await self?.appendBackgroundItems(items)
            }

            for candidate in candidates {
                guard usableCount < targetCount else {
                    break
                }
                guard !seenURLs.contains(candidate.url) else {
                    continue
                }
                seenURLs.insert(candidate.url)

                guard let item = loadTileItem(url: candidate.url) else {
                    continue
                }
                usableCount += 1
                batch.append(item)

                if batch.count >= backgroundAppendBatchSize {
                    await flushBatch()
                }
            }

            await flushBatch()
        }
    }

    private func appendBackgroundItems(_ items: [TileItem]) {
        guard !items.isEmpty else {
            return
        }
        loadedURLs.formUnion(items.map(\.url))
        tiledView?.appendItems(items)
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreAppPresentation()
    }

    private func advancePage(step: Int) {
        guard let tiledView else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastScrollWheelPageAt) > 0.18 else {
            return
        }
        lastScrollWheelPageAt = now

        let pageCount = tiledView.pageCount
        guard pageCount > 1 else {
            currentPage = 0
            scrollToCurrentPage(animated: false)
            return
        }

        currentPage = (currentPage + step + pageCount) % pageCount
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
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.contentView.animator().setBoundsOrigin(target)
            } completionHandler: {
                Task { @MainActor in
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        } else {
            scrollView.contentView.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

}

@MainActor
final class SlideshowController: NSObject, NSApplicationDelegate {
    private let imageURLs: [URL]
    private let options: ViewOptions
    private var window: SlideshowWindow?
    private var frontImageView = NSImageView()
    private var backImageView = NSImageView()
    private var timer: Timer?
    private var index = 0

    init(imageURLs: [URL], options: ViewOptions) {
        self.imageURLs = imageURLs
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let screen = NSScreen.main
        let frame: NSRect
        let style: NSWindow.StyleMask

        if options.windowed {
            frame = windowedFrame(on: screen, width: 1040, height: 680)
            style = [.titled, .closable, .miniaturizable, .resizable]
        } else {
            frame = fullscreenFrame(on: screen)
            style = [.borderless]
        }

        let contentView = SlideshowView(frame: frame)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.onAdvance = { [weak self] in self?.advance(step: 1) }
        contentView.onBack = { [weak self] in self?.advance(step: -1) }

        configure(frontImageView, in: contentView)
        configure(backImageView, in: contentView)

        let window = SlideshowWindow(
            contentRect: frame,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = "Lightpaper"
        window.backgroundColor = .black
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)

        if !options.windowed {
            configureFullscreenAppWindow(window)
        }

        self.window = window
        showImage(at: index, animated: false)
        timer = Timer.scheduledTimer(withTimeInterval: options.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advance(step: 1)
            }
        }

        if let quitAfter = options.quitAfter {
            Timer.scheduledTimer(withTimeInterval: quitAfter, repeats: false) { _ in
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        restoreAppPresentation()
    }

    private func configure(_ imageView: NSImageView, in view: NSView) {
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.alphaValue = 0
        view.addSubview(imageView)
    }

    private func advance(step: Int) {
        guard !imageURLs.isEmpty else {
            return
        }
        index = (index + step + imageURLs.count) % imageURLs.count
        showImage(at: index, animated: true)
    }

    private func showImage(at index: Int, animated: Bool) {
        guard let image = loadImage(from: imageURLs[index]) else {
            advance(step: 1)
            return
        }

        backImageView.image = image
        backImageView.alphaValue = 0
        backImageView.frame = frontImageView.frame

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.6 : 0
            frontImageView.animator().alphaValue = 0
            backImageView.animator().alphaValue = 1
        } completionHandler: {
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let oldFront = self.frontImageView
                self.frontImageView = self.backImageView
                self.backImageView = oldFront
            }
        }
    }

    private func loadImage(from url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let maxPixelSize = max(window?.frame.width ?? 2400, window?.frame.height ?? 1600) * 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

func printUsage() {
    let usage = """
    Usage:
      lightpaper-view [--library PATH] [--mode mosaic|tile|collage|slideshow] [--source previews|originals|all] [--interval SECONDS] [--windowed] [--limit N] [--quit-after SECONDS]

    Examples:
      swift run lightpaper-view -- --mode mosaic --windowed --limit 500
      swift run lightpaper-view -- --mode slideshow --source previews

    Keys:
      Space / Right Arrow / Down Arrow / L: next screen or photo
      Left Arrow / Up Arrow / J: previous screen or photo
      Esc / Q: quit
    """
    print(usage)
}

func parseOptions(_ arguments: [String]) throws -> ViewOptions {
    var options = ViewOptions()
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--":
            break
        case "--help", "-h":
            printUsage()
            exit(0)
        case "--library":
            index += 1
            guard index < arguments.count else {
                throw ViewError.invalidArgument("--library requires a path")
            }
            options.libraryPath = NSString(string: arguments[index]).expandingTildeInPath
        case "--source":
            index += 1
            guard index < arguments.count else {
                throw ViewError.invalidArgument("--source requires previews, originals, or all")
            }
            switch arguments[index] {
            case "previews":
                options.sourceFilter = [.preview]
            case "originals":
                options.sourceFilter = [.original]
            case "all":
                options.sourceFilter = Set(SourceKind.allCases)
            default:
                throw ViewError.invalidArgument("--source must be previews, originals, or all")
            }
        case "--mode":
            index += 1
            guard index < arguments.count else {
                throw ViewError.invalidArgument("--mode requires mosaic, tile, collage, or slideshow")
            }
            switch arguments[index] {
            case "collage":
                options.mode = .collage
            case "mosaic":
                options.mode = .mosaic
            case "tile":
                options.mode = .tile
            case "slideshow":
                options.mode = .slideshow
            default:
                throw ViewError.invalidArgument("--mode must be mosaic, tile, collage, or slideshow")
            }
        case "--interval":
            index += 1
            guard index < arguments.count, let interval = TimeInterval(arguments[index]), interval > 0 else {
                throw ViewError.invalidArgument("--interval requires a positive number")
            }
            options.interval = interval
        case "--windowed":
            options.windowed = true
        case "--limit":
            index += 1
            guard index < arguments.count, let limit = Int(arguments[index]), limit > 0 else {
                throw ViewError.invalidArgument("--limit requires a positive integer")
            }
            options.limit = limit
        case "--quit-after":
            index += 1
            guard index < arguments.count, let quitAfter = TimeInterval(arguments[index]), quitAfter > 0 else {
                throw ViewError.invalidArgument("--quit-after requires a positive number")
            }
            options.quitAfter = quitAfter
        default:
            throw ViewError.invalidArgument("Unknown argument: \(argument)")
        }
        index += 1
    }

    return options
}

func defaultLibraryCandidates() -> [URL] {
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

func findLibrary(path: String?) throws -> URL {
    if let path {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ViewError.unreadableLibrary(url.path)
        }
        return url
    }

    for url in defaultLibraryCandidates() {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
    }

    throw ViewError.noLibraryFound
}

func findScanRoots(in libraryURL: URL) throws -> [ScanRoot] {
    guard let children = try? FileManager.default.contentsOfDirectory(
        at: libraryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw ViewError.unreadableLibrary(libraryURL.path)
    }

    return children.compactMap { child in
        let managedCatalog = child.appendingPathComponent("Managed Catalog.mcat")
        let previews = child.appendingPathComponent("previews", isDirectory: true)
        let originals = child.appendingPathComponent("originals", isDirectory: true)
        if FileManager.default.fileExists(atPath: managedCatalog.path)
            || FileManager.default.fileExists(atPath: previews.path)
            || FileManager.default.fileExists(atPath: originals.path) {
            return ScanRoot(accountURL: child)
        }
        return nil
    }
}

func mediaFormat(for url: URL) -> MediaFormat {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
        return .unknown
    }
    defer {
        try? handle.close()
    }

    let data = (try? handle.read(upToCount: 16)) ?? Data()
    let bytes = [UInt8](data)

    if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
        return .jpeg
    }
    if bytes.count >= 8,
       bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
       bytes[4] == 0x0D, bytes[5] == 0x0A, bytes[6] == 0x1A, bytes[7] == 0x0A {
        return .png
    }
    if bytes.count >= 4,
       ((bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00)
        || (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A)) {
        return .tiff
    }
    if bytes.count >= 12 {
        let marker = String(bytes: bytes[4..<8], encoding: .ascii)
        let brand = String(bytes: bytes[8..<12], encoding: .ascii)
        if marker == "ftyp", let brand, ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) {
            return .heif
        }
    }

    return .unknown
}

func loadTileItem(url: URL) -> TileItem? {
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

func collectSourceDirectories(options: ViewOptions) throws -> [SourceDirectory] {
    let libraryURL = try findLibrary(path: options.libraryPath)
    let roots = try findScanRoots(in: libraryURL)
    var sourceDirectories: [SourceDirectory] = []

    for root in roots {
        let directories: [(SourceKind, URL)] = [
            (.original, root.accountURL.appendingPathComponent("originals", isDirectory: true)),
            (.preview, root.accountURL.appendingPathComponent("previews", isDirectory: true))
        ]

        for (source, directory) in directories where options.sourceFilter.contains(source) {
            guard FileManager.default.fileExists(atPath: directory.path) else {
                continue
            }
            sourceDirectories.append(SourceDirectory(source: source, directory: directory))
        }
    }

    return sourceDirectories
}

func collectMediaURLs(options: ViewOptions, sourceDirectories: [SourceDirectory], limit: Int?) throws -> [URL] {
    let candidates = collectCandidateURLs(from: sourceDirectories, limit: limit, excluding: [])
    guard !candidates.isEmpty else {
        throw ViewError.noImagesFound
    }

    let orderedCandidates = candidates.shuffled()

    if let limit {
        return orderedCandidates.prefix(limit).map(\.url)
    }

    return orderedCandidates.map(\.url)
}

func collectCandidateURLs(
    from sourceDirectories: [SourceDirectory],
    limit: Int?,
    excluding excludedURLs: Set<URL>
) -> [MediaCandidate] {
    let targetCount = limit ?? defaultImageLimit
    var candidates: [MediaCandidate] = []
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
            guard candidates.count < targetCount else {
                return candidates
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
            candidates.append(MediaCandidate(url: url))
        }
    }

    return candidates
}

func candidateDirectories(for source: SourceKind, under root: URL) -> [URL] {
    switch source {
    case .preview:
        return [root] + childDirectories(under: root)
    case .original:
        let years = childDirectories(under: root)
        let dates = years.flatMap(childDirectories)
        return [root] + years + dates
    }
}

func childDirectories(under root: URL) -> [URL] {
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

func isLikelyImageURL(_ url: URL) -> Bool {
    let extensionName = url.pathExtension.lowercased()
    guard !extensionName.isEmpty else {
        return true
    }
    return ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"].contains(extensionName)
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let sourceDirectories = try collectSourceDirectories(options: options)
    let initialLimit = min(options.limit ?? defaultImageLimit, initialImageURLLimit)
    let imageURLs = try collectMediaURLs(options: options, sourceDirectories: sourceDirectories, limit: initialLimit)
    print("Loaded \(imageURLs.count) initial Lightroom cache images.")

    let app = NSApplication.shared
    let delegate: NSApplicationDelegate = switch options.mode {
    case .collage:
        TileController(
            imageURLs: imageURLs,
            sourceDirectories: sourceDirectories,
            options: options,
            overlapFraction: 0.18
        )
    case .mosaic:
        TileController(
            imageURLs: imageURLs,
            sourceDirectories: sourceDirectories,
            options: options,
            overlapFraction: 0,
            editorialLayout: true
        )
    case .tile:
        TileController(
            imageURLs: imageURLs,
            sourceDirectories: sourceDirectories,
            options: options,
            overlapFraction: 0
        )
    case .slideshow:
        SlideshowController(imageURLs: imageURLs, options: options)
    }
    app.delegate = delegate
    app.run()
} catch let error as ViewError {
    FileHandle.standardError.write(Data("Error: \(error.description)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
