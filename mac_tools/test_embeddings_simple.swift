#!/usr/bin/env swift

import Foundation

print("Testing embeddings functionality...")

// Test embedding generation
let url = URL(string: "http://localhost:11434/api/embeddings")!
var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")

let payload: [String: Any] = [
    "model": "nomic-embed-text",
    "prompt": "Hello world, this is a test embedding"
]

do {
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            print("❌ Error: \(error)")
            exit(1)
        }
        
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [Double] else {
            print("❌ Failed to parse embedding response")
            if let data = data {
                print("Raw response: \(String(data: data, encoding: .utf8) ?? "nil")")
            }
            exit(1)
        }
        
        print("✅ Generated embedding with \(embedding.count) dimensions")
        print("First 5 values: \(Array(embedding.prefix(5)))")
        
        // Test similarity calculation
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        let c: [Float] = [1.0, 0.0, 0.0]
        
        func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
            let dotProduct = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
            let magnitudeA = sqrt(a.reduce(0) { $0 + $1 * $1 })
            let magnitudeB = sqrt(b.reduce(0) { $0 + $1 * $1 })
            return dotProduct / (magnitudeA * magnitudeB)
        }
        
        let simAB = cosineSimilarity(a, b)  // Should be ~0
        let simAC = cosineSimilarity(a, c)  // Should be ~1
        
        print("✅ Similarity tests:")
        print("  sim([1,0,0], [0,1,0]) = \(simAB) (expected ~0)")
        print("  sim([1,0,0], [1,0,0]) = \(simAC) (expected ~1)")
        
        exit(0)
    }
    
    task.resume()
    
    // Keep the script running until completion
    RunLoop.main.run()
    
} catch {
    print("❌ Failed to create request: \(error)")
    exit(1)
}