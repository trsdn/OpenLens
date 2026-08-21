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
struct SectionHeader: View {
    let title: String
    let info: String

    init(_ title: String, info: String) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            InfoButton(text: info)
        }
    }
}
