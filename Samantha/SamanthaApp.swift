//
//  SamanthaApp.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import SwiftUI

@main
struct SamanthaApp: App {
    var body: some Scene {
        MenuBarExtra("Samantha", systemImage: "sparkles") {
            ContentView()
                .frame(width: 300, height: 400)
        }
        .menuBarExtraStyle(.window)
    }
}
