import Foundation

/// Watcher detector on the Anthropic Messages API.
///
/// Raw HTTP rather than an SDK: there is no official Anthropic SDK for Swift,
/// and this is a single stateless request. Thinking is left off entirely --
/// Haiku 4.5 predates adaptive thinking, and a yes/no-plus-label verdict is not
/// what extended reasoning is for.
struct AnthropicProductDetector: ProductDetector {
  let model: String
  var name: String { "anthropic:\(model)" }
  var isConfigured: Bool { !CorvusConfig.anthropicAPIKey.isEmpty }

  func detect(jpeg: Data, study: Study) async throws -> DetectionOutcome {
    let key = CorvusConfig.anthropicAPIKey
    guard !key.isEmpty else { throw DetectorError.notConfigured(name) }

    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.timeoutInterval = 15

    let body: [String: Any] = [
      "model": model,
      "max_tokens": 500,
      "temperature": 0,
      "system": DetectionPrompt.system(for: study),
      "messages": [[
        "role": "user",
        "content": [
          ["type": "image", "source": [
            "type": "base64",
            "media_type": "image/jpeg",
            "data": jpeg.base64EncodedString(),
          ]],
          ["type": "text", "text": DetectionPrompt.userTurn],
        ],
      ]],
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
          let content = root["content"] as? [[String: Any]],
          let text = content.compactMap({ $0["text"] as? String }).first
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
