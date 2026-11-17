import Observation
import SwiftUI
import BrimCore

/// The sound outputs for the picker (C1). Event-driven: CoreAudio says when devices come or go.
@Observable
public final class AudioOutputsStore {
    public private(set) var outputs: [AudioOutput] = []
    public private(set) var currentID: AudioOutput.ID?
    public var current: AudioOutput? { outputs.first { $0.id == currentID } }

    @ObservationIgnored private let service: any AudioOutputsService

    public init(service: any AudioOutputsService) {
        self.service = service
        service.onChange = { [weak self] in self?.refresh() }
    }

    public func start() {
        service.start()
        refresh()
    }

    public func refresh() {
        outputs = service.outputs()
        currentID = service.currentOutput()
    }

    public func select(_ id: AudioOutput.ID) {
        guard id != currentID, service.select(id) else { return }
        currentID = id
    }
}

/// The output list, iPhone-style: icon, name, a checkmark on the one playing. Picking one switches all
/// sound there (like Control Center), then the list closes a moment later so you see the check move.
struct OutputList: View {
    let store: AudioOutputsStore
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(store.outputs) { output in
                        row(output)
                    }
                }
            }
        }
    }

    private func row(_ output: AudioOutput) -> some View {
        let isCurrent = output.id == store.currentID
        return Button {
            store.select(output.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onDone() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: output.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24)
                Text(output.name)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isCurrent ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(output.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
