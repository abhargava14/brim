import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Converts and shrinks images with ImageIO: JPEG, PNG, HEIC, or a PDF with one page per image.
public enum ImageConverter {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case jpeg, png, heic, pdf

        public var id: String { rawValue }
        public var title: String { rawValue.uppercased() }
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        var type: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            case .heic: return .heic
            case .pdf: return .pdf
            }
        }
    }

    public struct Result: Identifiable, Sendable {
        public let id = UUID()
        public let source: URL
        public let output: URL?
        public let before: Int64
        public let after: Int64
        public let error: String?
    }

    public static let imageTypes: [UTType] = [.image]

    /// Converts each file next to the original ("photo.heic" → "photo.jpg", or "photo 2.jpg" if taken).
    /// `maxSide` shrinks the longer edge (0 keeps the size); `quality` applies to JPEG and HEIC.
    public static func convert(_ urls: [URL], to format: Format, quality: Double, maxSide: Int) -> [Result] {
        if format == .pdf { return [pdf(urls, maxSide: maxSide)] }
        return urls.map { url in
            let before = size(url)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = load(source, maxSide: maxSide) else {
                return Result(source: url, output: nil, before: before, after: 0, error: "Not an image Brim can read")
            }
            let output = freeURL(for: url, ext: format.fileExtension)
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.type.identifier as CFString, 1, nil) else {
                return Result(source: url, output: nil, before: before, after: 0, error: "This Mac can't write \(format.title)")
            }
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                return Result(source: url, output: nil, before: before, after: 0, error: "Couldn't save")
            }
            return Result(source: url, output: output, before: before, after: size(output), error: nil)
        }
    }

    static func pdf(_ urls: [URL], maxSide: Int) -> Result {
        let document = PDFDocument()
        var before: Int64 = 0
        for url in urls {
            before += size(url)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = load(source, maxSide: maxSide),
                  let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else { continue }
            document.insert(page, at: document.pageCount)
        }
        guard let first = urls.first, document.pageCount > 0 else {
            return Result(source: urls.first ?? URL(fileURLWithPath: "/"), output: nil, before: before, after: 0, error: "No images to put in a PDF")
        }
        let output = freeURL(for: first, ext: "pdf")
        guard document.write(to: output) else {
            return Result(source: first, output: nil, before: before, after: 0, error: "Couldn't save the PDF")
        }
        return Result(source: first, output: output, before: before, after: size(output), error: nil)
    }

    /// The image, keeping its orientation, scaled so its longer side is at most `maxSide`.
    static func load(_ source: CGImageSource, maxSide: Int) -> CGImage? {
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceCreateThumbnailFromImageAlways: true]
        if maxSide > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxSide
        } else if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 4096
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 4096
            options[kCGImageSourceThumbnailMaxPixelSize] = max(width, height)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func freeURL(for url: URL, ext: String) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    public static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
