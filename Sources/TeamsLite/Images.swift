import AppKit
import ImageIO
import UniformTypeIdentifiers

extension NSAttributedString.Key {
    /// Marks an inline image placeholder produced by the HTML converter (value: ImageRef).
    static let teamsLiteImage = NSAttributedString.Key("TeamsLiteImage")
}

final class ImageRef: NSObject {
    let src: String
    let width: CGFloat?
    let height: CGFloat?

    init(src: String, width: CGFloat?, height: CGFloat?) {
        self.src = src
        self.width = width
        self.height = height
    }

    /// Display size in points, capped so a screenshot doesn't take over the transcript.
    func displaySize(for image: NSImage? = nil) -> NSSize {
        var w = image?.size.width ?? width ?? 240
        var h = image?.size.height ?? height ?? 160
        let scale = min(1, ImageStore.maxPoints / max(w, 1), ImageStore.maxPoints / max(h, 1))
        w *= scale
        h *= scale
        return NSSize(width: max(w.rounded(), 24), height: max(h.rounded(), 24))
    }
}

/// Inline images: thumbnails decoded at display size (never the full bitmap), kept in a
/// small LRU capped by decoded bytes. Loads run one at a time because Graph allows about
/// one hosted-content request per second per chat.
@MainActor
final class ImageStore {
    nonisolated static let maxPoints: CGFloat = 320
    private let maxBytes = 12 * 1024 * 1024

    private let graph: Graph
    private let http: URLSession
    private var cache: [String: (image: NSImage, cost: Int)] = [:]
    private var lru: [String] = []
    private var total = 0
    private var queue: [String] = []
    private var queued: Set<String> = []
    private var failed: Set<String> = []
    private var running = false
    var onLoaded: ((String) -> Void)?

    init(graph: Graph, http: URLSession) {
        self.graph = graph
        self.http = http
        try? FileManager.default.removeItem(at: Self.tempDir)
    }

    func image(_ src: String) -> NSImage? {
        guard let entry = cache[src] else { return nil }
        lru.removeAll { $0 == src }
        lru.append(src)
        return entry.image
    }

    func hasFailed(_ src: String) -> Bool { failed.contains(src) }

    /// Newest requests are served first (the user is usually looking at the bottom).
    func request(_ src: String) {
        guard cache[src] == nil, !failed.contains(src), !queued.contains(src) else { return }
        queued.insert(src)
        queue.append(src)
        pump()
    }

    func clear() {
        cache = [:]
        lru = []
        total = 0
        queue = []
        queued = []
        failed = []
    }

    private func pump() {
        guard !running, let src = queue.popLast() else { return }
        running = true
        Task {
            defer {
                queued.remove(src)
                running = false
                pump()
            }
            do {
                let data = try await fetch(src)
                let image = await Self.thumbnail(data, maxPixels: Int(Self.maxPoints * 2))
                guard let image else { throw GraphError.http(0, "Unsupported image") }
                store(src, image)
                onLoaded?(src)
            } catch {
                failed.insert(src)
                log.error("Image load failed: \(error.localizedDescription, privacy: .public)")
                onLoaded?(src)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    func store(_ src: String, _ image: NSImage) {
        let px = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? Int(image.size.width * image.size.height * 4)
        let cost = px * 4
        cache[src] = (image, cost)
        lru.append(src)
        total += cost
        while total > maxBytes, lru.count > 1 {
            let evicted = lru.removeFirst()
            total -= cache.removeValue(forKey: evicted)?.cost ?? 0
        }
    }

    /// Graph-hosted content needs the bearer token; other https images (GIFs, stickers) don't.
    func fetch(_ src: String) async throws -> Data {
        guard let url = URL(string: src), url.scheme == "https" else { throw GraphError.http(0, "Unsupported image URL") }
        if url.host == "graph.microsoft.com" {
            return try await graph.send("GET", url, accept: "*/*")
        }
        let (data, resp) = try await http.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw GraphError.http(0, "Image download failed") }
        return data
    }

    /// Downloads the full image and opens it in the default viewer (Preview).
    func openFull(_ src: String) async throws {
        let data = try await fetch(src)
        let ext = Self.fileExtension(data)
        try FileManager.default.createDirectory(at: Self.tempDir, withIntermediateDirectories: true)
        let file = Self.tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: file)
        NSWorkspace.shared.open(file)
    }

    private static let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TeamsLite-images")

    nonisolated static func thumbnail(_ data: Data, maxPixels: Int) async -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Point size = half the pixels (Retina), so a 640 px thumbnail shows at 320 pt.
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }

    static func fileExtension(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let ext = UTType(type)?.preferredFilenameExtension else { return "png" }
        return ext
    }
}

/// An image the user is about to send (pasted, dropped or picked).
struct OutgoingImage {
    let data: Data
    let contentType: String
    let pixelWidth: Int
    let pixelHeight: Int

    static let maxBytes = 2_600_000
    static let maxTotalBytes = 2_800_000

    static func hasImages(_ pb: NSPasteboard) -> Bool {
        if pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]) != nil { return true }
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true }
    }

    /// Keeps PNG/JPEG/GIF as they are when small enough; otherwise scales to 2560 px and re-encodes as JPEG.
    static func make(from data: Data) -> OutgoingImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        let mime = type?.preferredMIMEType ?? ""
        if ["image/png", "image/jpeg", "image/gif"].contains(mime), data.count <= maxBytes, max(w, h) <= 4096 {
            return OutgoingImage(data: data, contentType: mime, pixelWidth: w, pixelHeight: h)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), 2560),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Screenshots usually arrive as TIFF: PNG keeps them sharp when it stays small enough.
        for (uti, mimeType, quality) in [(UTType.png, "image/png", 1.0), (UTType.jpeg, "image/jpeg", 0.85), (UTType.jpeg, "image/jpeg", 0.7)] {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, uti.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest), out.length <= maxBytes else { continue }
            return OutgoingImage(data: out as Data, contentType: mimeType, pixelWidth: cg.width, pixelHeight: cg.height)
        }
        return nil
    }

    /// Images found on a pasteboard (pasted screenshots, copied images, image files).
    static func from(pasteboard pb: NSPasteboard) -> [Data] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true }
            if !images.isEmpty { return images.compactMap { try? Data(contentsOf: $0) } }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let data = pb.data(forType: type) { return [data] }
        }
        return []
    }
}
