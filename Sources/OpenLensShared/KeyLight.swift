import Foundation

/// The state of one Elgato Key Light: whether it is on, how bright, and what
/// colour temperature.
///
/// A value type with no networking in it, so the arithmetic that is easy to get
/// wrong — the colour temperature in particular — can be tested on its own.
public struct KeyLightState: Codable, Equatable, Sendable {
    public var isOn: Bool
    /// Percent, as the device reports it.
    public var brightness: Int
    /// **Mired, not kelvin.** The device speaks mired and only mired; see
    /// `kelvin` for the conversion and why the ends look swapped.
    public var mired: Int

    public init(isOn: Bool = true, brightness: Int = 20, mired: Int = 213) {
        self.isOn = isOn
        self.brightness = Self.clampBrightness(brightness)
        self.mired = Self.clampMired(mired)
    }

    // MARK: - Ranges

    public static let brightnessRange = 0...100

    /// What the hardware accepts. 143 mired is 6993 K and 344 is 2907 K, which
    /// is the 7000 K–2900 K the product is sold as.
    public static let miredRange = 143...344

    /// The same range expressed the way a person thinks about it. Reversed,
    /// because mired is reciprocal: the *low* mired end is the *high* kelvin
    /// one.
    public static var kelvinRange: ClosedRange<Int> {
        kelvin(fromMired: miredRange.upperBound)...kelvin(fromMired: miredRange.lowerBound)
    }

    // MARK: - Colour temperature
    //
    // Mired is a million divided by kelvin. It exists because equal steps in
    // mired are roughly equal steps in visible colour, which kelvin is not:
    // 2900 K to 3100 K is an obvious change, 6800 K to 7000 K is barely
    // visible. The lamp is designed around that, and the API exposes it raw.
    //
    // Two consequences worth stating, because both have already caused a wrong
    // reading of these lamps: the numbers run *backwards* against kelvin, and
    // the conversion is not linear, so a midpoint in one unit is not the
    // midpoint in the other.

    public static func kelvin(fromMired mired: Int) -> Int {
        guard mired > 0 else { return kelvinRange.upperBound }
        return Int((1_000_000.0 / Double(mired)).rounded())
    }

    public static func mired(fromKelvin kelvin: Int) -> Int {
        guard kelvin > 0 else { return miredRange.upperBound }
        return clampMired(Int((1_000_000.0 / Double(kelvin)).rounded()))
    }

    /// Colour temperature in kelvin, rounded to the nearest value the lamp can
    /// actually hold.
    ///
    /// Setting this and reading it back will usually not return the same
    /// number, because many kelvin values share one mired step. That is the
    /// hardware's resolution showing through rather than a rounding bug, so
    /// callers should not treat a mismatch as a failed write.
    public var kelvin: Int {
        get { Self.kelvin(fromMired: mired) }
        set { mired = Self.mired(fromKelvin: newValue) }
    }

    // MARK: - Clamping

    public static func clampBrightness(_ value: Int) -> Int {
        min(brightnessRange.upperBound, max(brightnessRange.lowerBound, value))
    }

    public static func clampMired(_ value: Int) -> Int {
        min(miredRange.upperBound, max(miredRange.lowerBound, value))
    }
}

/// A light the app knows about, whether or not it can currently be reached.
///
/// Identified by serial number rather than by address, because the lamps take
/// their address from DHCP: keying on the address turns one lamp that moved
/// into two lamps, one of which never answers.
public struct KeyLightDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String { serialNumber }
    public var serialNumber: String
    /// The name set in the Elgato app, e.g. "Studio links".
    public var displayName: String
    public var productName: String
    /// Last address it answered on. A hint for the next launch, not an identity.
    public var host: String
    public var port: Int
    /// True when the user typed the address in rather than Bonjour finding it,
    /// in which case it must survive not being discovered.
    public var isManual: Bool

    public init(
        serialNumber: String,
        displayName: String,
        productName: String = "Elgato Key Light",
        host: String,
        port: Int = KeyLightDevice.defaultPort,
        isManual: Bool = false
    ) {
        self.serialNumber = serialNumber
        self.displayName = displayName
        self.productName = productName
        self.host = host
        self.port = port
        self.isManual = isManual
    }

    public static let defaultPort = 9123
    public static let bonjourServiceType = "_elg._tcp"
}
