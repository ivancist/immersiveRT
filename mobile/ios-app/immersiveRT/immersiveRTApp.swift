//
//  immersiveRTApp.swift
//  immersiveRT
//
//  Created by Ivan Cisternino on 11/07/2026.
//

import SwiftUI

@main
struct immersiveRTApp: App {
    // Owned here (not inside ContentView) so scenePhase transitions can
    // reach it directly — PHONE-07/Pitfall 4 requires isIdleTimerDisabled
    // to be reset on backgrounding and CoreMotion/heartbeat to pause/resume,
    // which needs the SAME SessionViewModel instance ContentView renders,
    // not a second one. ContentView's `sessionViewModel` init parameter
    // defaults to constructing its own when unset (e.g. #Preview), so this
    // is additive, not a breaking change to ContentView's public surface.
    @StateObject private var sessionViewModel = SessionViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(sessionViewModel: sessionViewModel)
        }
        .onChange(of: scenePhase) { _, newPhase in
            sessionViewModel.handleScenePhaseChange(newPhase)
        }
    }
}
