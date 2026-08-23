import Foundation

/// Turning what someone typed into an adjustment value.
///
/// This lives apart from the slider because the rule that matters is a rule
/// about *when*, not about drawing: the text has to be read once, at the end
/// of the edit. Parsing every keystroke cannot work — on the way to 56 the
/// field holds 5, which is itself a legal value, so it was clamped and written
/// back under the cursor and the remaining digits landed on the clamped number.
public enum NumberFieldValue {
    /// Accepts either decimal separator, so a number typed on a German
    /// keyboard is not silently discarded.
    ///
    /// Returns `nil` rather than zero for anything unparseable: a field that
    /// is empty or half-typed must leave the control where it was, otherwise
    /// tabbing away from a cleared field would neutralise it.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    /// Clamps once, at the end. Out-of-range numbers are pinned to the nearest
    /// end rather than rejected, which is what dragging the slider does.
    public static func clamp(
        _ typed: Double,
        displayScale: Double,
        range: ClosedRange<Double>
    ) -> Double {
        min(max(typed / displayScale, range.lowerBound), range.upperBound)
    }
}
