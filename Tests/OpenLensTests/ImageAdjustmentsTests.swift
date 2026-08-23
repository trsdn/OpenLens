import XCTest

final class ImageAdjustmentsTests: XCTestCase {
    // MARK: - Coefficients

    func testNeutralAdjustmentsAreIdentityInTheShader() {
        let neutral = ImageAdjustments.neutral
        XCTAssertTrue(neutral.isNeutral)
        // Every one of these is applied to every pixel, so anything other than
        // an exact identity here tints, dims or reshapes the whole picture
        // before a slider has been touched.
        XCTAssertEqual(neutral.exposureGain, 1, accuracy: 1e-12)
        XCTAssertEqual(neutral.blackLevel, 0, accuracy: 1e-12)
        XCTAssertEqual(neutral.whiteLevel, 1, accuracy: 1e-12)
        XCTAssertEqual(neutral.levelsGain, 1, accuracy: 1e-12)
        XCTAssertEqual(neutral.midtoneExponent, 1, accuracy: 1e-12)
        XCTAssertEqual(neutral.contrastAmount, 0, accuracy: 1e-12)
        XCTAssertEqual(neutral.saturationGain, 1, accuracy: 1e-12)
        XCTAssertEqual(neutral.temperatureShift, 0, accuracy: 1e-12)
        XCTAssertEqual(neutral.tintShift, 0, accuracy: 1e-12)
        XCTAssertEqual(neutral.shadowShift, 0, accuracy: 1e-12)
        XCTAssertEqual(neutral.highlightShift, 0, accuracy: 1e-12)
    }

    func testExposureIsMeasuredInStops() {
        XCTAssertEqual(ImageAdjustments(exposure: 1).exposureGain, 2, accuracy: 1e-9)
        XCTAssertEqual(ImageAdjustments(exposure: -1).exposureGain, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ImageAdjustments(exposure: 2).exposureGain, 4, accuracy: 1e-9)
    }

    // MARK: - Levels

    func testBlackPointMapsItsLevelOntoBlackAndLeavesWhiteAlone() {
        let deepened = ImageAdjustments(blackPoint: 0.5)
        XCTAssertGreaterThan(deepened.blackLevel, 0)
        XCTAssertEqual(
            (deepened.blackLevel - deepened.blackLevel) * deepened.levelsGain, 0, accuracy: 1e-12
        )
        XCTAssertEqual((1 - deepened.blackLevel) * deepened.levelsGain, 1, accuracy: 1e-12)
    }

    func testNegativeBlackPointFadesTheShadowsInsteadOfClippingThem() {
        let faded = ImageAdjustments(blackPoint: -0.5)
        // Input zero has to land above black, which is what a lifted shadow is.
        XCTAssertGreaterThan((0 - faded.blackLevel) * faded.levelsGain, 0)
    }

    func testEndPointsCannotCrossOrInvertThePicture() {
        // Both controls dragged to their extremes still has to leave a positive
        // slope, or the picture would come out as a negative.
        let extreme = ImageAdjustments(blackPoint: 1, whitePoint: 1)
        XCTAssertGreaterThan(extreme.levelsGain, 0)
        XCTAssertLessThanOrEqual(extreme.levelsGain, 1 / 0.05 + 1e-9)
    }

    func testPositiveMidtonesBrightenWithoutMovingTheEndPoints() {
        let opened = ImageAdjustments(midtones: 0.5)
        XCTAssertLessThan(opened.midtoneExponent, 1)
        // pow() fixes both 0 and 1 for any positive exponent, so only the
        // middle can move.
        XCTAssertGreaterThan(pow(0.5, opened.midtoneExponent), 0.5)
        XCTAssertEqual(pow(0.0, opened.midtoneExponent), 0, accuracy: 1e-12)
        XCTAssertEqual(pow(1.0, opened.midtoneExponent), 1, accuracy: 1e-12)
        XCTAssertGreaterThan(ImageAdjustments(midtones: -0.5).midtoneExponent, 1)
    }

    // MARK: - Contrast

