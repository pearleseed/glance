//
//  AppPickerSheet.swift
//  glance
//
//  Searchable installed-app picker sheet presented from `AppLockSettingsPage`.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppPickerSheet: View {
    @Bindable var installedApps: InstalledApps
    let lockedBundleIDs: Set<String>
    let onToggleApp: (LockedApp) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""
    @State private var pickerError: String?
    @State private var selectedCautionAppName: String?

    private var filteredApps: [InstalledApp] {
        installedApps.search(searchQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(SettingsMetrics.rowBorder)
            searchBar

            if let pickerError {
                banner(text: pickerError, isWarning: true)
            } else if let selectedCautionAppName {
                banner(
                    text:
                        "\(selectedCautionAppName) is a terminal/IDE — ensure you have another way to recover if camera auth fails.",
                    isWarning: false
                )
            }

            appList
            Divider().overlay(SettingsMetrics.rowBorder)
            footerBar
        }
        .frame(width: 440, height: 470)
        .background(SettingsMetrics.windowTintColor)
        .task {
            await installedApps.refresh()
        }
    }

    private var headerBar: some View {
        HStack {
            Text("Add Application")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SettingsMetrics.textPrimary)
            Spacer()
            SettingsPrimaryButton(title: "Done", compact: true) {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textTertiary)

            TextField("Search installed apps…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(SettingsMetrics.textPrimary)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SettingsMetrics.rowColor)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var appList: some View {
        if installedApps.isScanning && installedApps.apps.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning applications…")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredApps.isEmpty {
            VStack(spacing: 6) {
                Text("No matching applications")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsMetrics.textSecondary)
                Text("Try a different search or choose an app bundle manually.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredApps) { app in
                        let isLocked = lockedBundleIDs.contains(app.bundleIdentifier.lowercased())
                        Button {
                            pickerError = nil
                            selectedCautionAppName = (!isLocked && app.isCautionApp) ? app.name : nil
                            onToggleApp(app.toLockedApp())
                        } label: {
                            InstalledAppPickerRow(app: app, isLocked: isLocked)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Button {
                chooseOtherApplication()
            } label: {
                Text("Choose Other…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(SettingsMetrics.neutralButtonFill)
                    .overlay(
                        Capsule().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                    )
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(filteredApps.count) available")
                .font(.system(size: 11))
                .foregroundStyle(SettingsMetrics.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func banner(text: String, isWarning: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(isWarning ? SettingsMetrics.qualityPoorColor : SettingsMetrics.qualityFairColor)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(SettingsMetrics.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SettingsMetrics.rowColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func chooseOtherApplication() {
        pickerError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Lock App"
        panel.message = "Select an application bundle to protect with Glance."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let resolvedURL = url.resolvingSymlinksInPath()
        guard let bundle = Bundle(url: resolvedURL) ?? Bundle(url: url),
            let rawBundleID = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawBundleID.isEmpty
        else {
            pickerError = "Selected item does not have a valid bundle identifier."
            return
        }

        let name = LockedApp.displayName(for: bundle, url: url)
        guard LockedApp.canLock(bundleIdentifier: rawBundleID) else {
            pickerError = "\(name) cannot be locked because it is protected for macOS or Glance recovery."
            return
        }

        let entry = LockedApp(bundleIdentifier: rawBundleID, name: name, path: url.path)
        if !lockedBundleIDs.contains(rawBundleID.lowercased()) {
            selectedCautionAppName = entry.isCautionApp ? name : nil
            onToggleApp(entry)
        } else {
            selectedCautionAppName = nil
        }
    }
}

private struct InstalledAppPickerRow: View {
    let app: InstalledApp
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsMetrics.textPrimary)
                        .lineLimit(1)

                    if app.isCautionApp {
                        Text("Caution")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(SettingsMetrics.qualityFairColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(SettingsMetrics.qualityFairColor.opacity(0.16))
                            .clipShape(Capsule())
                    }
                }

                Text(app.bundleIdentifier)
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isLocked {
                Label("Locked", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GlanceTheme.accent)
            } else {
                Text("Add")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SettingsMetrics.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(SettingsMetrics.neutralButtonFill)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(SettingsMetrics.rowColor)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isLocked ? GlanceTheme.accent.opacity(0.55) : SettingsMetrics.rowBorder,
                    lineWidth: SettingsMetrics.rowBorderWidth
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
