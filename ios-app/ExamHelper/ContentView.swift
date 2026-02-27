import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit
import AudioToolbox

// ⚠️ رابط ngrok - تأكد إنه نفس الرابط الشغال عندك
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

    private var isCapturing = false
    private var ignoreNextVolumeChange = false

    private var answerPollTimer: Timer?
    private var lastKnownVersion: Int = 0
    private var savedAnswer: String = ""

    // MARK: - Setup

    func setup() {
        UIApplication.shared.isIdleTimerDisabled = true
        setupAudio()
        addHiddenVolumeView()

        savedAnswer = UserDefaults.standard.string(forKey: "lastAnswer") ?? ""
        lastKnownVersion = UserDefaults.standard.integer(forKey: "lastVersion")

        print("🔧 Setup done. SERVER_URL = \(SERVER_URL)")
        print("🔧 Saved answer: \(savedAnswer), version: \(lastKnownVersion)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.observeVolume()
            print("🔧 Volume observer started, current volume: \(self.session.outputVolume)")
        }

        pingServer()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.pingServer()
        }
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
                print("🔧 Hidden volume view added")
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
                print("🔇 Ignored volume reset")
                return
            }

            guard let newVol = change.newValue, let oldVol = change.oldValue else { return }
            let diff = newVol - oldVol
            print("🔊 Volume changed: \(oldVol) → \(newVol) (diff: \(diff))")

            if diff > 0.01 {
                print("⬆️ Volume UP detected")
                self.handleVolumeUp()
            } else if diff < -0.01 {
                print("⬇️ Volume DOWN detected")
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

    // MARK: - Volume UP → Capture

    private func handleVolumeUp() {
        guard !isCapturing else {
            print("⚠️ Already capturing, skipped")
            return
        }
        isCapturing = true

        vibrate(times: 1)
        print("📱 Sending POST /capture...")

        guard let url = URL(string: "\(SERVER_URL)/capture") else {
            print("❌ Invalid URL")
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

            defer {
                DispatchQueue.main.async { self.isCapturing = false }
            }

            if let error {
                print("❌ Capture network error: \(error.localizedDescription)")
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                print("📱 Capture HTTP status: \(httpResponse.statusCode)")
            }

            guard let data else {
                print("❌ No data received")
                return
            }

            if let str = String(data: data, encoding: .utf8) {
                print("📱 Capture response: \(str)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["status"] as? String == "ok" else {
                print("❌ Capture failed - status not ok")
                return
            }

            print("✅ Screenshot captured successfully!")
            DispatchQueue.main.async {
                self.vibrate(times: 2)
            }

            // Start polling for answer
            self.startAnswerPolling()
        }.resume()
    }

    // MARK: - Volume DOWN → Replay (local only, NEVER blocked)

    private func handleVolumeDown() {
        let answer = savedAnswer
        print("🔁 Replaying saved answer: '\(answer)'")
        DispatchQueue.main.async {
            self.vibrateForAnswer(answer)
        }
    }

    // MARK: - Answer Polling

    private func startAnswerPolling() {
        print("🔄 Starting answer polling...")
        DispatchQueue.main.async {
            self.answerPollTimer?.invalidate()

            self.answerPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                self?.checkForAnswer(timer: timer)
            }

            // Auto-stop after 120s
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                if self?.answerPollTimer != nil {
                    print("⏰ Answer polling timeout (120s)")
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

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }

            if let error {
                print("❌ Poll /last error: \(error.localizedDescription)")
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? Int,
                  let answer = json["analysis"] as? String,
                  !answer.isEmpty else { return }

            if version > self.lastKnownVersion {
                let cleanAnswer = answer.trimmingCharacters(in: .whitespaces).lowercased()
                print("🎉 New answer! '\(cleanAnswer)' v\(version)")

                self.lastKnownVersion = version
                self.savedAnswer = cleanAnswer

                UserDefaults.standard.set(self.savedAnswer, forKey: "lastAnswer")
                UserDefaults.standard.set(version, forKey: "lastVersion")

                DispatchQueue.main.async {
                    timer.invalidate()
                    self.answerPollTimer = nil
                    print("📳 Auto-vibrating for answer: \(cleanAnswer)")
                    self.vibrateForAnswer(cleanAnswer)
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

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    print("❌ Ping failed: \(error.localizedDescription)")
                    self?.dotColor = .gray.opacity(0.3)
                    return
                }

                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["status"] as? String == "ok" {
                    if self?.dotColor != .green {
                        print("✅ Ping OK - connected!")
                    }
                    self?.dotColor = .green
                } else {
                    if let data, let str = String(data: data, encoding: .utf8) {
                        print("⚠️ Ping unexpected response: \(str)")
                    }
                    self?.dotColor = .gray.opacity(0.3)
                }
            }
        }.resume()
    }

    // MARK: - Haptics

    private func vibrateForAnswer(_ answer: String) {
        guard !answer.isEmpty else {
            print("📳 No answer saved, light tap")
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

        print("📳 Vibrating \(count) times for '\(answer)'")
        guard count > 0 else { return }
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