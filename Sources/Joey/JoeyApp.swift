import AppKit
import Foundation
import LeafiyUI
import LeafiyUICore
import SwiftUI

@main
struct JoeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        LeafiyLocalization.language = SettingsStore().load().selectedAppLanguage
        if CommandLine.arguments.contains("--leafiy-doctor") {
            print(LeafiyDiagnostics.doctorReport(
                store: LeafiySettingsStore<AppSettings>.standard(directoryName: "Joey"),
                probes: Self.localizationProbes
            ))
            Foundation.exit(0)
        }
        LeafiyDiagnostics.writeLaunchReport(
            store: LeafiySettingsStore<AppSettings>.standard(directoryName: "Joey"),
            probes: Self.localizationProbes
        )
    }

    private static var localizationProbes: [LeafiyDiagnostics.LocalizationProbe] {
        [
            (label: "app",
             bundle: LeafiyLocalization.moduleBundle(package: "joey", target: "Joey"),
             key: "Refresh"),
            (label: "leafiy-ui",
             bundle: LeafiyLocalization.moduleBundle(package: "LeafiyUI", target: "LeafiyUI"),
             key: "About"),
        ]
    }

    var body: some Scene {
        // Panel-style menu-bar app (joey ADR-0002): the `.window` scene is the
        // primary surface; the family Menu Tail lives in the panel's Gear Menu.
        LeafiyMenuBarExtra(style: .window) {
            PanelRootView(model: appDelegate.model)
                .id(appDelegate.model.language.rawValue)
        } label: {
            JoeyMenuBarLabel(transfers: appDelegate.model.transfers)
                .id(appDelegate.model.language.rawValue)
        }

        Settings {
            JoeySettingsView(model: appDelegate.model)
                .id(appDelegate.model.language.rawValue)
        }
    }
}

struct JoeyMenuBarLabel: View {
    @ObservedObject var transfers: TransferManager

    var body: some View {
        LeafiyMenuBarLabel(status: status)
    }

    private var status: LeafiyMenuBarStatus {
        switch transfers.dotState {
        case .idle: return .idle
        case .busy: return .busy
        case .success: return .success
        case .error: return .failure
        }
    }
}

@MainActor
final class AppDelegate: LeafiyAppDelegate {
    let model = JoeyModel()
    private var dropTarget: LeafiyMenuBarDropTarget?

    override func leafiyApplicationDidFinishLaunching(_ notification: Notification) {
        let settings = model.settings
        LeafiyLocalization.language = settings.selectedAppLanguage
        LeafiyLaunchAtLogin.setEnabled(settings.launchAtLogin)
        LeafiyApplicationPresentation.shared.apply(settings.applicationIconMode)
        model.activateBrowser()

        // Icon Drop wiring (ticket 08): hover decides the surface, release on
        // the icon itself falls through to `iconDrop`.
        let dropTarget = LeafiyMenuBarDropTarget(
            onDrop: { [weak self] urls in
                self?.model.iconDrop(urls)
            },
            onDragChanged: { [weak self] inside in
                self?.model.iconDragChanged(inside)
            }
        )
        dropTarget.activate()
        self.dropTarget = dropTarget
    }

    override func leafiyApplicationWillTerminate(_ notification: Notification) {
        dropTarget?.deactivate()
        model.favoriteTray.hide()
    }
}
