//
//  RAGService.swift
//  Samantha
//
//  Created by 鯨井優一 on 2026/04/09.
//

import Foundation

struct RAGService {
    private static let openAIKey: String = Bundle.main.infoDictionary?["OPENAI_API_KEY"] as? String ?? ""
    private static let embeddingEndpoint = URL(string: "https://api.openai.com/v1/embeddings")!
    private static let embeddingModel = "text-embedding-3-small"
    private static let requestTimeout: TimeInterval = 15
    /// Minimum cosine similarity to consider a document relevant.
    private static let relevanceThreshold: Double = 0.4

    /// A blog article chunk with its precomputed embedding vector.
    struct Document {
        let filename: String
        let text: String
        var embedding: [Double] = []
    }

    // MARK: - Cache

    private static var cachedDocuments: [Document]?

    // MARK: - Public API

    /// Search BlogData for the top-k documents most relevant to `query`.
    /// Always returns up to topK results regardless of score.
    static func search(query: String, topK: Int = 3) async throws -> [Document] {
        let documents = try await loadDocuments()
        guard !documents.isEmpty else {
            print("[RAG] No documents loaded — skipping search")
            return []
        }

        let queryVector = try await embed(text: query)

        // Rank by cosine similarity — only include docs above relevance threshold
        let ranked = documents
            .map { doc in (doc: doc, score: cosineSimilarity(queryVector, doc.embedding)) }
            .sorted { $0.score > $1.score }
            .prefix(topK)

        for (i, item) in ranked.enumerated() {
            print("[RAG] #\(i + 1) score=\(String(format: "%.4f", item.score)) file=\(item.doc.filename)")
        }

        // Filter out low-relevance docs to avoid bloating context for unrelated queries
        let relevant = ranked.filter { $0.score >= relevanceThreshold }
        if relevant.count < ranked.count {
            print("[RAG] Filtered to \(relevant.count) doc(s) above threshold \(relevanceThreshold)")
        }

        return relevant.map(\.doc)
    }

    // MARK: - Document Loading

    private static func loadDocuments() async throws -> [Document] {
        if let cached = cachedDocuments { return cached }

        let mdFiles = findMarkdownFiles()
        print("[RAG] Found \(mdFiles.count) markdown file(s) in bundle")

        var docs: [Document] = []
        for file in mdFiles {
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                let truncated = String(text.prefix(8000))
                let vector = try await embed(text: truncated)
                let doc = Document(filename: file.lastPathComponent, text: text, embedding: vector)
                docs.append(doc)
                print("[RAG] Embedded: \(file.lastPathComponent) (\(text.count) chars)")
            } catch {
                print("[RAG] Failed to load \(file.lastPathComponent): \(error)")
            }
        }

        print("[RAG] Total documents embedded: \(docs.count)")
        cachedDocuments = docs
        return docs
    }

    /// Try multiple strategies to locate .md/.txt files in the app bundle.
    private static func findMarkdownFiles() -> [URL] {
        // Strategy 1: Look for BlogData subdirectory
        if let urls = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: "BlogData"), !urls.isEmpty {
            print("[RAG] Strategy 1 (subdirectory 'BlogData'): found \(urls.count) .md files")
            let txt = Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: "BlogData") ?? []
            return urls + txt
        }

        // Strategy 2: url(forResource:) for the folder
        if let folderURL = Bundle.main.url(forResource: "BlogData", withExtension: nil) {
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) {
                let filtered = files.filter { ["md", "txt"].contains($0.pathExtension.lowercased()) }
                if !filtered.isEmpty {
                    print("[RAG] Strategy 2 (folder reference): found \(filtered.count) files")
                    return filtered
                }
            }
        }

        // Strategy 3: Search entire bundle for all .md files
        if let urls = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: nil), !urls.isEmpty {
            print("[RAG] Strategy 3 (all .md in bundle root): found \(urls.count) files")
            let txt = Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: nil) ?? []
            return urls + txt
        }

        // Strategy 4: Walk the bundle Resources directory
        let resourcePath = Bundle.main.bundlePath + "/Contents/Resources"
        let fm = FileManager.default
        var found: [URL] = []
        if let enumerator = fm.enumerator(atPath: resourcePath) {
            while let path = enumerator.nextObject() as? String {
                let ext = (path as NSString).pathExtension.lowercased()
                if ext == "md" || ext == "txt" {
                    found.append(URL(fileURLWithPath: resourcePath + "/" + path))
                }
            }
        }
        if !found.isEmpty {
            print("[RAG] Strategy 4 (recursive walk): found \(found.count) files")
            return found
        }

        print("[RAG] WARNING: No markdown files found in bundle via any strategy")
        print("[RAG] Bundle path: \(Bundle.main.bundlePath)")
        return []
    }

    // MARK: - OpenAI Embedding

    private struct EmbeddingRequest: Encodable {
        let model: String
        let input: String
    }

    private struct EmbeddingResponse: Decodable {
        struct DataItem: Decodable {
            let embedding: [Double]
        }
        let data: [DataItem]
    }

    private static func embed(text: String) async throws -> [Double] {
        let body = EmbeddingRequest(model: embeddingModel, input: text)

        var request = URLRequest(url: embeddingEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8) ?? "unknown"
            throw RAGError.embeddingFailed(status: status, detail: detail)
        }

        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        guard let vector = decoded.data.first?.embedding else {
            throw RAGError.emptyEmbedding
        }
        return vector
    }

    // MARK: - Cosine Similarity

    private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in a.indices {
            dot   += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Errors

    enum RAGError: LocalizedError {
        case embeddingFailed(status: Int, detail: String)
        case emptyEmbedding

        var errorDescription: String? {
            switch self {
            case .embeddingFailed(let status, let detail):
                return "Embedding API error (\(status)): \(detail)"
            case .emptyEmbedding:
                return "Empty embedding returned"
            }
        }
    }
}
