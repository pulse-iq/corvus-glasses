/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionView.swift
//
// The app's front door. Phone mode joins a LiveKit room on sight -- camera,
// mic and the assistant all come up together; everything intelligent lives
// server-side. Glasses mode keeps the DAT streaming flow (assistant voice for
// glasses returns when their frames publish into the room as a track).
//

import MWDATCore
import SwiftUI
import UIKit

struct StreamSessionView: View {
  let wearables: WearablesInterface?
  private let wearablesViewModel: WearablesViewModel?
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var liveKit = LiveKitSession()
  /// The Corvus watcher. Watches the same glasses frames the call publishes
  /// and decides when a pickup is worth interrupting for.
  @StateObject private var watcher = WatcherCoordinator(study: StudyStore.shared.active)
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(IntelligenceEngine.defaultsKey) private var intelligenceRaw = IntelligenceEngine.gemini.rawValue
  @State private var glassesAutoStarted = false
  /// Only signal available that DAT camera permission may have been granted.
  /// It is granted in the Meta AI app, and nothing publishes it back here.
  @Environment(\.scenePhase) private var scenePhase
  @State private var glassesResumeTask: Task<Void, Never>?
  /// The call screen is the app's front door but carries no settings
  /// affordance, so on this fork the Watcher was unreachable from the UI.
  @State private var showSettings = false
  @AppStorage("corvus.showWatcherHUD") private var showHUD = true
  @AppStorage("corvus.watchOnCameraScreen") private var watchHere = true
  /// Observed here rather than only read at launch: Settings writes this key,
  /// and the coordinator builds its interceptor once in init, so without a
  /// watcher on it the picker silently did nothing until the next relaunch.
  @AppStorage("corvus.interceptor") private var interceptorRaw = InterceptorKind.liveKit.rawValue

  private var captureSource: CaptureSource {
    CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera
  }

  private var glassesPlaceholder: (title: String, caption: String) {
    switch viewModel.glassesIssue {
    case .sdkUnavailable:
      return ("Glasses unavailable", "The glasses SDK is not available on this device.")
    case .permissionNeeded:
      return ("Glasses permission needed", "Allow it in the Meta AI app.")
    case .hingesClosed:
      return ("Glasses folded", "Open the hinges to start streaming.")
    case .reconnecting:
      return ("Reconnecting to glasses", "Video will appear when your glasses start streaming.")
    case nil:
      return ("Waiting for glasses video", "Video will appear when your glasses start streaming.")
    }
  }

