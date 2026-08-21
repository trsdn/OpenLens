import Foundation

/// Colour correction folded into the existing render pass.
///
/// Every value is neutral at zero and symmetric around it, so the middle of a
/// slider is always "untouched" and a reset is unambiguous.
///
/// The maths deliberately runs in YCbCr rather than RGB, because that is the
/// colour space the camera already delivers: exposure and contrast touch only
/// luma, white balance and saturation touch only chroma. In the NV12 output
/// path those are two separate fragment shaders anyway, so each adjustment
/// lands in the shader that already owns that plane — no RGB round trip, no
/// extra pass, a handful of arithmetic operations per pixel.
public struct ImageAdjustments: Codable, Equatable, Sendable {
    /// Stops of exposure: -1 halves the light, +1 doubles it.
    public var exposure: Double = 0
    /// -1 flattens the image, +1 steepens it around mid grey.
    public var contrast: Double = 0
    /// -1 is monochrome, +1 is twice the colour.
    public var saturation: Double = 0
    /// -1 cools towards blue, +1 warms towards amber.
    public var temperature: Double = 0

    public init(
        exposure: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        temperature: Double = 0
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
    }

    public static let neutral = ImageAdjustments()

    /// Exposure is the one control with a real-world unit, so it gets a wider
    /// range than the dimensionless ones.
    public static let exposureRange: ClosedRange<Double> = -2...2
    public static let unitRange: ClosedRange<Double> = -1...1

    public var isNeutral: Bool { self == .neutral }

    // MARK: - Shader coefficients
    //
    // Converted here rather than in the shader so the per-pixel cost stays at
    // one multiply-add: `pow` in particular would otherwise run two million
    // times per frame to produce a value that only changes when a slider moves.

    /// Linear light multiplier. Exposure is measured in stops, hence 2^n.
    public var exposureGain: Double { pow(2, exposure) }

    /// Slope around mid grey, 0.5x to 1.5x.
    public var contrastGain: Double { 1 + contrast * 0.5 }

    /// Chroma multiplier, 0 (grey) to 2.
    public var saturationGain: Double { 1 + saturation }

    /// Chroma offset applied against Cb and towards Cr.
    ///
    /// Kept small: chroma only spans +/-0.5 in total, so 0.06 is already a
    /// pronounced shift and anything larger clips colour before the slider
    /// reaches its end.
    public var temperatureShift: Double { temperature * 0.06 }
}
