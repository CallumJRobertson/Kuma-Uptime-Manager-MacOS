//
//  UptimeKuma_MacApp.swift
//  UptimeKuma Mac
//
//  Created by Callum Robertson on 09/03/2026.
//

import SwiftUI

@main
struct UptimeKuma_MacApp: App {
    @StateObject private var store = UptimeKumaStatusStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            MenuBarStatusLabel(
                text: store.menuLabel,
                iconName: store.menuSymbolName,
                showDownDot: store.menuShowsDownDot
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
                .frame(width: 420)
        }
    }
}

private struct MenuBarStatusLabel: View {
    let text: String
    let iconName: String
    let showDownDot: Bool

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: iconName)
                if showDownDot {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -3)
                }
            }
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
        }
    }
}
