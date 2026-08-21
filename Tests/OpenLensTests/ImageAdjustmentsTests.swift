import XCTest

final class ImageAdjustmentsTests: XCTestCase {
    // MARK: - Coefficients

    func testNeutralAdjustmentsAreIdentityInTheShader() {
        let neutral = ImageAdjustments.neutral
        XCTAssertTrue(neutral.isNeutral)
        // These four values are multiplied into every pixel, so anything other
        // than an exact identity here tints or dims the whole picture before a
        // slider has been touched.
        XCTAssertEqual(neutral.exposureGain, 1, accuracy: 1e-12)
        XCTAssertEqual(neutral.contrastGain, 1, accuracy: 1e-12)
        XCTAssertEqual(neutral.saturationGain, 1, accuracy: 1e-12)
        XCTAssertEqual(neutral.temperatureShift, 0, accuracy: 1e-12)
    }

    func testExposureIsMeasuredInStops() {
        XCTAssertEqual(ImageAdjustments(exposure: 1).exposureGain, 2, accuracy: 1e-9)
        XCTAssertEqual(ImageAdjustments(exposure: -1).exposureGain, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ImageAdjustments(exposure: 2).exposureGain, 4, accuracy: 1e-9)
    }

    func testExtremesStayWithinUsableShaderRanges() {
        // Saturation must reach exactly zero for monochrome and must not go
        // negative, which would invert every hue.
        XCTAssertEqual(ImageAdjustments(saturation: -1).saturationGain, 0, accuracy: 1e-12)
        XCTAssertEqual(ImageAdjustments(saturation: 1).saturationGain, 2, accuracy: 1e-12)
        // Contrast stays a positive slope at both ends.
        XCTAssertEqual(ImageAdjustments(contrast: -1).contrastGain, 0.5, accuracy: 1e-12)
        XCTAssertEqual(ImageAdjustments(contrast: 1).contrastGain, 1.5, accuracy: 1e-12)
        // Chroma only spans +/-0.5 in total, so the shift has to stay well inside it.
        XCTAssertLessThan(abs(ImageAdjustments(temperature: 1).temperatureShift), 0.1)
    }

    func testTemperatureIsSignedAroundNeutral() {
        XCTAssertGreaterThan(ImageAdjustments(temperature: 0.5).temperatureShift, 0)
        XCTAssertLessThan(ImageAdjustments(temperature: -0.5).temperatureShift, 0)
    }

    // MARK: - Persistence

    func testAdjustmentsRoundTripThroughJSON() throws {
        let original = ImageAdjustments(
            exposure: 0.5, contrast: -0.25, saturation: 0.75, temperature: -0.5
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ImageAdjustments.self, from: data), original)
    }
}
