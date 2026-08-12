import Foundation

enum DesktopMultiSelection {
    static func range<ID: Hashable>(
        from anchor: ID?,
        through target: ID,
        in orderedIDs: [ID]
    ) -> Set<ID> {
        guard let anchor,
              let anchorIndex = orderedIDs.firstIndex(of: anchor),
              let targetIndex = orderedIDs.firstIndex(of: target)
        else { return [target] }

        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        return Set(orderedIDs[bounds])
    }
}
