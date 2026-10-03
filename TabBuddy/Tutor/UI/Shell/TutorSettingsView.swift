//
//  TutorSettingsView.swift
//  TabBuddy
//
//  Tutor settings: instrument, gentle daily goal, and resetting tutor
//  progress for one instrument (library data is never touched).
//

import SwiftUI

struct TutorSettingsView: View {
    @EnvironmentObject private var state: TutorShellState
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Picker("Instrument", selection: Binding(get: { state.instrument }, set: { state.setInstrument($0) })) {
                    ForEach(TutorInstrument.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("Each instrument has its own book and reading progress.")
            }

            Section {
                Stepper(value: Binding(get: { state.dailyGoalMinutes }, set: { state.setDailyGoal($0) }),
                        in: 5...60, step: 5) {
                    HStack {
                        Text("Daily goal")
                        Spacer()
                        Text("\(state.dailyGoalMinutes) min").foregroundStyle(DS.fg2).monospacedDigit()
                    }
                }
                LabeledContent("Reading days", value: "\(state.practiceDays)")
            } footer: {
                Text("Minutes count from chapters you mark as read. The goal is a guide, not a streak. Missing a day loses nothing.")
            }

            Section {
                Button("Reset \(state.instrument.displayName) progress…", role: .destructive) {
                    confirmReset = true
                }
            } footer: {
                Text("Clears which chapters are marked read (and game bests) for \(state.instrument.displayName). Your library, practice takes, and calibration stay.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.paper)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(DS.paper)
        .confirmationDialog("Reset \(state.instrument.displayName) progress?", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Reset progress", role: .destructive) { state.resetProgress(for: state.instrument) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Read marks and game bests for \(state.instrument.displayName) will be removed. This cannot be undone.")
        }
    }
}
