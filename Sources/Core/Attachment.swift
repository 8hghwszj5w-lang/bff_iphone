import Foundation
import UIKit
import Vision
import PDFKit
import ImageIO

// MARK: - 附件内容提取（全部本机完成，不消耗额外 API：图片走 Vision OCR，PDF 走 PDFKit，其余按纯文本）
//
// 当前主链路：图片/常见文档已改为直传 DeepSeek（见 Pipeline.handle + uploadPurpose），
// 这里主要剩两类工作：
// · uploadPurpose  决定每个扩展名走 Files API 哪个 purpose（改支持范围就看它）
// · fileText       直传不支持/上传失败时的本地纯文本兜底
// ocr()/image() 目前不在发送链路上（直传后模型自己"看图"），
// ocr 保留是因为以后若要做"图片文字提取给 v4-pro"的降级方案可以直接用。

enum AttachmentError: LocalizedError {
    case binaryFile
    case emptyFile
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .binaryFile: return "这个文件看起来是二进制格式，暂时只能读取纯文本和 PDF。"
        case .emptyFile: return "这个文件是空的。"
        case .invalidImage: return "这张图读取失败，换一张试试。"
        }
    }
}

enum AttachmentExtractor {
    static let maxFileChars = 8000
    static let maxOCRChars = 4000

    /// ImageIO 在解码时缩小，而不是先展开整张大图再缩放；同时应用 EXIF 方向。
    /// 调用方应在后台执行。4096px 足够保留通常文档 OCR 的细节。
    static func image(from data: Data, maxPixelSize: Int = 4096) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    static func image(from url: URL, maxPixelSize: Int = 4096) -> UIImage? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    /// 图片 → 文字（Apple Vision，离线 OCR）
    static func ocr(from image: UIImage) async -> String {
        await Task.detached(priority: .userInitiated) {
            guard let cgImage = image.cgImage else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage,
                                               orientation: cgOrientation(image.imageOrientation),
                                               options: [:])
            do {
                try handler.perform([request])
            } catch {
                return ""
            }
            var text = ""
            for observation in request.results ?? [] {
                guard let line = observation.topCandidates(1).first?.string else { continue }
                if !text.isEmpty { text += "\n" }
                text += String(line.prefix(max(0, maxOCRChars - text.count)))
                if text.count >= maxOCRChars { break }
            }
            return text
        }.value
    }

    private static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    /// 按扩展名决定 Files API 的 purpose（见官方 Files API 文档）；
    /// 返回 nil 表示该类型不能直传，走本地纯文本兜底。
    static func uploadPurpose(ext: String) -> String? {
        switch ext {
        // PDF / Word / PPT → 官方解析通道（只取文字）
        case "pdf", "doc", "docx", "ppt", "pptx":
            return "text_recognition"
        // 纯文本 / 代码 / 表格 / 电子书 → user_data
        case "txt", "md", "csv", "json", "log", "yaml", "yml", "html", "xml", "toml", "ini",
             "ts", "js", "py", "swift", "java", "c", "h", "cpp", "go", "rs", "rb", "php", "sh",
             "xlsx", "xls", "epub", "mobi":
            return "user_data"
        default:
            return nil
        }
    }

    /// 图片扩展名（可转 base64 内联，或经 user_data 直传）
    static func isImageExt(_ ext: String) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp"].contains(ext)
    }

    /// 文件 → 文本（PDF 走 PDFKit；其他按 UTF-8 纯文本，拒绝二进制）。后台调用。
    static func fileText(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        if url.pathExtension.lowercased() == "pdf",
           let doc = PDFDocument(url: url) {
            var text = ""
            var readPages = 0
            let pages = min(doc.pageCount, 50)
            for i in 0..<pages {
                // 页面的临时 PDFKit 对象及时释放；已有足够文本就不再提取后续页。
                let pageText = autoreleasepool { doc.page(at: i)?.string ?? "" }
                readPages = i + 1
                text += pageText + "\n"
                // 先修剪再判断，长前导空白/空白页不能挤掉后续真正的文本。
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { text = "" }
                if trimmed.prefix(maxFileChars + 1).count > maxFileChars {
                    text = trimmed
                    break
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw AttachmentError.emptyFile }
            let truncated = text.prefix(maxFileChars + 1).count > maxFileChars || readPages < doc.pageCount
            let note = truncated ? "\n\n（PDF 共 \(doc.pageCount) 页，已截取前 \(readPages) 页中的部分内容）" : ""
            return String(text.prefix(maxFileChars)) + note
        }

        // 保留完整 UTF-8/NUL 校验（包括文件末尾），以及前导空白和组合字素的语义。
        // 可安全映射时避免额外的整文件 Data 堆拷贝；此路径由调用方在后台运行。
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.isEmpty { throw AttachmentError.emptyFile }
        if data.contains(0) { throw AttachmentError.binaryFile }
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw AttachmentError.binaryFile
        }
        let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只计数待发送前缀，而不是为判断截断遍历整个大字符串的字素。
        let prefix = String(text.prefix(maxFileChars + 1))
        let note = prefix.count > maxFileChars ? "\n\n（内容过长已截断）" : ""
        return String(prefix.prefix(maxFileChars)) + note
    }
}
