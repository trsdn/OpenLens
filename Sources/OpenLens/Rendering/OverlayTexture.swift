import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// A PNG (or any alpha-capable image) composited on top of the output.
struct OverlayTexture {
    var texture: MTLTexture
    /// Placement in normalized output space, top-left origin.
    var rect: CGRect
    var opacity: CGFloat
    var pixelSize: CGSize
}

enum OverlayLoader {
    enum LoadError: Error {
        case unreadable
        case textureCreationFailed
    }

    /// Decodes once into a premultiplied RGBA texture.
    ///
    /// Premultiplying up front means the shader's blend is a single mad rather
    /// than a divide per pixel, and it is the format `CGContext` produces anyway.
    static func load(url: URL, device: MTLDevice) throws -> (MTLTexture, CGSize) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw LoadError.unreadable }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = data.withUnsafeMutableBytes({ buffer -> CGContext? in
                  CGContext(
                      data: buffer.baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
              })
        else { throw LoadError.unreadable }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LoadError.textureCreationFailed
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return (texture, CGSize(width: width, height: height))
    }
}
