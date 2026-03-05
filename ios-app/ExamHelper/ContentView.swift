import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit
import AudioToolbox

// ⚠️ رابط ngrok — بدون مسافة في النهاية!
let SERVER_URL = "https://05c7-45-156-31-150.ngrok-free.app"

// MARK: - View

struct ContentView: View {
    @StateObject private var vm = AppViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Circle()
                .fill(vm.dotColor)
                .frame(width: 10, height: 10)
        }
        .onAppear { vm.setup() }
    }
}

// MARK: - ViewModel

class AppViewModel: ObservableObject {
    @Published var dotColor: Color = .clear

    private var previousVolume: Float = 0.5
    private var volumeObserver: NSKeyValueObservation?
    private let session = AVAudioSession.sharedInstance()

    // Separate flags — volume DOWN is NEVER blocked
    private var isCapturing = false
    private var ignoreNextVolumeChange = false

    // WebSocket
    private var wsTask: URLSessionWebSocketTask?
    private var wsConnected = false
    private var shouldReconnect = true
    private var reconnectAttempts = 0
    private var maxReconnectAttempts = 120 // 30 minutes of retrying

    // Answer state
    private var lastKnownVersion: Int = 0
    private var savedAnswer: String = ""

    // MARK: - Setup

    func setup() {
        UIApplication.shared.isIdleTimerDisabled = true
        setupAudio()
        addHiddenVolumeView()

        // Load local cache
        savedAnswer = UserDefaults.standard.string(forKey: "lastAnswer") ?? ""

        print("🔧 SERVER_URL = \(SERVER_URL)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.observeVolume()
        }

        // Connect WebSocket
        connectWebSocket()

        // Ping every 15s to keep connection alive (same as server)
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.sendWSPing()
        }
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket() {
        guard shouldReconnect else { return }

        let wsURL = SERVER_URL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")

        guard let url = URL(string: wsURL) else {
            print("❌ Invalid WS URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")

        let session = URLSession(configuration: .default)
        wsTask = session.webSocketTask(with: request)
        wsTask?.resume()

        // Register as iPhone
        let registerMsg = ["type": "register", "role": "iphone"]
        if let data = try? JSONSerialization.data(withJSONObject: registerMsg) {
            wsTask?.send(.string(String(data: data, encoding: .utf8)!)) { error in
                if let error {
                    print("❌ WS register error: \(error.localizedDescription)")
                }
            }
        }

        // Start receiving
        receiveWSMessage()

        print("🔌 WebSocket connecting...")
    }

    private func receiveWSMessage() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleWSMessage(text)
                default:
                    break
                }
                // Continue receiving
                self.receiveWSMessage()

