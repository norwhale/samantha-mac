//
//  SamanthaApp.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import SwiftUI
import UserNotifications

@main
struct SamanthaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var proactiveService = ProactiveService()

    var body: some Scene {
        MenuBarExtra("Samantha", systemImage: "sparkles") {
            ContentView()
                .environment(proactiveService)
                .frame(width: 300, height: 400)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Delegate (notifications + lifecycle)

class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            print("[App] Notification permission: \(granted), error: \(String(describing: error))")
        }
        UNUserNotificationCenter.current().delegate = self

        // Cleanup old activity logs
        Task { await ActivityLogger.cleanup() }
    }

    // Show notification even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        print("[App] Notification tapped")
        // App activates; user opens MenuBarExtra to see the suggestion banner
    }
}
