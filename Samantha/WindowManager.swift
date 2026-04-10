//
//  WindowManager.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/10.
//

import AppKit
import SwiftUI

/// Manages the Command Center window as a standalone NSWindow.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var window: NSWindow?

    func openCommandCenter(proactiveService: ProactiveService, cognitiveLoadService: CognitiveLoadService) {
        // If already open, bring to front
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = CommandCenterView()
            .environment(proactiveService)
            .environment(cognitiveLoadService)

        let hostingView = NSHostingView(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 950),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Samantha — Command Center"
        w.contentView = hostingView
        w.center()
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 1200, height: 750)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = w
    }
}
