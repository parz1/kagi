import AppKit
import Foundation

/// All production callbacks run on the main queue. Hold only clipboard ownership,
/// never another cached copy of the secret. Normal quit also releases the lease.
final class ClipboardLease: @unchecked Sendable {
  private let generation: Int
  private let currentGeneration: () -> Int
  private let erase: () -> Void
  private var observer: NSObjectProtocol?
  init(generation: Int, currentGeneration: @escaping () -> Int, erase: @escaping () -> Void,
    observeTermination: Bool = true) {
    self.generation = generation
    self.currentGeneration = currentGeneration
    self.erase = erase
    if observeTermination {
      observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
        object: nil, queue: .main) { [weak self] _ in self?.clear() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.clear() }
  }
  func clear() {
    if currentGeneration() == generation { erase() }
    if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
  }
}
