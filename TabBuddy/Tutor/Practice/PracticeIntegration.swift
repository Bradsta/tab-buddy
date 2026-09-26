//
//  PracticeIntegration.swift
//  TabBuddy
//
//  Glue between the existing viewer and library practice mode
//  (TUTOR_IMPLEMENTATION.md §8). The viewer publishes a `PracticeToolState`
//  through the environment; both transports (`TabTransportBar`,
//  `OriginalTransportBar`) render `PracticeToolButton` in their tools zone, so
//  no renderer in between needs to know about practice.
//

import Combine
import SwiftUI

// MARK: - Transport tool

/// Whether the open score can be practiced with listening, and how to start.
struct PracticeToolState {
    enum Status: Equatable {
        case available
        /// Short, honest reason shown when the tile is tapped.
        case unavailable(String)
    }

    /// Evaluated when the tile renders, so it follows engine readiness.
    var resolveStatus: @MainActor () -> Status
    var open: @MainActor () -> Void

    @MainActor var status: Status { resolveStatus() }
}

private struct PracticeToolKey: EnvironmentKey {
    static let defaultValue: PracticeToolState? = nil
}

extension EnvironmentValues {
    /// Set by `TabViewerView`; nil hides the Practice tile (e.g. Tab Maker).
    var practiceTool: PracticeToolState? {
        get { self[PracticeToolKey.self] }
        set { self[PracticeToolKey.self] = newValue }
    }
}

/// The Practice tile (`waveform.and.mic`) for the transport tools zone.
/// Unavailable scores keep the tile visible (dimmed) so the reason is one tap away.
struct PracticeToolButton: View {
    @Environment(\.practiceTool) private var tool
    /// Re-renders when a Guitar Pro player registers or becomes ready, since
    /// `tool.status` reads the registry rather than observed state.
    @ObservedObject private var readiness = PracticeSourceRegistry.readiness
    @State private var showReason = false

    var body: some View {
        if let tool {
            let status = tool.status
            Button {
                if tool.status == .available { tool.open() } else { showReason = true }
            } label: {
                TransportTileLabel(icon: "waveform.and.mic", label: "Practice", active: false)
                    .opacity(status == .available ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Practice with listening")
            .accessibilityHint(status == .available
                               ? "Listens through the microphone and grades your playing"
                               : "Unavailable for this score. Shows why")
            .popover(isPresented: $showReason) {
                PracticeUnavailableCard(reason: reason(tool.status))
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func reason(_ status: PracticeToolState.Status) -> String {
        if case .unavailable(let why) = status { return why }
        return ""
    }
}

struct PracticeUnavailableCard: View {
    var reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Practice isn't available", systemImage: "waveform.and.mic")
                .font(.headline)
                .foregroundStyle(DS.fg1)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(DS.fg2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(idealWidth: 320, maxWidth: 360, alignment: .leading)
    }
}

// MARK: - Guitar Pro players

/// Lets practice mode reach the open Guitar Pro player (note export, loop,
/// speed) without threading it through the viewer hierarchy.
@MainActor
enum PracticeSourceRegistry {
    private final class WeakPlayer {
        weak var player: GuitarProPlayer?
        init(_ player: GuitarProPlayer) { self.player = player }
    }
    private static var players: [UUID: WeakPlayer] = [:]
    private static var readySubscriptions: [UUID: AnyCancellable] = [:]

    /// Changes whenever a registered player's readiness changes.
    static let readiness = PracticeSourceReadiness()

    static func register(_ player: GuitarProPlayer, for fileID: UUID) {
        players = players.filter { $0.value.player != nil }
        readySubscriptions = readySubscriptions.filter { players[$0.key] != nil }
        players[fileID] = WeakPlayer(player)
        readySubscriptions[fileID] = player.$ready
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { readiness.revision += 1 } }
        readiness.revision += 1
    }

    static func guitarPro(for fileID: UUID) -> GuitarProPlayer? {
        players[fileID]?.player
    }
}

/// Observable readiness of practice sources that live outside SwiftUI state.
@MainActor
final class PracticeSourceReadiness: ObservableObject {
    @Published var revision = 0
}

// MARK: - Latency storage

@MainActor
enum PracticeLatency {
    /// Calibrated latency is the tutor's unified store, shared with lessons.
    static func store(_ tutor: TutorStore? = nil) -> LatencyStore {
        TutorLatency.store(tutor)
    }
}
