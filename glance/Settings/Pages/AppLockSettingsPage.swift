//
//  AppLockSettingsPage.swift
//  glance
//
//  Settings tab for App Lock v2: SystemAuthentication-protected toggle, default and per-app
//  RelockPolicy selection, searchable app picker + NSOpenPanel, and recovery caution notices.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppLockSettingsPage: View {
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared
    @Bindable private var installedApps = InstalledApps.shared
    @Bindable private var enrollmentStore = FaceEnrollmentStore.shared

    @State private var isEditingAuthorized = false
    @State private var isAuthenticating = false
    @State private var authError: String?
    @State private var showingAppPicker = false

    private var hasCautionAppSelected: Bool {
        settings.lockedApps.contains(where: \.isCautionApp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(
                    title: "Enable App Lock",
                    subtitle: "Cover selected apps until you authenticate with your face or Touch ID.",
                    subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                ) {
                    GlanceToggle(isOn: Binding(
                        get: { settings.isAppLockEnabled },
                        set: { newValue in
                            authorizeChange {
                                settings.isAppLockEnabled = newValue
                            }
                        }
                    ))
                }

                SettingsGroupDivider()

                SettingsRowContent(
                    title: "Default relock",
                    subtitle: "When unlocked apps require authentication again.",
                    subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                ) {
                    SettingsMenuPickerPill(label: settings.defaultAppRelockPolicy.title) {
                        ForEach(RelockPolicy.selectablePresets) { policy in
                            Button(policy.title) {
                                authorizeChange {
                                    settings.defaultAppRelockPolicy = policy
                                }
                            }
                        }
                    }
                }
            }

            if let authError {
                SettingsCaption(text: authError)
            } else if !isEditingAuthorized {
                SettingsCaption(text: "Changing App Lock settings or modifying the protected list requires Touch ID or your Mac password.")
            }

            if !pocController.isSessionUnlocked {
                SettingsCaption(text: "Glance session is locked — face scanning for apps is paused until you unlock your session on Face or Password. Touch ID / Password fallback still works.")
            } else if enrollmentStore.activeIdentities.isEmpty {
                SettingsCaption(text: "No active enrolled face — locked apps will fall back to Touch ID / Password until a face is enabled.")
            }

            lockedAppsHeader
                .padding(.bottom, -6)

            if settings.lockedApps.isEmpty {
                SettingsGroup {
                    SettingsRowContent(
                        title: "No locked apps",
                        subtitle: "Add applications you want to guard behind Glance."
                    ) {
                        SettingsPrimaryButton(title: "Add App…", compact: true) {
                            authorizeChange {
                                showingAppPicker = true
                            }
                        }
                    }
                }
            } else {
                SettingsGroup {
                    ForEach(Array(settings.lockedApps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 {
                            SettingsGroupDivider()
                        }
                        LockedAppRow(
                            app: app,
                            defaultPolicy: settings.defaultAppRelockPolicy,
                            onSelectPolicy: { policy in
                                authorizeChange {
                                    setPolicyOverride(policy, for: app.bundleIdentifier)
                                }
                            },
                            onRemove: {
                                authorizeChange {
                                    removeApp(bundleIdentifier: app.bundleIdentifier)
                                }
                            }
                        )
                    }
                }
            }

            if hasCautionAppSelected {
                cautionNoticeBanner
            }

            transparencyNotice
        }
        .onAppear {
            pocController.refreshCredentialStatus()
            enrollmentStore.reloadIfUnlocked()
        }
        .onDisappear {
            isEditingAuthorized = false
            authError = nil
        }
        .onChange(of: pocController.isSessionUnlocked) { _, unlocked in
            if !unlocked {
                isEditingAuthorized = false
            }
        }
        .sheet(isPresented: $showingAppPicker) {
            AppPickerSheet(
                installedApps: installedApps,
                lockedBundleIDs: Set(settings.lockedApps.map { $0.bundleIdentifier.lowercased() }),
                onToggleApp: { candidate in
                    authorizeChange {
                        toggleLockedApp(candidate)
                    }
                }
            )
        }
    }

    private var lockedAppsHeader: some View {
        HStack(spacing: 0) {
            SettingsSectionTitle(text: "Locked Apps")

            Button {
                authorizeChange {
                    showingAppPicker = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add application")
            .padding(.trailing, SettingsMetrics.sectionTitleHorizontalInset)
            .padding(.top, SettingsMetrics.sectionTitleVerticalPadding)
        }
    }

    private var cautionNoticeBanner: some View {
        SettingsGroup {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsMetrics.qualityFairColor)
                    .padding(.top, 1)

                Text("You have a third-party terminal or IDE locked. If authentication fails or camera access is unavailable, Apple Terminal, Activity Monitor, Finder, and System Settings remain excluded for recovery.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
            .padding(.vertical, 10)
        }
    }

    private var transparencyNotice: some View {
        SettingsCaption(
            text: "App Lock is a privacy shield while Glance is running — quitting Glance or disabling App Lock after authenticating removes all curtains. Glance, Finder, System Settings, Terminal, and Activity Monitor cannot be locked."
        )
        .padding(.top, 2)
    }

    // MARK: - Authorization & Mutations

    private func authorizeChange(_ mutation: @escaping () -> Void) {
        if isEditingAuthorized {
            mutation()
            return
        }
        guard !isAuthenticating else { return }
        isAuthenticating = true
        authError = nil

        Task {
            let outcome = await SystemAuthentication.authenticate(
                reason: "Authenticate to modify App Lock settings"
            )
            isAuthenticating = false
            switch outcome {
            case .authenticated:
                isEditingAuthorized = true
                mutation()
            case .cancelled:
                break
            case .failed(let message):
                authError = message
            }
        }
    }

    private func toggleLockedApp(_ app: LockedApp) {
        guard LockedApp.canLock(bundleIdentifier: app.bundleIdentifier) else { return }
        let lowerID = app.bundleIdentifier.lowercased()
        if settings.lockedApps.contains(where: { $0.bundleIdentifier.lowercased() == lowerID }) {
            settings.lockedApps.removeAll { $0.bundleIdentifier.lowercased() == lowerID }
        } else {
            settings.lockedApps.append(app)
            settings.lockedApps.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    private func removeApp(bundleIdentifier: String) {
        let lowerID = bundleIdentifier.lowercased()
        settings.lockedApps.removeAll { $0.bundleIdentifier.lowercased() == lowerID }
    }

    private func setPolicyOverride(_ policy: RelockPolicy?, for bundleIdentifier: String) {
        let lowerID = bundleIdentifier.lowercased()
        guard let index = settings.lockedApps.firstIndex(where: { $0.bundleIdentifier.lowercased() == lowerID }) else {
            return
        }
        settings.lockedApps[index].relockPolicyOverride = policy
    }
}

// MARK: - Locked App Row

private struct LockedAppRow: View {
    let app: LockedApp
    let defaultPolicy: RelockPolicy
    let onSelectPolicy: (RelockPolicy?) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.resolvedIcon())
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(SettingsMetrics.rowFont)
                        .foregroundStyle(SettingsMetrics.textPrimary)
                        .lineLimit(1)

                    if app.isCautionApp {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsMetrics.qualityFairColor)
                            .help("Third-party terminal or IDE")
                    }
                }

                Text(app.bundleIdentifier)
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            SettingsMenuPickerPill(
                label: app.relockPolicyOverride?.shortTitle ?? "Default (\(defaultPolicy.shortTitle))"
            ) {
                Button("Default (\(defaultPolicy.title))") {
                    onSelectPolicy(nil)
                }
                Divider()
                ForEach(RelockPolicy.selectablePresets) { policy in
                    Button(policy.title) {
                        onSelectPolicy(policy)
                    }
                }
            }

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(SettingsMetrics.neutralButtonFill)
                    .overlay(
                        Circle().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove \(app.name)")
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, 8)
    }
}

// MARK: - Searchable App Picker Sheet

private struct AppPickerSheet: View {
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
                    text: "\(selectedCautionAppName) is a terminal/IDE — ensure you have another way to recover if camera auth fails.",
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
                .aspectRatio(contentMode: .fit)
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

private extension RelockPolicy {
    static let selectablePresets: [RelockPolicy] = [
        .everyTime,
        .afterFocusLossMinutes(1),
        .afterFocusLossMinutes(5),
        .afterFocusLossMinutes(15),
        .afterMinutes(1),
        .afterMinutes(5),
        .afterMinutes(15),
        .afterMinutes(60),
    ]
}
