import XCTest

/// The number beside each slider used to be parsed on every keystroke, which
/// meant a value could not be typed at all: on the way to 56 the field held 5,
/// clamped it, and rewrote itself under the cursor, so the remaining digits
/// landed on the clamped number and 42 became 100.
final class NumberFieldValueTests: XCTestCase {
    private let displayScale: Double = 100
    private let range: ClosedRange<Double> = -1...1

    // MARK: - Parsing

    func testParsesPlainNumber() {
        XCTAssertEqual(NumberFieldValue.parse("56"), 56)
    }

    func testParsesCommaAsDecimalSeparator() {
        XCTAssertEqual(NumberFieldValue.parse("1,4"), 1.4)
    }

    func testParsesPointAsDecimalSeparator() {
        XCTAssertEqual(NumberFieldValue.parse("1.4"), 1.4)
    }

    func testParsesNegativeNumber() {
        XCTAssertEqual(NumberFieldValue.parse("-28"), -28)
    }

    func testIgnoresSurroundingWhitespace() {
        XCTAssertEqual(NumberFieldValue.parse("  12  "), 12)
    }

    /// An empty or half-typed field must not be read as zero, or tabbing away
    /// from a field you cleared would silently neutralise the control.
    func testRejectsEmptyText() {
        XCTAssertNil(NumberFieldValue.parse(""))
        XCTAssertNil(NumberFieldValue.parse("   "))
    }

    func testRejectsNonNumericText() {
        XCTAssertNil(NumberFieldValue.parse("abc"))
        XCTAssertNil(NumberFieldValue.parse("-"))
    }

    // MARK: - Clamping

    func testClampConvertsFromDisplayScale() {
        XCTAssertEqual(NumberFieldValue.clamp(56, displayScale: displayScale, range: range), 0.56, accuracy: 1e-9)
    }

    func testClampPinsAboveRangeToUpperBound() {
        XCTAssertEqual(NumberFieldValue.clamp(4256, displayScale: displayScale, range: range), 1)
    }

    func testClampPinsBelowRangeToLowerBound() {
        XCTAssertEqual(NumberFieldValue.clamp(-500, displayScale: displayScale, range: range), -1)
    }

    /// The regression itself: every prefix of a typed number is now free to be
    /// out of range, because only the finished text is clamped.
    func testIntermediateDigitsSurviveUntilTheEnd() {
        let typed = "56"
        let prefixes = (1...typed.count).map { String(typed.prefix($0)) }
        let parsed = prefixes.compactMap(NumberFieldValue.parse)

        XCTAssertEqual(parsed, [5, 56])
        XCTAssertEqual(
            NumberFieldValue.clamp(parsed.last!, displayScale: displayScale, range: range),
            0.56,
            accuracy: 1e-9
        )
    }
}