            case .failure(let error):
                print("❌ WS receive error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.wsConnected = false
                    self.dotColor = .gray.opacity(0.3)
                    
                    // Hide gray dot after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.dotColor = .clear
                    }
                }
                // Aggressive reconnect
                if self.reconnectAttempts < self.maxReconnectAttempts {
                    self.reconnectAttempts += 1
                    print("🔄 Reconnecting... attempt \(self.reconnectAttempts)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.connectWebSocket()
                    }
                } else {
                    print("❌ Max reconnect attempts reached")
                }
            }
        }
    }

    private func handleWSMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "registered" {
            // Connected! Sync version from server
            if let version = json["version"] as? Int {
                lastKnownVersion = version
            }
            if let answer = json["analysis"] as? String, !answer.isEmpty {
                savedAnswer = answer.trimmingCharacters(in: .whitespaces).lowercased()
                UserDefaults.standard.set(savedAnswer, forKey: "lastAnswer")
            }

            DispatchQueue.main.async {
                self.wsConnected = true
                self.reconnectAttempts = 0
                self.dotColor = .green
                print("✅ WebSocket connected! version=\(self.lastKnownVersion) answer='\(self.savedAnswer)'")
            }
        }

        if type == "answer" {
            // 🎉 Answer pushed from server INSTANTLY!
            guard let answer = json["analysis"] as? String,
                  let version = json["version"] as? Int,
                  !answer.isEmpty else { return }

            let clean = answer.trimmingCharacters(in: .whitespaces).lowercased()
            print("🎉 Answer received via WS: '\(clean)' v\(version)")

            lastKnownVersion = version
            savedAnswer = clean
            UserDefaults.standard.set(clean, forKey: "lastAnswer")
            UserDefaults.standard.set(version, forKey: "lastVersion")

            // AUTO-VIBRATE immediately!
            DispatchQueue.main.async {
                print("📳 Auto-vibrate: \(clean)")
                self.vibrateForAnswer(clean)
            }
        }

        if type == "admin_captured" {
            // Admin captured screenshot - special haptic feedback
            print("📱 Admin captured - haptic feedback")
            DispatchQueue.main.async {
                self.adminCapturedFeedback()
            }
        }
    }

    private func sendWSPing() {
        wsTask?.sendPing { [weak self] error in
            if let error {
                print("❌ WS ping failed: \(error.localizedDescription)")
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    self.wsConnected = false
                    self.dotColor = .gray.opacity(0.3)
                    
                    // Hide gray dot after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.dotColor = .clear
                    }
                }
                
                // Aggressive reconnect on ping failure
                if self.reconnectAttempts < self.maxReconnectAttempts {
                    self.reconnectAttempts += 1
                    print("🔄 Reconnecting after ping failure... attempt \(self.reconnectAttempts)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.connectWebSocket()
                    }
                }
            } else {
                // Ping successful - keep connected
                DispatchQueue.main.async {
                    self?.wsConnected = true
                }
            }
        }
    }

    // MARK: - Audio

    private func setupAudio() {
        do {
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            previousVolume = session.outputVolume
        } catch {
            print("❌ Audio error: \(error)")
        }
    }

    private func addHiddenVolumeView() {
        DispatchQueue.main.async {
            let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
            volumeView.alpha = 0.01
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = scene.windows.first {
                window.addSubview(volumeView)
            }
        }
    }

    // MARK: - Volume Observer

    private func observeVolume() {
        previousVolume = session.outputVolume

        volumeObserver = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self else { return }

            if self.ignoreNextVolumeChange {
                self.ignoreNextVolumeChange = false
                return
            }

            guard let newVol = change.newValue, let oldVol = change.oldValue else { return }
            let diff = newVol - oldVol

            if diff > 0.01 {
                print("⬆️ Volume UP")
                self.handleVolumeUp()
            } else if diff < -0.01 {
                print("⬇️ Volume DOWN")
                self.handleVolumeDown()
            }

            self.resetVolume()
        }
    }

    private func resetVolume() {
        ignoreNextVolumeChange = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.setSystemVolume(0.5)
            self.previousVolume = 0.5
        }
    }

    private func setSystemVolume(_ value: Float) {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first {
            for view in window.subviews {
                if let volumeView = view as? MPVolumeView,
                   let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                    slider.value = value
                    return
                }
            }
        }
    }

    // MARK: - Volume UP → Capture (HTTP POST, background thread)

    private func handleVolumeUp() {
        guard !isCapturing else {
            print("⚠️ Already capturing")
            return
        }
        isCapturing = true

        // 1 vibration = started
        vibrate(times: 1)

        // Use HTTP for capture (reliable, handles timeout)
        guard let url = URL(string: "\(SERVER_URL)/capture") else {
            isCapturing = false
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.timeoutInterval = 30

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }

            DispatchQueue.main.async { self.isCapturing = false }

            if let error {
                print("❌ Capture error: \(error.localizedDescription)")
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["status"] as? String == "ok" else {
                if let data, let s = String(data: data, encoding: .utf8) {
                    print("❌ Capture response: \(s)")
                }
                return
            }

            print("✅ Screenshot captured!")
            DispatchQueue.main.async { self.vibrate(times: 2) }

            // Answer will arrive automatically via WebSocket — no polling needed!
        }.resume()
    }

    // MARK: - Volume DOWN → Replay (local only, NEVER blocked)

    private func handleVolumeDown() {
        // This is completely independent of isCapturing
        let answer = savedAnswer
        print("🔁 Replay: '\(answer)'")
        DispatchQueue.main.async {
            self.vibrateForAnswer(answer)
        }
    }

    // MARK: - Haptics

    private func adminCapturedFeedback() {
        // Special haptic for admin capture - distinctly different
        AudioServicesPlaySystemSound(1519)
        
        // Additional haptic for distinction
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            AudioServicesPlaySystemSound(1519)
        }
    }

    private func vibrateForAnswer(_ answer: String) {
        guard !answer.isEmpty else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        let count: Int
        switch answer.first {
        case "a": count = 1
        case "b": count = 2
        case "c": count = 3
        case "d": count = 4
        case "e": count = 5
        default:  count = 0
        }

        guard count > 0 else { return }
        print("📳 \(count) strong haptic pulses for '\(answer)'")
        strongHapticPulses(times: count)
    }

    private func strongHapticPulses(times: Int) {
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.0) {
                AudioServicesPlaySystemSound(1519)
            }
        }
    }

    private func vibrate(times: Int) {
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }
}
