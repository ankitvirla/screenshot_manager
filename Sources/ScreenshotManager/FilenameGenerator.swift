import Foundation
import Vision

enum FilenameGenerator {
    static func suggest(from imageData: Data, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let visionRequest = VNRecognizeTextRequest()
            visionRequest.recognitionLevel = .accurate

            guard (try? VNImageRequestHandler(data: imageData).perform([visionRequest])) != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let lines = (visionRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let recognizedText = lines.prefix(30).joined(separator: "\n")
            guard !recognizedText.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let fallbackName = slug(from: lines.prefix(2).joined(separator: " "))
            guard let endpoint = URL(string: "http://localhost:11434/api/generate") else {
                DispatchQueue.main.async { completion(fallbackName) }
                return
            }

            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = 12
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": "qwen2.5:7b",
                "prompt": "Name a screenshot file using the most distinctive topic words from this OCR text. Preserve recognizable words as written; do not abbreviate them or invent context. Use 3 to 6 lowercase words joined by hyphens. Return only the filename words, with no extension or explanation.\n\(recognizedText)",
                "stream": false
            ])
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            URLSession.shared.dataTask(with: urlRequest) { data, _, _ in
                let modelResponse = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .flatMap { $0["response"] as? String }
                let name = modelResponse.map(slug(from:)) ?? fallbackName
                DispatchQueue.main.async { completion(name) }
            }.resume()
        }
    }

    private static func slug(from text: String) -> String? {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}