    /// The S-curve exactly as the shader applies it, so what is asserted below
    /// is the curve the picture actually gets.
    private func curve(_ y: Double, _ adjustments: ImageAdjustments) -> Double {
        y + adjustments.contrastAmount * (y - 0.5) * (1 - abs(2 * y - 1))
    }

    func testContrastCannotPushAnEndPointPastItself() {
        // This is the whole reason the curve is not a straight slope: a linear
        // gain drives everything above mid grey towards clipping, and the
        // brightest part of a lit face is already close to it.
        for contrast in [-1.0, -0.5, 0.5, 1.0] {
            let adjustments = ImageAdjustments(contrast: contrast)
            XCTAssertEqual(curve(0, adjustments), 0, accuracy: 1e-12)
            XCTAssertEqual(curve(1, adjustments), 1, accuracy: 1e-12)
            XCTAssertLessThanOrEqual(curve(0.95, adjustments), 1)
            XCTAssertGreaterThanOrEqual(curve(0.05, adjustments), 0)
        }
    }

    func testContrastSteepensTheMidtonesInTheExpectedDirection() {
        let more = ImageAdjustments(contrast: 0.5)
        XCTAssertLessThan(curve(0.25, more), 0.25)
        XCTAssertGreaterThan(curve(0.75, more), 0.75)

        let less = ImageAdjustments(contrast: -0.5)
        XCTAssertGreaterThan(curve(0.25, less), 0.25)
        XCTAssertLessThan(curve(0.75, less), 0.75)

        // Mid grey is the pivot and must not drift, or contrast would double as
        // a brightness control.
        XCTAssertEqual(curve(0.5, more), 0.5, accuracy: 1e-12)
        XCTAssertEqual(curve(0.5, less), 0.5, accuracy: 1e-12)
    }

    func testContrastRemainsMonotonicAtItsExtremes() {
        // A curve that doubles back would swap the order of two brightnesses,
        // which shows up as banding on a gradient.
        for contrast in [-1.0, 1.0] {
            let adjustments = ImageAdjustments(contrast: contrast)
            var previous = -1.0
            for step in 0...200 {
                let value = curve(Double(step) / 200, adjustments)
                XCTAssertGreaterThan(value, previous)
                previous = value
            }
        }
    }

    // MARK: - Colour

    func testExtremesStayWithinUsableShaderRanges() {
        // Saturation must reach exactly zero for monochrome and must not go
        // negative, which would invert every hue.
        XCTAssertEqual(ImageAdjustments(saturation: -1).saturationGain, 0, accuracy: 1e-12)
        XCTAssertEqual(ImageAdjustments(saturation: 1).saturationGain, 2, accuracy: 1e-12)
        // Chroma only spans +/-0.5 in total. The shadow and highlight zones
        // never overlap, so the worst case is the global shift plus whichever
        // of the two is larger.
        let stacked = ImageAdjustments(temperature: 1, tint: 1, shadowWarmth: 1, highlightWarmth: 1)
        let worstCase = abs(stacked.temperatureShift)
            + abs(stacked.tintShift)
            + max(abs(stacked.shadowShift), abs(stacked.highlightShift))
        XCTAssertLessThan(worstCase, 0.25)
    }

    func testTemperatureIsSignedAroundNeutral() {
        XCTAssertGreaterThan(ImageAdjustments(temperature: 0.5).temperatureShift, 0)
        XCTAssertLessThan(ImageAdjustments(temperature: -0.5).temperatureShift, 0)
    }

