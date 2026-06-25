import Foundation

@MainActor
@Observable
final class SampleProjectService {
    static let shared = SampleProjectService()

    struct Summary: Identifiable, Sendable {
        let slug: String
        let title: String
        let posterUrl: String?
        var id: String { slug }
    }

    func fetchSamples() async throws -> [Summary] { [] }

    func cachedURL(slug: String) -> URL? { nil }

    func materialize(slug: String, onProgress: (Double) -> Void) async throws -> URL {
        throw SampleError.notConfigured
    }

    enum SampleError: LocalizedError {
        case notConfigured
        var errorDescription: String? { "Samples not available in this build." }
    }
}
