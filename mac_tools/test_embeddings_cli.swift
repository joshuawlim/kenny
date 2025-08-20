#!/usr/bin/env swift

import Foundation

func printJSON<T: Codable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = []
    if let data = try? encoder.encode(value),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }
}

struct EmbeddingResult: Codable {
    let model: String
    let text: String
    let dimensions: Int
    let generation_time_ms: Int
    let first_5_values: [Double]
}

guard CommandLine.arguments.count > 1 else {
    print("Usage: ./test_embeddings_cli.swift \"text to embed\"")
    exit(1)
}

let inputText = CommandLine.arguments[1]

print("Generating embedding for: \(inputText)")

let url = URL(string: "http://localhost:11434/api/embeddings")!
var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")

let payload: [String: Any] = [
    "model": "nomic-embed-text",
    "prompt": inputText
]

do {
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    
    let startTime = Date()
    
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        
        if let error = error {
            print("Error: \(error)")
            exit(1)
        }
        
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [Double] else {
            print("Failed to parse embedding response")
            exit(1)
        }
        
        let result = EmbeddingResult(
            model: "nomic-embed-text",
            text: inputText,
            dimensions: embedding.count,
            generation_time_ms: duration,
            first_5_values: Array(embedding.prefix(5))
        )
        
        printJSON(result)
        exit(0)
    }
    
    task.resume()
    RunLoop.main.run()
    
} catch {
    print("Failed to create request: \(error)")
    exit(1)
}