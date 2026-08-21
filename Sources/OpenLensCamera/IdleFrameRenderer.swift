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
