import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit
import AudioToolbox

// ⚠️ Change this to your ngrok URL
let SERVER_URL = "https://2291-31-206-48-4.ngrok-free.app"

// MARK: - View

struct ContentView: View {
    @StateObject private var vm = AppViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Circle()
                .fill(vm.isConnected ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)
        }
        .onAppear { vm.setup() }
    }
}

// MARK: - ViewModel

class AppViewModel: ObservableObject {
    @Published var isConnected = false

    private var lastAnswer     = ""
    private var isBusy         = false
    private var previousVolume : Float = 0.5
    private var volumeObserver : NSKeyValueObservation?
    private let session        = AVAudioSession.sharedInstance()

    // MARK: Setup

    func setup() {
        UIApplication.shared.isIdleTimerDisabled = true
        setupAudio()
        addHiddenVolumeView()
        observeVolume()
        ping()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.ping()
        }
    }

    // MARK: Audio Session

    private func setupAudio() {
        do {
            try session.setActive(true)
            try session.setCategory(.playback, options: .mixWithOthers)
            previousVolume = session.outputVolume
        } catch {
            print("Audio error: \(error)")
        }
    }

    // MARK: Hide Volume HUD

    private func addHiddenVolumeView() {
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.alpha = 0.01
        DispatchQueue.main.async {
            if let scene  = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = scene.windows.first {
                window.addSubview(view)
            }
        }
    }

    // MARK: Volume Observer

    private func observeVolume() {
        volumeObserver = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, !self.isBusy else { return }
            guard let newVol = change.newValue else { return }

            let diff = newVol - self.previousVolume
            self.previousVolume = newVol

            if diff > 0.01 {
                self.captureScreenshot()   // Volume UP  → trigger screenshot
            } else if diff < -0.01 {
                self.replayAnswer()        // Volume DOWN → replay last answer
            }

            self.resetVolume()
        }
    }

    private func resetVolume() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let view = MPVolumeView(frame: .zero)
            if let slider = view.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.value = 0.5
            }
            self.previousVolume = 0.5
        }
    }

    // MARK: Ping

    private func ping() {
        guard let url = URL(string: "\(SERVER_URL)/ping") else { return }
        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["status"] as? String == "ok" {
                    self?.isConnected = true
                } else {
                    self?.isConnected = false
                }
            }
        }.resume()
    }

    // MARK: Volume UP → Capture Screenshot

    private func captureScreenshot() {
        guard !isBusy else { return }
        isBusy = true

        // 1 vibration = capture started
        vibrate(times: 1)

        guard let url = URL(string: "\(SERVER_URL)/capture") else {
            isBusy = false
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        req.timeoutInterval = 20

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            defer { DispatchQueue.main.async { self?.isBusy = false } }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["status"] as? String == "ok" else { return }

            // 2 vibrations = screenshot received successfully
            DispatchQueue.main.async {
                self?.vibrate(times: 2)
            }
        }.resume()
    }

    // MARK: Volume DOWN → Replay Last Answer

    private func replayAnswer() {
        // First fetch latest answer from server
        guard let url = URL(string: "\(SERVER_URL)/last") else { return }
        var req = URLRequest(url: url)
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            if let data,
               let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let answer = json["analysis"] as? String,
               !answer.isEmpty {
                self.lastAnswer = answer.trimmingCharacters(in: .whitespaces).lowercased()
            }

            DispatchQueue.main.async {
                self.vibrateForAnswer(self.lastAnswer)
            }
        }.resume()
    }

    // MARK: Haptics

    private func vibrateForAnswer(_ answer: String) {
        guard !answer.isEmpty else {
            // No answer yet - single light tap
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
        vibrate(times: count)
    }

    private func vibrate(times: Int) {
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            }
        }
    }
}