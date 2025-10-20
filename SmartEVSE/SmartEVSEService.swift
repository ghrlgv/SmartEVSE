//
//  SmartEVSEService.swift
//  SmartEVSEapp
//
//  Created by Ruud Verheul on 17/10/2025.
//

import Foundation
import SwiftUI
import Combine

enum EVSEMode: Int, CaseIterable, Identifiable, Codable {
    case off = 0
    case normal = 1
    case solar = 2
    case smart = 3
    case pause = 4

    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .off: return "OFF"
        case .normal: return "Normal"
        case .solar: return "Solar"
        case .smart: return "Smart"
        case .pause: return "Pause"
        }
    }
}

struct EVSEAPIResponseColors: Decodable {
    let off: String?
    let normal: String?
    let solar: String?
    let smart: String?
    let custom: String?
}

struct EVSEAPIResponseEVMeter: Decodable {
    let charged_kwh: Double?
}

struct EVSEAPIResponseSettings: Decodable {
    let override_current: Int?
    let cablelock: Int?
}

struct EVSEAPIResponse: Decodable {
    let mode: String?
    let mode_id: Int?
    let color: EVSEAPIResponseColors?
    let settings: EVSEAPIResponseSettings?
    let ev_meter: EVSEAPIResponseEVMeter?
}

struct HistoryItem: Identifiable, Codable {
    let id: UUID
    let date: Date
    let mode: EVSEMode
    let hex: String
    let chargedKWh: Double?

    init(id: UUID = UUID(), date: Date, mode: EVSEMode, hex: String, chargedKWh: Double? = nil) {
        self.id = id
        self.date = date
        self.mode = mode
        self.hex = hex
        self.chargedKWh = chargedKWh
    }
}

@MainActor final class SmartEVSEService: ObservableObject {
    @Published var lastMessage: String = ""
    @Published var statusColor: Color = .gray
    @Published var history: [HistoryItem] = [] // newest first
    @Published var currentMode: EVSEMode = .off
    @Published var isCableLocked: Bool = false

    private let historyLimit = 50
    private let historyStorageKey = "history_items_v1"

    init() {
        loadHistory()
    }

    func setMode(ip: String, mode: EVSEMode) async {
        await sendPOST(ip: ip, params: ["mode": String(mode.rawValue)])
    }

    func setOverrideCurrent(ip: String, value: Int) async {
        await sendPOST(ip: ip, params: ["override_current": String(value)])
    }

    func setStartTime(ip: String, date: Date, mode: EVSEMode) async {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startString = formatter.string(from: date)
        await sendPOST(ip: ip, params: ["starttime": startString, "mode": String(mode.rawValue)])
    }

    func setCableLock(ip: String, locked: Bool) async {
        let value = locked ? "1" : "0"
        await sendPOST(ip: ip, params: ["cablelock": value])
        // Optimistically update local state; will be corrected on next refresh if needed
        self.isCableLocked = locked
    }
    
    func reboot(ip: String) async {
        await sendPOST(ip: ip, params: ["reboot": "1"])
    }
    
    func clearHistory() {
        self.history.removeAll()
        saveHistory()
    }

    func exportHistory() {
        // TODO: implement export (e.g., share sheet) — placeholder to compile
    }

    func importHistory(from data: Data?) {
        // TODO: implement import — placeholder to compile
    }

    private func sendPOST(ip: String, params: [String: String]) async {
        let query = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        guard let url = URL(string: "http://\(ip)/settings?\(query)") else {
            updateMessage("Invalid IP address")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data() // IMPORTANT: empty body
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                if let decoded = try? JSONDecoder().decode(EVSEAPIResponse.self, from: data) {
                    print("[DEBUG][POST] mode_id=\(decoded.mode_id ?? -1), mode=\(decoded.mode ?? "nil")")
                    handleSettings(decoded)
                    updateMessage("Mode: \(decoded.mode ?? "unknown") | Current: \(decoded.settings?.override_current ?? 0)A")
                } else {
                    updateMessage("Settings updated.")
                }
            } else {
                updateMessage("HTTP error \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
        } catch {
            updateMessage("Network error: \(error.localizedDescription)")
        }
    }

    func getSettings(ip: String) async -> EVSEAPIResponse? {
        guard let url = URL(string: "http://\(ip)/settings") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let decoded = try? JSONDecoder().decode(EVSEAPIResponse.self, from: data) {
                print("[DEBUG][GET] mode_id=\(decoded.mode_id ?? -1), mode=\(decoded.mode ?? "nil")")
                handleSettings(decoded)
                return decoded
            }
        } catch {}
        return nil
    }

    private func handleSettings(_ decoded: EVSEAPIResponse) {
        // Determine mode and color
        let mode = EVSEMode(rawValue: decoded.mode_id ?? 0) ?? .off
        let colors = decoded.color
        let hex: String = {
            guard let colors else { return "#555555" }
            switch mode {
            case .normal: return colors.normal ?? "#00FF00"
            case .solar:  return colors.solar  ?? "#FFFF00"
            case .smart:  return colors.smart  ?? "#0000FF"
            case .off, .pause: return colors.off ?? "#555555"
            }
        }()

        // Update UI color
        self.statusColor = Color(hex: hex)

        // History + notifications when the mode actually changes
        if mode != currentMode {
            currentMode = mode
            let energy = (mode == .off) ? decoded.ev_meter?.charged_kwh : nil
            pushHistory(mode: mode, hex: hex, chargedKWh: energy)
            NotificationManager.shared.notify(title: "SmartEVSE mode changed", body: mode.displayName)
        }

        if let lock = decoded.settings?.cablelock { self.isCableLocked = (lock != 0) }
    }

    private func pushHistory(mode: EVSEMode, hex: String, chargedKWh: Double? = nil) {
        history.insert(HistoryItem(date: Date(), mode: mode, hex: hex, chargedKWh: chargedKWh), at: 0)
        saveHistory()
    }

    private func updateMessage(_ text: String) {
        self.lastMessage = text
    }
    
    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(history)
            UserDefaults.standard.set(data, forKey: historyStorageKey)
        } catch {
            // ignore persistence errors for now
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyStorageKey) else { return }
        if let items = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            self.history = items
        }
    }
}

extension Color {
    init(hex: String) {
        let hexString = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        _ = Scanner(string: hexString).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

