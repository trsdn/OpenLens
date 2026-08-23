import SwiftUI

/// A small `ⓘ` that reveals an explanation on demand.
///
/// Prose parked permanently under a control is noise: it is read once, then
/// becomes something to scroll past forever. Hiding it behind a button keeps the
/// panel scannable while the explanation stays one click away.
struct InfoButton: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About this setting")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
                .padding(12)
        }
    }
}

/// A `Form` section title with the section's explanation tucked behind a `ⓘ`.
///
/// The trailing summary is what makes collapsing a section safe: a shut section
/// still says what it holds ("Cam Link 4K", "3 adjusted"), so folding away the
/// settings you configure once does not hide the fact that they are set.
struct SectionHeader: View {
    let title: String
    let info: String
    var summary: String?
    /// Draws the summary in the accent colour, for sections holding a value
    /// that is no longer at its default.
    var summaryIsActive = false

    init(_ title: String, info: String, summary: String? = nil, summaryIsActive: Bool = false) {
        self.title = title
        self.info = info
        self.summary = summary
        self.summaryIsActive = summaryIsActive
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton(text: info)
            if let summary {
                Spacer(minLength: 8)
                Text(summary)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(summaryIsActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityLabel("\(title) summary: \(summary)")
            }
        }
    }
}
