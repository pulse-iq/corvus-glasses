import AVFoundation
import SwiftUI

/// The watcher bench.
///
/// Points the phone camera at the watcher and shows every gate it passes
/// through, because tuning the watcher is entirely about seeing *why* a pickup
/// did or did not fire. Runs with no glasses, no room and no server.
struct CorvusWatcherView: View {
  @StateObject private var watcher = WatcherCoordinator(study: StudyStore.shared.active)
  @StateObject private var camera = PhoneCameraSource()
  @ObservedObject private var studies = StudyStore.shared
  @State private var detectorKind = CorvusConfig.activeDetector
  @State private var captureCorpus = CorvusConfig.captureCorpus

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        preview
        controls
        status
        triggerList
      }
      .padding()
    }
    .navigationTitle("Watcher")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      camera.onFrame = { buffer in
        Task { @MainActor in watcher.submit(pixelBuffer: buffer) }
      }
      camera.start()
    }
    .onDisappear {
      camera.stop()
      watcher.stop()
    }
  }

  private var preview: some View {
    CameraPreview(session: camera.session)
      .frame(height: 260)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay(alignment: .topLeading) {
        if let error = camera.error {
          Text(error)
            .font(.caption)
            .padding(6)
            .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.white)
            .padding(8)
        }
      }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Which fieldwork is running. Items, questions and thresholds all come
      // from the selected study, not from code.
      HStack {
        Text("Study").foregroundStyle(.secondary)
        Spacer()
        Menu {
          ForEach(studies.studies) { study in
            Button(study.name) {
              studies.activate(study)
              watcher.use(study)
            }
          }
          Divider()
          Button("Reload from disk") {
            studies.reload()
            watcher.use(studies.active)
          }
        } label: {
          Text(watcher.study.name)
        }
      }
      Text("\(watcher.study.items.count) items watched")
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Detector", selection: $detectorKind) {
        ForEach(DetectorKind.allCases) { kind in
          Text(kind.displayName).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .onChange(of: detectorKind) { _, new in watcher.use(new) }

      if !watcher.isConfigured {
        Label("No API key for \(watcher.detectorName)", systemImage: "key.slash")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      Toggle("Save frames for benchmarking", isOn: $captureCorpus)
        .onChange(of: captureCorpus) { _, new in CorvusConfig.captureCorpus = new }
        .font(.subheadline)

      Button(watcher.isRunning ? "Stop watching" : "Start watching") {
        watcher.isRunning ? watcher.stop() : watcher.start()
      }
      .buttonStyle(.borderedProminent)
      .tint(watcher.isRunning ? .red : .accentColor)
    }
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 6) {
      row("Study", watcher.study.id)
      row("Detector", watcher.detectorName)
      row("Frames", "\(watcher.framesSeen) seen / \(watcher.framesSampled) sampled")
      if let latency = watcher.lastLatency {
        row("Latency", String(format: "%.0f ms", latency * 1000))
      }
      if let d = watcher.lastDetection {
        row("Holding", d.holding ? "yes" : "no")
        row("Item", d.itemID ?? d.productGuess ?? "-")
        row("Confidence", String(format: "%.2f", d.confidence))
      }
      if let decision = watcher.lastDecision {
        row("Decision", decision.label)
      }
      if watcher.isDetecting {
        row("State", "detecting...")
      }
      if let error = watcher.lastError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .font(.system(.subheadline, design: .monospaced))
  }

  @ViewBuilder
  private var triggerList: some View {
    if !watcher.triggers.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Triggers").font(.headline)
        ForEach(watcher.triggers, id: \.firedAt) { trigger in
          VStack(alignment: .leading, spacing: 2) {
            Text(trigger.item.displayName).bold()
            Text(trigger.item.question)
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(String(format: "%.2f confidence, %d hits", trigger.confidence, trigger.hitCount))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value).multilineTextAlignment(.trailing)
    }
  }
}

/// Thin AVCaptureVideoPreviewLayer wrapper -- the watcher's own preview, kept
/// independent of the call screen's renderer.
private struct CameraPreview: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.layer.session = session
    view.layer.videoGravity = .resizeAspectFill
    return view
  }

  func updateUIView(_ uiView: PreviewView, context: Context) {}

  final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    override var layer: AVCaptureVideoPreviewLayer { super.layer as! AVCaptureVideoPreviewLayer }
  }
}
