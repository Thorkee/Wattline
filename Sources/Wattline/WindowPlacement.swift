import Foundation

enum WindowPlacement {
    enum Anchor { case topTrailing, center }

    static func frame(size: CGSize, in area: CGRect, anchor: Anchor) -> CGRect {
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)
        let spaceX = area.width - width
        let spaceY = area.height - height
        switch anchor {
        case .topTrailing:
            return CGRect(x: area.maxX - width - min(12, spaceX), y: area.maxY - height - min(6, spaceY),
                          width: width, height: height)
        case .center:
            return CGRect(x: area.minX + spaceX / 2, y: area.minY + spaceY / 2, width: width, height: height)
        }
    }
}
