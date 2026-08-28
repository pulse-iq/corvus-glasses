import Foundation

/// Turns a recorded answer into text.
///
/// Deliberately not on the interview's critical path. Transcription happens
/// after the wearer has walked away, so the round trip costs nothing the
/// participant experiences -- which is why a network transcriber is affordable
/// here when it would not be inside a live conversation. The audio is always
/// kept, so a failure is a gap to re-run rather than data lost.
protocol Transcriber: Sendable {
  var name: String { get }
  var isConfigured: Bool { get }
  func transcribe(_ audio: URL) async throws -> String
}

enum TranscriberError: LocalizedError {
  case notConfigured(String)
  case http(Int, String)
  case badResponse

  var errorDescription: String? {
    switch self {
    case .notConfigured(let what): return "\(what) is not configured"
    case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
    case .badResponse: return "Unexpected transcription response"
    }
  }
}

/// OpenAI's audio transcription endpoint.
///
/// Chosen over the on-device recogniser because HFP audio recorded in a shop is
/// exactly the narrowband, noisy case where the gap between them is widest, and
/// these transcripts are the research output -- the thing the whole apparatus
/// exists to produce.
struct OpenAITranscriber: Transcriber {
  let name = "OpenAI \(CorvusConfig.transcriptionModel)"

  var isConfigured: Bool { !CorvusConfig.openAIAPIKey.isEmpty }

  func transcribe(_ audio: URL) async throws -> String {
    let key = CorvusConfig.openAIAPIKey
    guard !key.isEmpty else { throw TranscriberError.notConfigured("OpenAI API key") }

    let boundary = "corvus-\(UUID().uuidString)"
    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    func field(_ name: String, _ value: String) {
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
      body.append("\(value)\r\n".data(using: .utf8)!)
    }

    field("model", CorvusConfig.transcriptionModel)
    field("response_format", "json")
    // Steer spelling towards the study's own vocabulary: product names are
    // exactly what a general model mishears, and they are the words that matter.
    if !CorvusConfig.transcriptionPrompt.isEmpty {
      field("prompt", CorvusConfig.transcriptionPrompt)
    }

    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\n"
        .data(using: .utf8)!)
    body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
    body.append(try Data(contentsOf: audio))
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    request.httpBody = body

    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      throw TranscriberError.http(code, String(data: data, encoding: .utf8) ?? "")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = object["text"] as? String
    else { throw TranscriberError.badResponse }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
