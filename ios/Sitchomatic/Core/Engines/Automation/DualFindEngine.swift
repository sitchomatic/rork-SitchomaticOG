import Foundation
import os

// MARK: - DualFind Engine (DiscardingTaskGroup DOM Search)

/// High-performance DOM search engine that uses `DiscardingTaskGroup` to find
/// login fields, buttons, and patterns across chunked HTML content.
///
/// Key Swift 6.2 patterns:
/// - `withThrowingDiscardingTaskGroup`: Fire-and-forget task completion that
///   immediately frees memory after each chunk is processed, preventing
///   accumulation during thousand-node DOM scans.
/// - `OSAllocatedUnfairLock`: Lock-protected result aggregation without
///   actor `await` overhead — nanosecond-safe writes from concurrent tasks.
///
/// Replaces the old `DualFindViewModel` DOM parsing logic with a dedicated
/// engine that can be called from any actor isolation context.
public struct DualFindEngine: Sendable {

    /// Size of each DOM chunk for parallel processing (characters).
    private let chunkSize: Int

    public init(chunkSize: Int = 5000) {
        self.chunkSize = chunkSize
    }

    // MARK: - Matrix Search

    /// Performs a parallel search across chunked DOM content for matching criteria.
    ///
    /// The DOM is split into fixed-size chunks that are searched concurrently.
    /// `DiscardingTaskGroup` ensures each completed chunk's task memory is
    /// freed immediately — critical when scanning 100KB+ page sources.
    ///
    /// - Parameters:
    ///   - criteria: CSS selectors, IDs, or text patterns to search for
    ///   - targetDOM: The full HTML source to search within
    /// - Returns: All matching patterns found in the DOM
    public func performMatrixSearch(
        criteria: [String],
        targetDOM: String
    ) async throws -> [String] {
        guard !criteria.isEmpty, !targetDOM.isEmpty else { return [] }

        let domChunks = chunkString(targetDOM, size: chunkSize)
        let resultsLock = OSAllocatedUnfairLock(initialState: [String]())

        // DiscardingTaskGroup: Each chunk search is fire-and-forget.
        // Once a chunk is scanned, its task memory is instantly reclaimed.
        try await withThrowingDiscardingTaskGroup { group in
            for chunk in domChunks {
                group.addTask {
                    try Task.checkCancellation()

                    let matches = self.searchChunk(chunk: chunk, criteria: criteria)

                    if !matches.isEmpty {
                        // UnfairLock provides nanosecond-safe writes without actor await
                        resultsLock.withLock { buffer in
                            buffer.append(contentsOf: matches)
                        }
                    }
                }
            }
        }

        // Deduplicate results while preserving order
        return resultsLock.withLock { results in
            var seen = Set<String>()
            return results.filter { seen.insert($0).inserted }
        }
    }

    // MARK: - Login Field Detection

    /// Searches the DOM for common login form selectors and patterns.
    /// Returns a prioritized list of found login field identifiers.
    public func findLoginFields(in dom: String) async throws -> LoginFieldResult {
        let emailSelectors = [
            "#email", "#login-email", "#username", "#user_login",
            "input[type='email']", "input[name='email']",
            "input[name='username']", "input[name='login']",
            "[autocomplete='email']", "[autocomplete='username']"
        ]

        let passwordSelectors = [
            "#password", "#login-password", "#pass", "#user_pass",
            "input[type='password']", "input[name='password']",
            "[autocomplete='current-password']"
        ]

        let submitSelectors = [
            "#login-submit", "#submit", "button[type='submit']",
            "input[type='submit']", ".login-button", ".btn-login",
            "[data-testid='login-button']"
        ]

        async let emailMatches = performMatrixSearch(criteria: emailSelectors, targetDOM: dom)
        async let passwordMatches = performMatrixSearch(criteria: passwordSelectors, targetDOM: dom)
        async let submitMatches = performMatrixSearch(criteria: submitSelectors, targetDOM: dom)

        return try await LoginFieldResult(
            emailFields: emailMatches,
            passwordFields: passwordMatches,
            submitButtons: submitMatches
        )
    }

    // MARK: - Pattern Matching

    /// Searches a single DOM chunk for matching criteria.
    /// CPU-bound operation suitable for concurrent execution.
    private func searchChunk(chunk: String, criteria: [String]) -> [String] {
        let lowercasedChunk = chunk.lowercased()
        return criteria.filter { criterion in
            // Strip CSS selector syntax for content matching
            let searchTerm = criterion
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "input[", with: "")
                .replacingOccurrences(of: "button[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .replacingOccurrences(of: "'", with: "")
                .lowercased()

            // Check for the criterion in attribute values, IDs, names, and classes
            return lowercasedChunk.contains("id=\"\(searchTerm)\"")
                || lowercasedChunk.contains("name=\"\(searchTerm)\"")
                || lowercasedChunk.contains("class=\"\(searchTerm)")
                || lowercasedChunk.contains(searchTerm)
        }
    }

    // MARK: - String Chunking

    /// Splits a string into fixed-size chunks for parallel processing.
    /// Uses String.Index arithmetic to avoid unnecessary copies.
    private func chunkString(_ string: String, size: Int) -> [String] {
        guard !string.isEmpty, size > 0 else { return [] }

        var chunks: [String] = []
        var currentIndex = string.startIndex

        while currentIndex < string.endIndex {
            let endIndex = string.index(
                currentIndex,
                offsetBy: size,
                limitedBy: string.endIndex
            ) ?? string.endIndex

            chunks.append(String(string[currentIndex..<endIndex]))
            currentIndex = endIndex
        }

        return chunks
    }
}

// MARK: - Supporting Types

/// Result of a login field search across the DOM.
public struct LoginFieldResult: Sendable {
    public let emailFields: [String]
    public let passwordFields: [String]
    public let submitButtons: [String]

    /// Whether the DOM appears to contain a login form.
    public var hasLoginForm: Bool {
        !emailFields.isEmpty && !passwordFields.isEmpty
    }

    /// The best email field selector found.
    public var bestEmailSelector: String? { emailFields.first }

    /// The best password field selector found.
    public var bestPasswordSelector: String? { passwordFields.first }

    /// The best submit button selector found.
    public var bestSubmitSelector: String? { submitButtons.first }
}
