import SwiftUI

/// Reachability of the hosted gateway, resolved by an actual authenticated
/// request. "Configured" and "working" are different things -- a wrong token
/// looks identical to a correct one until something calls the server.
enum GatewayStatus: Equatable {
  case checking
  case ready
  case notConfigured
  case unauthorized
  case unreachable(String)
}

private struct GatewayStatusLabel: View {
  let status: GatewayStatus

  var body: some View {
    switch status {
    case .checking:
      ProgressView()
    case .ready:
      Label("Connected", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .labelStyle(.titleAndIcon)
    case .notConfigured:
      Text("Not set up")
        .foregroundStyle(.secondary)
    case .unauthorized:
      Label("Token rejected", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .labelStyle(.titleAndIcon)
    case .unreachable(let why):
      Label(why, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .labelStyle(.titleAndIcon)
    }
  }
}

struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  private let settings = SettingsManager.shared

  @State private var cloudGatewayURL: String = ""
  @State private var cloudGatewayToken: String = ""
  @State private var showResetConfirmation = false
  @State private var gatewayStatus: GatewayStatus = .checking
  // Applies immediately rather than on Save: the root view observes the same
  // key and swaps the capture pipeline live.
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(IntelligenceEngine.defaultsKey) private var intelligenceRaw = IntelligenceEngine.gemini.rawValue
  @AppStorage(SettingsManager.showCaptionsKey) private var showCaptions = true
  @AppStorage("corvus.watchOnCameraScreen") private var watchOnCameraScreen = true
  @AppStorage("corvus.showWatcherHUD") private var showWatcherHUD = true
  @AppStorage("corvus.interceptsEnabled") private var interceptsEnabled = true
  @AppStorage("corvus.transcribeAnswers") private var transcribeAnswers = true
  @AppStorage("corvus.audioRouteMode") private var audioRouteRaw = AudioRouteMode.glassesBothWays.rawValue
  @AppStorage("corvus.interceptor") private var interceptorRaw = InterceptorKind.liveKit.rawValue

  var body: some View {
    NavigationView {
      Form {
        // The watcher bench. Runs the watcher on the phone camera with no
        // glasses, room or server -- the only way to tune detection thresholds
        // without a shopping trip.
        Section(header: Text("Corvus"), footer: Text(
          "The watcher runs on whatever the camera screen is showing, glasses "
          + "included. Turn the overlay off before a participant wears these -- "
          + "a debug readout changes how someone behaves on camera.")) {
          NavigationLink("Watcher bench") {
            CorvusWatcherView()
          }
          NavigationLink("Audio route probe") {
            AudioRouteProbeView()
          }
          Toggle("Watch the camera screen", isOn: $watchOnCameraScreen)
          Toggle("Show detection overlay", isOn: $showWatcherHUD)
        }

        // Intercepts. Off leaves the watcher exactly as it was -- trigger, banner,
        // log, silence -- which is the right setting while tuning detection.
        Section(header: Text("Intercepts"), footer: Text(
          interceptorRaw == InterceptorKind.conversational.rawValue
            ? "The study's opening question is always asked word for word. After "
              + "that a model hears the answer and picks the follow-up, or stops. "
              + "Expect about two seconds of silence between turns."
            : audioRouteRaw == AudioRouteMode.glassesBothWays.rawValue
            ? "Glasses speaker and glasses microphone. The route drops to call "
              + "quality, but the mic is on the wearer rather than in a pocket — "
              + "worth far more once there is background noise."
            : "Glasses speaker at full quality, answer recorded on the phone. "
              + "Cleaner audio, but the phone hears the room rather than the wearer.")) {
          Toggle("Ask the question out loud", isOn: $interceptsEnabled)
          Picker("Style", selection: $interceptorRaw) {
            ForEach(InterceptorKind.allCases) { kind in
              Text(kind.label).tag(kind.rawValue)
            }
          }
          Picker("Audio route", selection: $audioRouteRaw) {
            ForEach(AudioRouteMode.allCases, id: \.rawValue) { mode in
              Text(mode.label).tag(mode.rawValue)
            }
          }
          Toggle("Transcribe answers", isOn: $transcribeAnswers)
        }

        Section(header: Text("Camera"), footer: Text(captureSourceRaw == CaptureSource.glasses.rawValue
          ? "Streams from your Meta glasses. Connecting them happens on the main screen."
          : "Uses this phone's camera. The app opens straight into it, with voice ready.")) {
          Picker("Source", selection: $captureSourceRaw) {
            ForEach(CaptureSource.allCases, id: \.rawValue) { source in
              Text(source.label).tag(source.rawValue)
            }
          }
          .pickerStyle(.segmented)
        }

        Section(header: Text("Intelligence"), footer: Text(intelligenceRaw == IntelligenceEngine.openai.rawValue
          ? "OpenAI gpt-realtime. Applies to the next call."
          : "Google Gemini Live. Applies to the next call.")) {
          Picker("Model", selection: $intelligenceRaw) {
            ForEach(IntelligenceEngine.allCases, id: \.rawValue) { engine in
              Text(engine.label).tag(engine.rawValue)
            }
          }
          .pickerStyle(.segmented)
          Toggle("Show captions", isOn: $showCaptions)
        }

        // Cloud gateway is the only backend now.
        if true {
          Section {
            HStack {
              Text("Status")
              Spacer()
              GatewayStatusLabel(status: gatewayStatus)
            }

            NavigationLink("Connected Apps") {
              ConnectedAppsView()
            }

            NavigationLink("Recent Tasks") {
              RecentTasksView()
            }
          }

          // The URL and token ship with working defaults, so most people never
          // need to see them; surfacing them as primary fields made a configured
          // setup look like one awaiting setup.
          Section {
            DisclosureGroup("Gateway settings") {
              VStack(alignment: .leading, spacing: 4) {
                Text("Gateway URL")
                  .font(.caption)
                  .foregroundColor(.secondary)
                TextField("https://gateway.example.com", text: $cloudGatewayURL)
                  .autocapitalization(.none)
                  .disableAutocorrection(true)
                  .keyboardType(.URL)
                  .font(.system(.body, design: .monospaced))
              }

              VStack(alignment: .leading, spacing: 4) {
                Text("Access Token")
                  .font(.caption)
                  .foregroundColor(.secondary)
                TextField("Your gateway access token", text: $cloudGatewayToken)
                  .autocapitalization(.none)
                  .disableAutocorrection(true)
                  .font(.system(.body, design: .monospaced))
              }
            }
          }
        }

        Section {
          Button("Reset to Defaults") {
            showResetConfirmation = true
          }
          .foregroundColor(.red)
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Save") {
            save()
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
      .alert("Reset Settings", isPresented: $showResetConfirmation) {
        Button("Reset", role: .destructive) {
          settings.resetAll()
          loadCurrentValues()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This will reset all settings to the values built into the app.")
      }
      .onAppear {
        loadCurrentValues()
      }
      .task {
        await refreshGatewayStatus()
      }
    }
  }

  /// Ask the gateway for something that needs a valid token, and distinguish a
  /// rejected token from an unreachable server -- they need opposite fixes.
  ///
  /// /health rather than upstream's /apps: Corvus points this at its own token
  /// server, which has no /apps, so a working setup reported "Server error 404"
  /// beside intercepts that were running fine. Both servers answer /health.
  private func refreshGatewayStatus() async {
    
    gatewayStatus = .checking
    guard GeminiConfig.isAgentConfigured,
          let url = URL(string: "\(GeminiConfig.agentBaseURL)/health") else {
      gatewayStatus = .notConfigured
      return
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("Bearer \(GeminiConfig.agentToken)", forHTTPHeaderField: "Authorization")

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      switch code {
      case 200: gatewayStatus = .ready
      case 401, 403: gatewayStatus = .unauthorized
      default: gatewayStatus = .unreachable("Server error \(code)")
      }
    } catch {
      gatewayStatus = .unreachable("Unreachable")
    }
  }

  private func loadCurrentValues() {
    cloudGatewayURL = settings.cloudGatewayURL
    cloudGatewayToken = settings.cloudGatewayToken
  }

  private func save() {
    settings.cloudGatewayURL = cloudGatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.cloudGatewayToken = cloudGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
