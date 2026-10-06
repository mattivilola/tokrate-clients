import Foundation

/// A set that forgets its oldest members past a limit, so per-database bookkeeping cannot grow forever.
struct BoundedSet<Element: Hashable> {
    private let limit: Int
    private var members: Set<Element> = []
    private var order: [Element] = []
    private var oldest = 0

    init(limit: Int) { self.limit = limit }

    func contains(_ element: Element) -> Bool { members.contains(element) }

    /// Adds the element; `false` when it was already a member.
    @discardableResult
    mutating func insert(_ element: Element) -> Bool {
        guard members.insert(element).inserted else { return false }
        order.append(element)
        if members.count > limit {
            members.remove(order[oldest])
            oldest += 1
            // Compact the consumed prefix once it dominates the array.
            if oldest > limit { order.removeFirst(oldest); oldest = 0 }
        }
        return true
    }
}
