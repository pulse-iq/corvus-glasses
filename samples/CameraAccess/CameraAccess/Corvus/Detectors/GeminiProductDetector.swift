import Foundation

/// Watcher detector on Gemini `generateContent`.
///
/// Deliberately not the Live API: this is one stateless image classification per
/// frame, so a plain HTTP round trip is cheaper and simpler than holding a
/// socket open. `responseMimeType: application/json` plus temperature 0 is what
/// keeps the verdict parseable and repeatable across a benchmark run.
struct GeminiProductDetector: ProductDetector {
  let model: String
  var name: String { "gemini:\(model)" }
  var isConfigured: Bool { !CorvusConfig.geminiAPIKey.isEmpty }

  func detect(jpeg: Data, study: Study) async throws -> DetectionOutcome {
    let key = CorvusConfig.geminiAPIKey
    guard !key.isEmpty else { throw DetectorError.notConfigured(name) }

    var request = URLRequest(
      url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    request.timeoutInterval = 15

    let body: [String: Any] = [
      "system_instruction": ["parts": [["text": DetectionPrompt.system(for: study)]]],
      "contents": [[
        "role": "user",
        "parts": [
          ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
          ["text": DetectionPrompt.userTurn],
        ],
      ]],
      "generationConfig": [
        "temperature": 0,
        "responseMimeType": "application/json",
        "maxOutputTokens": 500,
        // Flash-family models think by default; for a yes/no-plus-label call it
        // buys nothing and costs the latency the watcher is built around.
        "thinkingConfig": ["thinkingBudget": 0],
      ],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let started = Date()
    let (data, response) = try await send(request)
    let latency = Date().timeIntervalSince(started)

    guard let http = response as? HTTPURLResponse else {
      throw DetectorError.transport("no HTTP response")
    }
    let bodyText = String(data: data, encoding: .utf8) ?? ""
    guard (200..<300).contains(http.statusCode) else {
      throw DetectorError.badStatus(http.statusCode, bodyText)
    }

    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let candidates = root["candidates"] as? [[String: Any]],
          let content = candidates.first?["content"] as? [String: Any],
          let parts = content["parts"] as? [[String: Any]],
          let text = parts.compactMap({ $0["text"] as? String }).first
    else {
      throw DetectorError.unparseable(bodyText)
    }

    return DetectionOutcome(
      observation: try DetectionParser.parse(text, study: study),
      latency: latency,
      rawResponse: text,
      detectorName: name)
  }
}

/// URLSession's async API surfaces cancellation and transport failure as the
/// same throw; wrapping it keeps every detector reporting DetectorError.
func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
  do {
    return try await URLSession.shared.data(for: request)
  } catch {
    throw DetectorError.transport(error.localizedDescription)
  }
}
