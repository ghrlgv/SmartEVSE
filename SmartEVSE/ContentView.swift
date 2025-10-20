//
//  ContentView.swift
//  SmartEVSEapp
//
//  Created by Ruud Verheul on 17/10/2025.
//

import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var service = SmartEVSEService()
    @AppStorage("evse_ip") private var ipAddress: String = "192.168.1.100"
    @AppStorage("evse_on_mode") private var storedOnMode: Int = EVSEMode.normal.rawValue
    @State private var selectedMode: EVSEMode = .normal
    @State private var isOn: Bool = false
    @State private var overrideCurrent: Double = 16
    @State private var startTime: Date = Date()
    @State private var isBusy: Bool = false
    @State private var showingSettings: Bool = false
    @State private var isCableLocked: Bool = false
    @State private var showingRebootConfirm: Bool = false
    
    // 10s live refresh timer (foreground)
    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Button {
                    Task { await refreshNow() }
                } label: {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(service.statusColor)
                        .frame(height: 60)
                        .padding()
                        .overlay(
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise")
                                Text("Charger Status").bold()
                            }
                            .foregroundColor(.white)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh Charger Status")
                
                Form {
                    Section(header: Text("Charger")) {
                        
                        Toggle(isOn: Binding(
                            get: { isOn },
                            set: { newValue in
                                Task { await toggleEVSE(newValue) }
                            }
                        )) {
                            HStack(spacing: 8) {
                                Text("Power")
                                if service.currentMode == .pause {
                                    Text("Paused")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                            .disabled(isBusy || ipAddress.isEmpty)
                        
                        Picker("ON Mode", selection: $selectedMode) {
                            ForEach([EVSEMode.normal, EVSEMode.smart, EVSEMode.solar, EVSEMode.pause]) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    }
                    
                    if selectedMode == .normal || selectedMode == .smart {
                        Section(header: Text("Override Current")) {
                            Slider(value: $overrideCurrent, in: 6...32, step: 1)
                            Text("\(Int(overrideCurrent)) A")
                            Button("Apply Current Override") {
                                Task { await applyOverride() }
                            }
                            .disabled(isBusy)
                        }
                    }
                    
                    Section(header: Text("Schedule Start")) {
                        DatePicker("Start Time", selection: $startTime, displayedComponents: [.hourAndMinute, .date])
                        Button("Schedule Start") {
                            Task { await scheduleStart() }
                        }
                        .disabled(isBusy)
                    }
                    
                    if !service.lastMessage.isEmpty {
                        Section(header: Text("Log")) {
                            Text(service.lastMessage)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // History list
                    Section(header: Text("History (mode/color)")) {
                        NavigationLink("View All History") {
                            FullHistoryView(history: service.history, onClear: {
                                service.clearHistory()
                            }, onExport: {
                                service.exportHistory()
                            }, onImport: { data in
                                service.importHistory(from: data)
                            })
                        }
                        List(service.history) { item in
                            HStack {
                                Circle().fill(Color(hex: item.hex)).frame(width: 14, height: 14)
                                if item.mode == .off, let kwh = item.chargedKWh {
                                    Text("Off · \(String(format: "%.2f", kwh)) kWh")
                                } else {
                                    Text(item.mode.displayName)
                                }
                                Spacer()
                                Text(item.date, style: .time).foregroundColor(.secondary)
                            }
                        }
                        .frame(maxHeight: 300)
                        HStack {
                            Button(role: .destructive) {
                                service.clearHistory()
                            } label: {
                                Label("Clear History", systemImage: "trash")
                            }
                            Spacer()
                            Button {
                                service.exportHistory()
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            Button {
                                service.importHistory(from: nil)
                            } label: {
                                Label("Import", systemImage: "square.and.arrow.down")
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .onAppear {
                selectedMode = EVSEMode(rawValue: storedOnMode) ?? .normal
                Task { await refreshNow() }
            }
            .onChange(of: selectedMode, initial: false) { oldValue, newValue in
                storedOnMode = newValue.rawValue
                // If the charger is already ON, immediately apply the new mode
                if isOn && !ipAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task {
                        await service.setMode(ip: ipAddress, mode: newValue)
                        await refreshNow()
                    }
                }
            }
            .onReceive(refreshTimer) { _ in
                Task { await refreshNow() }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationView {
                    Form {
                        Section(header: Text("Connection")) {
                            TextField("IP address", text: $ipAddress)
                                .keyboardType(.numbersAndPunctuation)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                        }
                        Section(header: Text("Cable"), footer: Text("Lock prevents unplugging the cable from the EVSE.")) {
                            Toggle(isOn: Binding(get: { isCableLocked }, set: { newValue in
                                Task { await setCableLocked(newValue) }
                            })) {
                                Label("Lock Cable", systemImage: isCableLocked ? "lock.fill" : "lock.open" )
                            }
                            .disabled(isBusy || ipAddress.isEmpty)
                        }
                        Section(header: Text("Maintenance"), footer: Text("Reboots the SmartEVSE controller.")) {
                            Button(role: .destructive) {
                                showingRebootConfirm = true
                            } label: {
                                Label("Reboot Charger", systemImage: "arrow.counterclockwise.circle")
                            }
                        }
                    }
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") { showingSettings = false } }
                    }
                    .confirmationDialog("Reboot Charger?", isPresented: $showingRebootConfirm, titleVisibility: .visible) {
                        Button("Reboot", role: .destructive) {
                            Task {
                                await rebootCharger()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will reboot the SmartEVSE controller. Charging may be interrupted.")
                    }
                }
            }
        }
    }
    
    // MARK: - Actions
    private func setBusy(_ busy: Bool) {
        isBusy = busy
    }

    private func validateIP() -> Bool { !ipAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @MainActor
    private func refreshNow() async {
        guard validateIP() else { return }
        _ = await service.getSettings(ip: ipAddress)
        // keep local toggles in sync with service
        isOn = service.currentMode != .off
        // Only adopt service mode into the picker when the charger is actually on; when off, keep user's preferred on-mode
        if isOn, service.currentMode == .normal || service.currentMode == .smart || service.currentMode == .solar {
            selectedMode = service.currentMode
        }
        isCableLocked = service.isCableLocked
    }

    @MainActor
    private func toggleEVSE(_ newValue: Bool) async {
        guard validateIP() else { return }
        setBusy(true)
        defer { setBusy(false) }
        isOn = newValue
        if newValue {
            // turning on uses the selected mode
            await service.setMode(ip: ipAddress, mode: selectedMode)
        } else {
            // turning off
            await service.setMode(ip: ipAddress, mode: .off)
        }
        await refreshNow()
    }

    @MainActor
    private func applyOverride() async {
        guard validateIP() else { return }
        setBusy(true)
        defer { setBusy(false) }
        await service.setOverrideCurrent(ip: ipAddress, value: Int(overrideCurrent))
        await refreshNow()
    }

    @MainActor
    private func scheduleStart() async {
        guard validateIP() else { return }
        setBusy(true)
        defer { setBusy(false) }
        // Use the currently selected on-mode for scheduling
        await service.setStartTime(ip: ipAddress, date: startTime, mode: selectedMode)
        await refreshNow()
    }

    @MainActor
    private func rebootCharger() async {
        guard validateIP() else { return }
        setBusy(true)
        defer { setBusy(false) }
        await service.reboot(ip: ipAddress)
        // Give the device a moment and refresh; adjust delay if needed
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await refreshNow()
    }
    
    @MainActor
    private func setCableLocked(_ locked: Bool) async {
        guard validateIP() else { return }
        setBusy(true)
        defer { setBusy(false) }
        // Attempt to call service to lock/unlock cable; adjust to your service API
        await service.setCableLock(ip: ipAddress, locked: locked)
        isCableLocked = locked
        await refreshNow()
    }
}

