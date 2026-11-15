import XCTest
import UIKit
import SwiftUI
import PDFKit
@testable import FenShen

final class AttachmentTests: XCTestCase {
    private func file(_ data: Data, extension ext: String = "txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testUTF8TextIsTrimmedWithoutChangingContent() throws {
        let url = try file(Data(" \n你好 👩🏽‍💻 café\n ".utf8))
        XCTAssertEqual(try AttachmentExtractor.fileText(from: url), "你好 👩🏽‍💻 café")
    }

    func testLongTextTruncatesByCharactersNotBytes() throws {
        let unit = "👩🏽‍💻"
        let text = String(repeating: unit, count: 8001)
        let url = try file(Data(text.utf8))
        XCTAssertEqual(try AttachmentExtractor.fileText(from: url),
                       String(repeating: unit, count: 8000) + "\n\n（内容过长已截断）")
    }

    func testLargeLeadingWhitespaceDoesNotHideText() throws {
        let url = try file(Data((String(repeating: " ", count: 300_000) + "有效正文").utf8))
        XCTAssertEqual(try AttachmentExtractor.fileText(from: url), "有效正文")
    }

    func testBinaryAndInvalidUTF8AreRejectedIncludingFileTail() throws {
        for tail in [Data([0]), Data([0xFF]), Data([0xE4, 0xB8])] {
            var data = Data(repeating: 0x61, count: 300_000)
            data.append(tail)
            let url = try file(data)
            XCTAssertThrowsError(try AttachmentExtractor.fileText(from: url))
        }
    }

    func testEmptyFileIsRejected() throws {
        let url = try file(Data())
        XCTAssertThrowsError(try AttachmentExtractor.fileText(from: url))
    }

    @MainActor func testImageDownsamplingRespectsRequestedPixelLimit() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        let data = try XCTUnwrap(image.pngData())
        let decoded = try XCTUnwrap(AttachmentExtractor.image(from: data, maxPixelSize: 200))
        XCTAssertEqual(decoded.cgImage?.width, 200)
        XCTAssertEqual(decoded.cgImage?.height, 100)
        XCTAssertEqual(decoded.imageOrientation, .up)
    }

    func testDeltaBufferPreservesOrderAndRejectsLateDeltas() {
        let buffer = ChatDeltaBuffer()
        buffer.append("你")
        buffer.append("好")
        XCTAssertEqual(buffer.drain(), "你好")
        XCTAssertEqual(buffer.drain(), "")
        buffer.append("最后")
        XCTAssertEqual(buffer.finish(), "最后")
        buffer.append("迟到")
        XCTAssertEqual(buffer.drain(), "")
    }

    func testDeltaBufferConcurrentAppendsDoNotLoseText() {
        let buffer = ChatDeltaBuffer()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in buffer.append("x") }
        XCTAssertEqual(buffer.finish(), String(repeating: "x", count: 1000))
    }

    @MainActor func testCropCanvasFillsExportedFrameAtBaseScale() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        }
        let canvas = CropCanvas(image: image, frame: CGSize(width: 100, height: 100),
                                fit: 0.25, scale: 1, offset: .zero)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        let result = try XCTUnwrap(renderer.uiImage?.cgImage)
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 100)
        var pixels = [UInt8](repeating: 0, count: 100 * 100 * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 100, height: 100,
                                             bitsPerComponent: 8, bytesPerRow: 400,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(result, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        for (x, y) in [(1, 1), (98, 1), (1, 98), (98, 98), (50, 50)] {
            let offset = (y * 100 + x) * 4
            XCTAssertGreaterThan(pixels[offset], 240, "导出画布不应露底")
            XCTAssertEqual(pixels[offset + 3], 255)
        }
    }
}
