// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mac_tools",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "mac_tools", targets: ["mac_tools"]),
        .executable(name: "db_cli", targets: ["DatabaseCLI"]),
        .executable(name: "orchestrator_cli", targets: ["OrchestratorCLI"]),
        .executable(name: "assistant_core", targets: ["AssistantCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "mac_tools",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/mac_tools"
        ),
        .executableTarget(
            name: "DatabaseCLI", 
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "DatabaseCore"
            ],
            path: "src",
            sources: ["DatabaseCLI.swift"]
        ),
        .target(
            name: "DatabaseCore",
            dependencies: [],
            path: "src",
            sources: [
                "Utilities.swift",
                "Database.swift",
                "IngestManager.swift", 
                "MailIngester.swift",
                "NotesIngester.swift",
                "MessagesIngester.swift",
                "WhatsAppIngester.swift",
                "FilesIngester.swift",
                "Orchestrator.swift",
                "EmbeddingsService.swift",
                "EmbeddingIngester.swift",
                "HybridSearch.swift",
                "AssistantCore.swift",
                "LLMService.swift", 
                "ToolRegistry.swift",
                "TestAssistantCore.swift",
                "PerformanceMonitor.swift",
                "CacheManager.swift",
                "ConfigurationManager.swift",
                "ErrorHandler.swift",
                "BackgroundProcessor.swift",
                "PlanManager.swift",
                "AuditLogger.swift",
                "CompensationManager.swift",
                "CLISafety.swift"
            ]
        ),
        .executableTarget(
            name: "OrchestratorCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "DatabaseCore"
            ],
            path: "src",
            sources: ["OrchestratorCLI.swift"]
        ),
        .executableTarget(
            name: "AssistantCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "DatabaseCore"
            ],
            path: "src",
            sources: ["AssistantCLI.swift"]
        )
    ]
)