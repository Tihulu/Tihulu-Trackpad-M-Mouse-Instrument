#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct DropFileView: View {
    let title: String
    let subtitle: String
    let onURL: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 34, weight: .medium))
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .padding(24)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [7])))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = item as? URL { url = value }
                else { url = nil }
                if let url { DispatchQueue.main.async { onURL(url) } }
            }
            return true
        }
    }
}
#endif
