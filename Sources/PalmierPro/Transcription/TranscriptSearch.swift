import Foundation

/// Exact keyword search over cached transcripts
enum TranscriptSearch {
    struct Hit: Equatable, Identifiable {
        let assetID: String
        let start: Double
        let end: Double
        let text: String

        var id: String { "\(assetID):\(start)" }
    }

    static func search(query: String, assets: [(id: String, url: URL)], limit: Int = 20) async -> [Hit] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return [] }

        return await Task.detached(priority: .userInitiated) {
            var hits: [Hit] = []
            for asset in assets {
                guard !Task.isCancelled else { return [] }
                guard let transcript = TranscriptCache.cachedOnDisk(for: asset.url) else { continue }
                for segment in transcript.segments where matches(segment.text, terms: terms) {
                    hits.append(Hit(assetID: asset.id, start: segment.start, end: segment.end, text: segment.text))
                    if hits.count >= limit { return hits }
                }
            }
            return hits
        }.value
    }

    /// Query split into words, edge punctuation stripped (so "budget," → "budget").
    static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    static func matches(_ text: String, terms: [String]) -> Bool {
        terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
