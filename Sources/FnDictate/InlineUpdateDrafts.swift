import Foundation

/// Only ownership and an unsaved flag leave a view; draft text and keys never do.
/// A synchronous snapshot also protects the final application termination check.
final class InlineUpdateDrafts {
    static let shared = InlineUpdateDrafts()
    static let didChange = Notification.Name("fnDictateInlineDraftsChanged")

    private let lock = NSLock()
    private var owners = Set<UUID>()
    private let notifications: NotificationCenter

    init(notifications: NotificationCenter = .default) { self.notifications = notifications }

    var hasUnsavedChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !owners.isEmpty
    }

    fileprivate func setUnsaved(_ unsaved: Bool, owner: UUID) {
        lock.lock()
        let wasBusy = !owners.isEmpty
        if unsaved { owners.insert(owner) } else { owners.remove(owner) }
        let changed = wasBusy != !owners.isEmpty
        lock.unlock()
        if changed { notifications.post(name: Self.didChange, object: self) }
    }
}

/// Keep this token in SwiftUI State: window hiding keeps its protection, while
/// saving clears the flag and destroying the view releases only its own entry.
final class InlineUpdateDraft {
    private let owner = UUID()
    private let drafts: InlineUpdateDrafts

    init(drafts: InlineUpdateDrafts = .shared) { self.drafts = drafts }
    func setUnsaved(_ unsaved: Bool) { drafts.setUnsaved(unsaved, owner: owner) }
    deinit { drafts.setUnsaved(false, owner: owner) }
}
