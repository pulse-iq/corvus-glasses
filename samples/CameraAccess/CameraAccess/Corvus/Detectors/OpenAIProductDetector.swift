import Foundation

/// Watcher detector on OpenAI chat completions.
///
/// Chat Completions rather than the Responses API: the request shape has been
/// stable for years, which matters for a backend whose only job is to be a fair
/// comparison point. `temperature` is deliberately omitted -- the newer mini and
/// nano tiers reject it, and a 400 on an unrelated field would look like a
/// detector failure in the benchmark.
struct OpenAIProductDetector: ProductDetector {
  let model: String
  var name: String { "openai:\(model)" }
  var isConfigured: Bool { !CorvusConfig.openAIAPIKey.isEmpty }

  func detect(jpeg: Data, study: Study) async throws -> DetectionOutcome {
    let key = CorvusConfig.openAIAPIKey
    guard !key.isEmpty else { throw DetectorError.notConfigured(name) }

    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15

    let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    let body: [String: Any] = [
      "model": model,
      "response_format": ["type": "json_object"],
      "messages": [
        ["role": "system", "content": DetectionPrompt.system(for: study)],
        ["role": "user", "content": [
          ["type": "image_url", "image_url": ["url": dataURL, "detail": "low"]],
          ["type": "text", "text": DetectionPrompt.userTurn],
        ]],
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
          let choices = root["choices"] as? [[String: Any]],
          let message = choices.first?["message"] as? [String: Any],
          let text = message["content"] as? String
    else {
      throw DetectorError.unparseable(bodyText)
    }

    return DetectionOutcome(
      detection: try DetectionParser.parse(text, watchlist: study.items),
      latency: latency,
      rawResponse: text,
      detectorName: name)
  }
}
