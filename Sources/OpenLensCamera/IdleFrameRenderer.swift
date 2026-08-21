import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// Draws the "OpenLens isn't running" card exactly once at launch.
///
/// The result is a static buffer that gets re-sent every frame while idle, so
/// the steady-state cost of an unattended virtual camera is a memcpy-free
/// `stream.send`.
enum IdleFrameRenderer {
    static func makePlaceholder() -> CVPixelBuffer? {
        guard let bgra = drawCard() else { return nil }
        return convertToNV12(bgra)
    }

    private static func drawCard() -> CVPixelBuffer? {
        let width = OpenLensOutput.width
        let height = OpenLensOutput.height

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        context.setFillColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        draw(
            text: "OpenLens",
            in: context,
            fontSize: 96,
            weight: 0.3,
            gray: 0.92,
            centerY: CGFloat(height) / 2 + 20,
            width: width
        )
        draw(
            text: "Open the app to start your camera",
            in: context,
            fontSize: 36,
            weight: 0,
            gray: 0.45,
            centerY: CGFloat(height) / 2 - 70,
            width: width
        )

        return pixelBuffer
    }

    /// Converts the card to the stream's NV12 layout.
    ///
    /// This runs once at launch, so a plain loop is clearer than pulling in an
    /// accelerated path for a single frame. The coefficients are BT.601 video
    /// range, matching what the app's shader writes, so the placeholder and live
    /// video decode identically.
    private static func convertToNV12(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: OpenLensOutput.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            OpenLensOutput.pixelFormat,
            attributes as CFDictionary,
            &destination
        ) == kCVReturnSuccess, let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let src = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self),
              let lumaPlane = CVPixelBufferGetBaseAddressOfPlane(destination, 0)?
                  .assumingMemoryBound(to: UInt8.self),
              let chromaPlane = CVPixelBufferGetBaseAddressOfPlane(destination, 1)?
                  .assumingMemoryBound(to: UInt8.self)
        else { return nil }

        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)

        // BGRA in memory little-endian: byte 0 = blue, 1 = green, 2 = red.
        func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
            0.299 * r + 0.587 * g + 0.114 * b
        }

        for y in 0..<height {
            let srcRow = src + y * srcStride
            let lumaRow = lumaPlane + y * lumaStride
            for x in 0..<width {
                let pixel = srcRow + x * 4
                let blue = Double(pixel[0]) / 255
                let green = Double(pixel[1]) / 255
                let red = Double(pixel[2]) / 255
                lumaRow[x] = UInt8(clamping: Int((luma(red, green, blue) * 219 + 16).rounded()))
            }
        }

        for y in stride(from: 0, to: height, by: 2) {
            let chromaRow = chromaPlane + (y / 2) * chromaStride
            for x in stride(from: 0, to: width, by: 2) {
                var red = 0.0, green = 0.0, blue = 0.0
                for dy in 0..<2 where y + dy < height {
                    let srcRow = src + (y + dy) * srcStride
                    for dx in 0..<2 where x + dx < width {
                        let pixel = srcRow + (x + dx) * 4
                        blue += Double(pixel[0]) / 255
                        green += Double(pixel[1]) / 255
                        red += Double(pixel[2]) / 255
                    }
                }
                red /= 4; green /= 4; blue /= 4
                let y01 = luma(red, green, blue)
                let cb = (blue - y01) / 1.772 * 255 + 128
                let cr = (red - y01) / 1.402 * 255 + 128
                chromaRow[x] = UInt8(clamping: Int(cb.rounded()))
                chromaRow[x + 1] = UInt8(clamping: Int(cr.rounded()))
            }
        }

        CVBufferSetAttachment(
            destination, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate
        )
        return destination
    }

    private static func draw(
        text: String,
        in context: CGContext,
        fontSize: CGFloat,
        weight: CGFloat,
        gray: CGFloat,
        centerY: CGFloat,
        width: Int
    ) {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        // CoreText keys rather than AppKit's: the extension links neither AppKit
        // nor UIKit, so `NSAttributedString.Key.font` does not exist here.
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: gray, green: gray, blue: gray, alpha: 1),
            kCTKernAttributeName: fontSize * 0.01 * (1 + weight)
        ]
        guard let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            text as CFString,
            attributes as CFDictionary
        ) else { return }

        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(
            x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
            y: centerY
        )
        CTLineDraw(line, context)
    }
}
