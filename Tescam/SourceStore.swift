import Foundation

/// Owns the URLs the user picked as inputs, the security-scoped access lifecycle,
/// and the persisted bookmarks so the same picks survive across launches.
///
/// Carved out of `AppState` so the rest of the app talks to source-folder
/// concerns through a small interface and can be unit-tested with a stand-in
/// `UserDefaults` / `FileManager`.
final class SourceStore {
  /// `UserDefaults` key holding `[Data]` of the bookmark blobs for the last
  /// successful set of input folders. Public so test doubles can target it.
  static let defaultBookmarkKey = "Tescam.lastSourceBookmarks"

  private let bookmarkKey: String
  private let userDefaults: UserDefaults
  private let fileExists: (String) -> Bool
  private let bookmarkCreationOptions: URL.BookmarkCreationOptions
  private let bookmarkResolutionOptions: URL.BookmarkResolutionOptions
  private let startSecurityScopedAccess: (URL) -> Bool
  private let stopSecurityScopedAccess: (URL) -> Void
  private var activeSecurityScopedURLs: [URL] = []

  init(
    bookmarkKey: String = SourceStore.defaultBookmarkKey,
    userDefaults: UserDefaults = .standard,
    fileManager: FileManager = .default,
    bookmarkCreationOptions: URL.BookmarkCreationOptions = PlatformFileAccess.bookmarkCreationOptions,
    bookmarkResolutionOptions: URL.BookmarkResolutionOptions = PlatformFileAccess.bookmarkResolutionOptions,
    fileExists: ((String) -> Bool)? = nil,
    startSecurityScopedAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
    stopSecurityScopedAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
  ) {
    self.bookmarkKey = bookmarkKey
    self.userDefaults = userDefaults
    self.fileExists = fileExists ?? { fileManager.fileExists(atPath: $0) }
    self.bookmarkCreationOptions = bookmarkCreationOptions
    self.bookmarkResolutionOptions = bookmarkResolutionOptions
    self.startSecurityScopedAccess = startSecurityScopedAccess
    self.stopSecurityScopedAccess = stopSecurityScopedAccess
  }

  /// Standardizes paths, drops missing entries, and de-duplicates while preserving order.
  func normalize(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    var out: [URL] = []
    out.reserveCapacity(urls.count)
    for raw in urls {
      let u = raw.standardizedFileURL
      guard withSecurityScopedAccess(for: u, { fileExists(u.path) }) else { continue }
      if seen.insert(u.path).inserted {
        out.append(u)
      }
    }
    return out
  }

  /// Persists security-scoped bookmarks for the supplied URLs so they can be
  /// re-resolved on the next launch.
  func rememberBookmarks(for urls: [URL]) {
    let bookmarks = urls.compactMap { url -> Data? in
      try? url.bookmarkData(
        options: bookmarkCreationOptions,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    }
    userDefaults.set(bookmarks, forKey: bookmarkKey)
  }

  /// Resolves the persisted bookmarks. Stale bookmarks are refreshed in place,
  /// missing files are dropped, and the persisted blob is rewritten if any
  /// bookmark was refreshed. Returns the live URLs that survived resolution
  /// (empty if nothing usable persists).
  func restoreBookmarkedURLs() -> [URL] {
    guard
      let bookmarks = userDefaults.array(forKey: bookmarkKey) as? [Data],
      !bookmarks.isEmpty
    else {
      return []
    }

    var restored: [URL] = []
    var refreshedBookmarks: [Data] = []
    for bookmark in bookmarks {
      var stale = false
      guard
        let url = try? URL(
          resolvingBookmarkData: bookmark,
          options: bookmarkResolutionOptions,
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        )
      else {
        continue
      }
      // Existence must be probed with security-scoped access started: a
      // sandboxed folder bookmark can read as "missing" even when it is
      // present and reachable. (Plain, non-scoped bookmarks return false from
      // startAccessing and the probe still works.)
      let exists = withSecurityScopedAccess(for: url) { fileExists(url.path) }
      guard exists else {
        continue
      }
      restored.append(url)
      if stale,
         let refreshed = try? url.bookmarkData(
          options: PlatformFileAccess.bookmarkCreationOptions,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
         ) {
        refreshedBookmarks.append(refreshed)
      } else {
        refreshedBookmarks.append(bookmark)
      }
    }

    if !refreshedBookmarks.isEmpty, restored.count == refreshedBookmarks.count {
      userDefaults.set(refreshedBookmarks, forKey: bookmarkKey)
    }
    return restored
  }

  /// Starts security-scoped access for the supplied URLs and remembers which
  /// ones succeeded so they can be released later. Idempotent: any previously
  /// active scope is released first.
  func activateSecurityScope(for urls: [URL]) {
    deactivateSecurityScope()
    activeSecurityScopedURLs = urls.filter { startSecurityScopedAccess($0) }
  }

  /// Releases all currently held security-scoped access.
  func deactivateSecurityScope() {
    for url in activeSecurityScopedURLs {
      stopSecurityScopedAccess(url)
    }
    activeSecurityScopedURLs.removeAll()
  }

  private func withSecurityScopedAccess<T>(for url: URL, _ body: () -> T) -> T {
    let scoped = startSecurityScopedAccess(url)
    defer {
      if scoped {
        stopSecurityScopedAccess(url)
      }
    }
    return body()
  }
}