    func testTintIsSignedAroundNeutral() {
        XCTAssertEqual(ImageAdjustments.neutral.tintShift, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(ImageAdjustments(tint: 0.5).tintShift, 0)
        XCTAssertLessThan(ImageAdjustments(tint: -0.5).tintShift, 0)
    }

    func testTintSharesTheTemperatureScale() {
        // Both are white balance controls sitting next to each other, so the
        // same number typed into either has to mean the same size of shift.
        let value = 0.4
        XCTAssertEqual(
            ImageAdjustments(tint: value).tintShift,
            ImageAdjustments(temperature: value).temperatureShift,
            accuracy: 1e-12
        )
    }

    func testTintMovesGreenAgainstRedAndBlue() {
        // The point of the second axis: temperature trades red against blue and
        // barely moves green, tint moves green against both. Without that
        // difference the control would be a duplicate of white balance.
        //
        // Reproduces the shader's chroma maths on the BT.601 matrix it uses.
        func rgbDelta(cb: Double, cr: Double) -> (r: Double, g: Double, b: Double) {
            (r: 1.402 * cr, g: -0.344136 * cb - 0.714136 * cr, b: 1.772 * cb)
        }
        // Warm: Cb down, Cr up.
        let warmShift = ImageAdjustments(temperature: 0.5).temperatureShift
        let warm = rgbDelta(cb: -warmShift, cr: warmShift)
        XCTAssertGreaterThan(warm.r, 0)
        XCTAssertLessThan(warm.b, 0)
        XCTAssertLessThan(abs(warm.g), abs(warm.r) / 3)

        // Magenta: both components up together.
        let tintShift = ImageAdjustments(tint: 0.5).tintShift
        let magenta = rgbDelta(cb: tintShift, cr: tintShift)
        XCTAssertGreaterThan(magenta.r, 0)
        XCTAssertGreaterThan(magenta.b, 0)
        XCTAssertLessThan(magenta.g, 0)
        // Green is the axis this control exists to reach, so it has to move it
        // substantially rather than incidentally.
        XCTAssertGreaterThan(abs(magenta.g), abs(warm.g) * 2)
    }

    func testShadowAndHighlightTintsShareTheTemperatureScale() {
        // They are the same warm/cool axis restricted to one end of the
        // picture, so a given number has to mean the same shift wherever it is
        // typed.
        let value = 0.4
        XCTAssertEqual(
            ImageAdjustments(shadowWarmth: value).shadowShift,
            ImageAdjustments(temperature: value).temperatureShift,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            ImageAdjustments(highlightWarmth: value).highlightShift,
            ImageAdjustments(temperature: value).temperatureShift,
            accuracy: 1e-12
        )
    }

    // MARK: - Persistence

    func testAdjustmentsRoundTripThroughJSON() throws {
        let original = ImageAdjustments(
            exposure: 0.5,
            blackPoint: 0.2,
            whitePoint: -0.1,
            midtones: 0.3,
            contrast: -0.25,
            saturation: 0.75,
            temperature: -0.5,
            tint: 0.4,
            shadowWarmth: 0.35,
            highlightWarmth: -0.15
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ImageAdjustments.self, from: data), original)
    }

    func testASceneSavedBeforeTheNewControlsExistedStillLoads() throws {
        // Synthesised decoding throws on a missing key rather than falling back
        // to the property default, so without the hand-written initialiser
        // every added slider would wipe the user's saved scenes on first launch.
        let legacy = Data(
            #"{"exposure":0.5,"contrast":0.2,"saturation":0.1,"temperature":-0.3}"#.utf8
        )
        let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: legacy)
        XCTAssertEqual(decoded.exposure, 0.5, accuracy: 1e-12)
        XCTAssertEqual(decoded.contrast, 0.2, accuracy: 1e-12)
        XCTAssertEqual(decoded.saturation, 0.1, accuracy: 1e-12)
        XCTAssertEqual(decoded.temperature, -0.3, accuracy: 1e-12)
        // The controls that did not exist yet have to come back neutral.
        XCTAssertEqual(decoded.blackPoint, 0, accuracy: 1e-12)
        XCTAssertEqual(decoded.whitePoint, 0, accuracy: 1e-12)
        XCTAssertEqual(decoded.midtones, 0, accuracy: 1e-12)
        XCTAssertEqual(decoded.tint, 0, accuracy: 1e-12)
        XCTAssertEqual(decoded.shadowWarmth, 0, accuracy: 1e-12)
        XCTAssertEqual(decoded.highlightWarmth, 0, accuracy: 1e-12)
    }
}
