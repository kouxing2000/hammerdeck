import SwiftUI

/// A simple flow layout: places its subviews left-to-right and wraps to a new
/// row when the next subview would overflow the proposed width. Each row is
/// left-aligned and its items are vertically centered within the row's height.
///
/// macOS 13+ (the SwiftUI `Layout` protocol). Net-new, reusable; the Rules
/// editor's token sentence (`AddRuleForm`) is the first caller -- a row of pill
/// tokens that wraps instead of forcing a wide pane. Mirrors the canonical
/// WWDC flow-layout shape; no caching (the token count is tiny).
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 6
    var vSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * vSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                // Center each pill within the row's line height so a taller pill
                // (e.g. one with a two-line value) doesn't shove the baseline.
                let yOffset = (row.height - item.size.height) / 2
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + yOffset),
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + hSpacing
            }
            y += row.height + vSpacing
        }
    }

    // MARK: - row packing

    private struct Item { let index: Int; let size: CGSize }
    private struct Row { var items: [Item] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.items.isEmpty ? size.width : current.width + hSpacing + size.width
            if projected > maxWidth && !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + hSpacing + size.width
            current.height = max(current.height, size.height)
            current.items.append(Item(index: index, size: size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
