import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit
import AudioToolbox

// ⚠️ رابط ngrok
let SERVER_URL = "https://2291-31-206-48-4.ngrok-free.app"

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
    @Published var dotColor: Color = .gray.opacity(0.3)

    private var previousVolume: Float = 0.5
    private var volumeObserver: NSKeyValueObservation?
    private let session = AVAudioSession.sharedInstance()

    private var isCapturing = false              // ONLY blocks volume UP
    private var ignoreNextVolumeChange = false

    private var answerPollTimer: Timer?
    private var lastKnownVersion: Int = 0        // synced from server on startup
    private var savedAnswer: String = ""

    // MARK: - Setup

    func setup() {
        UIApplication.shared.isIdleTimerDisabled = true
        setupAudio()
        addHiddenVolumeView()

        // Load local cache
        savedAnswer = UserDefaults.standard.string(forKey: "lastAnswer") ?? ""

        print("🔧 Setup done. SERVER_URL = \(SERVER_URL)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.observeVolume()
            print("🔧 Volume observer started")
        }

        // Sync version from server FIRST, then start ping loop
        syncVersionFromServer()

        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.pingServer()
        }
    }

    // MARK: - Sync version from server on startup
    // This prevents the "stale version" bug where local version is behind server

    private func syncVersionFromServer() {
        guard let url = URL(string: "\(SERVER_URL)/last") else { return }

        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }

            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["version"] as? Int {

                self.lastKnownVersion = version

                // Also sync the answer if there is one
                if let answer = json["analysis"] as? String, !answer.isEmpty {
                    self.savedAnswer = answer.trimmingCharacters(in: .whitespaces).lowercased()
                    UserDefaults.standard.set(self.savedAnswer, forKey: "lastAnswer")
                }

                print("🔄 Synced from server: version=\(version), answer='\(self.savedAnswer)'")
            }

            DispatchQueue.main.async {
                self.pingServer()
            }
        }.resume()
    }

    // MARK: - Audio

    private func setupAudio() {
        do {
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            previousVolume = session.outputVolume
            print("🔊 Audio setup OK, volume: \(previousVolume)")
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

    // MARK: - Volume UP → Capture + Auto-poll for answer

    private func handleVolumeUp() {
        guard !isCapturing else {
            print("⚠️ Already capturing, skip")
            return
        }
        isCapturing = true

        // 1 vibration = started
        vibrate(times: 1)

        guard let url = URL(string: "\(SERVER_URL)/capture") else {
            isCapturing = false
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.timeoutInterval = 20

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }

            // Release capture lock
            DispatchQueue.main.async { self.isCapturing = false }

            if let error {
                print("❌ Capture error: \(error.localizedDescription)")
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("❌ Invalid response")
                return
            }

            let status = json["status"] as? String ?? "unknown"
            print("📱 Capture response: \(status)")

            if status == "ok" {
                // 2 vibrations = screenshot received
                DispatchQueue.main.async {
                    self.vibrate(times: 2)
                }
                // Start polling for the admin's answer
                self.startAnswerPolling()
            } else if status == "timeout" {
                print("⏰ Windows didn't capture in time")
                // 3 short taps = error signal
                DispatchQueue.main.async {
                    let gen = UINotificationFeedbackGenerator()
                    gen.notificationOccurred(.error)
                }
            }
        }.resume()
    }

    // MARK: - Volume DOWN → Replay from local (NEVER blocked by isCapturing)

    private func handleVolumeDown() {
        let answer = savedAnswer
        print("🔁 Replay: '\(answer)'")
        DispatchQueue.main.async {
            self.vibrateForAnswer(answer)
        }
    }

    // MARK: - Answer Polling (auto-vibrate when admin sends answer)

    private func startAnswerPolling() {
        print("🔄 Polling for answer... (current version: \(lastKnownVersion))")
        DispatchQueue.main.async {
            self.answerPollTimer?.invalidate()

            self.answerPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                self?.checkForAnswer(timer: timer)
            }

            // Timeout after 180s
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
                if self?.answerPollTimer != nil {
                    print("⏰ Answer poll timeout")
                    self?.answerPollTimer?.invalidate()
                    self?.answerPollTimer = nil
                }
            }
        }
    }

    private func checkForAnswer(timer: Timer) {
        guard let url = URL(string: "\(SERVER_URL)/last") else { return }

        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? Int,
                  let answer = json["analysis"] as? String,
                  !answer.isEmpty else { return }

            // New answer detected!
            if version > self.lastKnownVersion {
                let clean = answer.trimmingCharacters(in: .whitespaces).lowercased()
                print("🎉 New answer: '\(clean)' v\(version)")

                self.lastKnownVersion = version
                self.savedAnswer = clean

                UserDefaults.standard.set(clean, forKey: "lastAnswer")
                UserDefaults.standard.set(version, forKey: "lastVersion")

                DispatchQueue.main.async {
                    // Stop polling
                    timer.invalidate()
                    self.answerPollTimer = nil

                    // AUTO-VIBRATE immediately!
                    print("📳 Auto-vibrate: \(clean)")
                    self.vibrateForAnswer(clean)
                }
            }
        }.resume()
    }

    // MARK: - Ping

    private func pingServer() {
        guard let url = URL(string: "\(SERVER_URL)/ping") else { return }

        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async {
                if let error {
                    print("❌ Ping: \(error.localizedDescription)")
                    self?.dotColor = .gray.opacity(0.3)
                    return
                }
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["status"] as? String == "ok" {
                    self?.dotColor = .green
                } else {
                    self?.dotColor = .gray.opacity(0.3)
                }
            }
        }.resume()
    }

    // MARK: - Haptics

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
        print("📳 \(count) vibrations for '\(answer)'")
        vibrate(times: count)
    }

    private func vibrate(times: Int) {
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }
}