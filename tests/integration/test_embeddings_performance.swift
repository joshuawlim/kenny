#!/usr/bin/env swift

import Foundation

let testTexts = [
    "Short text for testing embedding generation speed",
    "A medium length text that contains more words and should take slightly longer to process through the embedding model",
    """
    A much longer text that represents a typical document chunk. This text contains multiple sentences
    and paragraphs that would be commonly found in emails, notes, or documents. The embedding model
    needs to process all of this content and generate a vector representation that captures the
    semantic meaning of the entire text block. This is representative of real-world usage patterns.
    """,
    "Another short query",
    "Meeting with team about project roadmap and deliverables for Q1 2024"
]

struct PerformanceResult: Codable {
    let text_length: Int
    let generation_time_ms: Int
    let dimensions: Int
}

struct BenchmarkSummary: Codable {
    let model: String
    let total_texts: Int
    let total_time_ms: Int
    let average_time_ms: Int
    let p50_ms: Int
    let p95_ms: Int
    let results: [PerformanceResult]
}

func testEmbeddingPerformance() async throws {
    print("Testing embedding generation performance...")
    print("=========================================")
    
    var results: [PerformanceResult] = []
    var times: [Int] = []
    let model = "nomic-embed-text"
    
    for (index, text) in testTexts.enumerated() {
        print("Test \(index + 1)/\(testTexts.count): \(text.prefix(50))...")
        
        let startTime = Date()
        
        let url = URL(string: "http://localhost:11434/api/embeddings")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "model": model,
            "prompt": text
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            print("Failed to generate embedding")
            continue
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let embedding = json?["embedding"] as? [Double] else {
            print("Invalid response format")
            continue
        }
        
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        
        results.append(PerformanceResult(
            text_length: text.count,
            generation_time_ms: duration,
            dimensions: embedding.count
        ))
        times.append(duration)
        
        print("  ✓ Generated \(embedding.count)-dim embedding in \(duration)ms")
    }
    
    times.sort()
    let p50 = times[times.count / 2]
    let p95 = times[Int(Double(times.count) * 0.95)]
    let totalTime = times.reduce(0, +)
    let avgTime = totalTime / times.count
    
    let summary = BenchmarkSummary(
        model: model,
        total_texts: testTexts.count,
        total_time_ms: totalTime,
        average_time_ms: avgTime,
        p50_ms: p50,
        p95_ms: p95,
        results: results
    )
    
    print("\nBenchmark Summary:")
    print("==================")
    print("Model: \(model)")
    print("Total texts: \(testTexts.count)")
    print("Average time: \(avgTime)ms")
    print("P50: \(p50)ms")
    print("P95: \(p95)ms")
    print("Total time: \(totalTime)ms")
    
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    if let jsonData = try? encoder.encode(summary),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        print("\nJSON Output:")
        print(jsonString)
    }
    
    print("\n✅ Performance target check:")
    if avgTime <= 100 {
        print("  PASS: Average embedding generation (\(avgTime)ms) is under 100ms target")
    } else {
        print("  WARN: Average embedding generation (\(avgTime)ms) exceeds 100ms target")
    }
}

Task {
    do {
        try await testEmbeddingPerformance()
    } catch {
        print("Error: \(error)")
        exit(1)
    }
    exit(0)
}

RunLoop.main.run()