  init(wearables: WearablesInterface?, wearablesVM: WearablesViewModel?) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    ZStack {
      if captureSource == .iPhoneCamera {
        LiveKitStreamView(session: liveKit)
      } else if viewModel.isStreaming {
        // Glasses are just another camera: same call screen, same agent, with
        // DAT frames bridged into the room via pushGlassesFrame.
        LiveKitStreamView(session: liveKit, glassesPlaceholder: glassesPlaceholder)
      } else if let wearablesViewModel {
        if wearablesViewModel.registrationState == .registered || wearablesViewModel.hasMockDevice {
          // No start-choice interstitial: registered glasses go straight to
          // the call screen, auto-starting the stream once per entry, then
          // re-attempting on a slow cadence while the glasses are asleep --
          // the placeholder is the only voice for the wait.
          LiveKitStreamView(session: liveKit, glassesPlaceholder: glassesPlaceholder)
            .task {
              guard !glassesAutoStarted else { return }
              glassesAutoStarted = true
              // Restored to the cadence this shipped with. Two attempts at
              // retuning it moved the time-to-first-frame from 36s to 31s --
              // noise -- because the wait was never this loop's fault.
              for _ in 0..<4 {
                await viewModel.handleStartStreaming()
                if viewModel.isStreaming { break }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if viewModel.isStreaming || captureSource != .glasses { break }
              }
            }
        } else {
          HomeScreenView(viewModel: wearablesViewModel)
        }
      } else {
        Color.black.edgesIgnoringSafeArea(.all)
      }

      // Settings, and through it the Watcher. Overlaid rather than placed in a
      // toolbar because this screen has no navigation chrome to hang one on.
      VStack {
        HStack {
          Spacer()
          Button {
            showSettings = true
          } label: {
            Image(systemName: "gearshape.fill")
              .foregroundStyle(.white)
              .padding(10)
              .background(.black.opacity(0.45), in: Circle())
          }
          .padding(.trailing, 16)
          .padding(.top, 8)
        }
        Spacer()

        // The watcher, visible. Bottom-left so it clears the call chrome.
        if showHUD {
          HStack {
            WatcherHUD(watcher: watcher)
              .frame(maxWidth: 300, alignment: .leading)
            Spacer()
          }
          .padding(.leading, 16)
          .padding(.bottom, 110)
        }
      }
    }
    .sheet(isPresented: $showSettings) {
      SettingsView()
    }
    .task {
      viewModel.onDecodedFrame = { [weak liveKit] pixelBuffer in
        liveKit?.pushGlassesFrame(pixelBuffer)
      }
      // The watcher rides the same feed. Its own sampler throttles to ~1fps, so
      // handing it every frame costs a closure call.
      viewModel.onAnalysisFrame = { [weak watcher] image in
        // Heartbeat first: the audio probe needs proof DAT is still delivering
        // even when the watcher is stopped or another screen is up.
        FrameHeartbeat.shared.tick()
        watcher?.submit(image: image)
      }
      // Realtime intercepts run through this screen's room.
      watcher.attach(liveKit: liveKit)
      if watchHere { watcher.start() }
      if CorvusConfig.useLiveKitCall {
        if captureSource == .iPhoneCamera {
          await liveKit.start()
        }
      } else {
        // The preview is otherwise only ever opened as a side effect of
        // start(), so skipping the call left the screen black. It is purely
        // local -- no room, no gateway -- and it covers both sources: the back
        // camera on the phone, and the buffer track pushGlassesFrame writes
        // into on the glasses.
        await liveKit.startPreview()
      }
    }
    .onDisappear {
      watcher.stop()
      glassesResumeTask?.cancel()
    }
    .onChange(of: viewModel.isStreaming) { streaming in
      // Glasses mode: the call rides the DAT stream's lifecycle -- frames
      // start flowing, the room opens; the stream ends, the call ends.
      guard captureSource == .glasses, CorvusConfig.useLiveKitCall else { return }
      Task {
        if streaming {
          await liveKit.start()
        } else if liveKit.isActive {
          await liveKit.stop()
        }
      }
    }
    .onChange(of: interceptorRaw) { raw in
      // Rebuilds the interceptor in place, so the choice applies to the next
      // trigger rather than the next launch.
      if let kind = InterceptorKind(rawValue: raw) { watcher.use(kind) }
    }
    .onChange(of: intelligenceRaw) { _ in
      // The brain is chosen at session start (room-token metadata), so a live
      // call redials itself to apply the switch -- the user flips a toggle and
      // three seconds later the other model picks up.
      Task {
        if liveKit.isActive {
          await liveKit.stop()
          await liveKit.start()
        }
      }
    }
    .onChange(of: scenePhase) { phase in
      // Camera permission for the glasses is granted in the Meta AI app, in a
      // second hand-off that lands after registration -- usually after the
      // auto-start loop above has spent all four attempts and latched itself
      // off. Nothing publishes that grant back, so returning to the foreground
      // is the only evidence it may have happened.
      //
      // Poll rather than check once. The grant is routinely still invisible to
      // `checkPermissionStatus` at the moment the app foregrounds, so a single
      // attempt on return fails and nothing retries -- which is precisely what
      // made toggling the capture source look like the only cure, and why it
      // had to be repeated: each toggle rebuilt the view and bought another run
      // of the retry loop above.
      //
      // `resumeIfPermitted` checks without requesting. Calling the requesting
      // path from here would deeplink back out to the Meta AI app the user has
      // just come from.
      guard phase == .active, captureSource == .glasses, !viewModel.isStreaming else { return }
      glassesAutoStarted = false
      glassesResumeTask?.cancel()
      glassesResumeTask = Task {
        for _ in 0..<10 {
          if Task.isCancelled || viewModel.isStreaming || captureSource != .glasses { return }
          if await viewModel.resumeIfPermitted() { return }
          try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
      }
    }
    .onChange(of: captureSourceRaw) { newRaw in
      glassesAutoStarted = false
      Task {
        if CaptureSource(rawValue: newRaw) == .iPhoneCamera {
          if viewModel.isStreaming { await viewModel.stopSession() }
          // Guarded like the other two start sites. Unguarded, switching to the
          // phone camera opened upstream's assistant room -- a room with no
          // intercept brief, so the worker joins as the ordinary assistant and
          // starts talking. That is a second voice over the top of the
          // interceptor, and it also strands the worker: with no brief the
          // tracer pump runs, and without GATEWAY_URL it raises every five
          // seconds and holds the process open past teardown.
          if CorvusConfig.useLiveKitCall { await liveKit.start() } else { await liveKit.startPreview() }
        } else {
          await liveKit.stop()
        }
      }
    }
    .alert("Error", isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }
}
