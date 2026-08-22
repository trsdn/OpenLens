import Foundation

/// Colour correction folded into the existing render pass.
///
/// Every value is neutral at zero and symmetric around it, so the middle of a
/// slider is always "untouched" and a reset is unambiguous.
///
/// The maths deliberately runs in YCbCr rather than RGB, because that is the
/// colour space the camera already delivers: the tonal controls touch only
/// luma, the colour controls touch only chroma. In the NV12 output path those
/// are two separate fragment shaders anyway, so each adjustment lands in the
/// shader that already owns that plane — no RGB round trip, no extra pass, a
/// handful of arithmetic operations per pixel.
///
/// The one crossing between the two is deliberate: the shadow and highlight
/// white balance controls need to know how bright a pixel is before they can
/// decide how much to shift it, so the chroma shader samples the luma plane as
/// well. That plane is already resident, and chroma is quarter resolution, so
/// it costs a quarter of one extra texture read per output pixel.
public struct ImageAdjustments: Codable, Equatable, Sendable {
    /// Stops of exposure: -1 halves the light, +1 doubles it.
    public var exposure: Double = 0
    /// Where the darkest pixel lands. +1 pulls the black point up into the
    /// picture so shadows reach true black, -1 lifts them into a soft fade.
    public var blackPoint: Double = 0
    /// The same at the top end: +1 pulls the white point down so highlights
    /// reach true white, -1 holds them back.
    public var whitePoint: Double = 0
    /// Gamma. +1 opens the midtones without moving either end point.
    public var midtones: Double = 0
    /// -1 flattens the image, +1 steepens it around mid grey.
    public var contrast: Double = 0
    /// -1 is monochrome, +1 is twice the colour.
    public var saturation: Double = 0
    /// -1 cools towards blue, +1 warms towards amber.
    public var temperature: Double = 0
    /// White balance for the shadows alone, on the same warm/cool axis.
    public var shadowWarmth: Double = 0
    /// White balance for the highlights alone.
    public var highlightWarmth: Double = 0

    public init(
        exposure: Double = 0,
        blackPoint: Double = 0,
        whitePoint: Double = 0,
        midtones: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        temperature: Double = 0,
        shadowWarmth: Double = 0,
        highlightWarmth: Double = 0
    ) {
        self.exposure = exposure
        self.blackPoint = blackPoint
        self.whitePoint = whitePoint
        self.midtones = midtones
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.shadowWarmth = shadowWarmth
        self.highlightWarmth = highlightWarmth
    }

    /// Hand-written so that a scene file saved before a control existed still
    /// loads: synthesised decoding treats a missing key as an error rather
    /// than falling back to the property's default, which would make every
    /// added slider wipe the user's saved scenes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Double {
            try container.decodeIfPresent(Double.self, forKey: key) ?? 0
        }
        exposure = try value(.exposure)
        blackPoint = try value(.blackPoint)
        whitePoint = try value(.whitePoint)
        midtones = try value(.midtones)
        contrast = try value(.contrast)
        saturation = try value(.saturation)
        temperature = try value(.temperature)
        shadowWarmth = try value(.shadowWarmth)
        highlightWarmth = try value(.highlightWarmth)
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

    /// How far the end points may travel. A fifth of the range is already a
    /// drastic move on a normally exposed picture, and stopping there keeps the
    /// slider usable across its whole length instead of doing everything in the
    /// first few percent.
    private static let endPointTravel = 0.20

    /// The input level that becomes black.
    public var blackLevel: Double { blackPoint * Self.endPointTravel }

    /// The input level that becomes white.
    public var whiteLevel: Double { 1 - whitePoint * Self.endPointTravel }

    /// Slope between the two end points. Floored so that dragging both to their
    /// extremes cannot divide by zero or invert the picture.
    public var levelsGain: Double { 1 / max(whiteLevel - blackLevel, 0.05) }

    /// Gamma exponent. Negated so that a positive slider opens the midtones,
    /// which is the direction a "brighter" label implies.
    public var midtoneExponent: Double { pow(2, -midtones) }

    /// Strength of the contrast S-curve.
    ///
    /// Deliberately not a straight slope: a linear `(y - 0.5) * gain` pushes
    /// highlights past white long before the slider runs out, and a face lit
    /// from one side is exactly the picture where that shows first. The curve
    /// in the shader tapers to nothing at both ends, so contrast reshapes the
    /// midtones and leaves the end points where the levels controls put them.
    public var contrastAmount: Double { contrast * 0.5 }

    /// Chroma multiplier, 0 (grey) to 2.
    public var saturationGain: Double { 1 + saturation }

    /// Chroma offset applied against Cb and towards Cr.
    ///
    /// Kept small: chroma only spans +/-0.5 in total, so 0.06 is already a
    /// pronounced shift and anything larger clips colour before the slider
    /// reaches its end.
    public var temperatureShift: Double { temperature * 0.06 }

    /// The same shift, weighted towards the dark end of the picture.
    ///
    /// Split from the global control because a room rarely has one colour
    /// temperature: a warm key light on the face and cooler ambient light
    /// filling the shadows leave a cast that runs in opposite directions at
    /// opposite ends of the scale, and no single white balance can correct
    /// both at once.
    public var shadowShift: Double { shadowWarmth * 0.06 }

    /// The same again, weighted towards the light end.
    public var highlightShift: Double { highlightWarmth * 0.06 }
}
