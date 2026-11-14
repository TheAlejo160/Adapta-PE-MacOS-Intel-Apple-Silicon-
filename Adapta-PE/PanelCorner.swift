import Foundation
import CoreGraphics

enum PanelCorner: String, CaseIterable {
    case upperLeft, upperRight, lowerLeft, lowerRight
    var title: String {
        switch self {
        case .upperLeft: return Textos.t("panel.superiorIzquierda")
        case .upperRight: return Textos.t("panel.superiorDerecha")
        case .lowerLeft: return Textos.t("panel.inferiorIzquierda")
        case .lowerRight: return Textos.t("panel.inferiorDerecha")
        }
    }
    func frame(size: CGSize, visible screen: CGRect, free: CGPoint? = nil, reservedHeight: CGFloat = 0) -> CGRect {
        let visible = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: max(1, screen.height - reservedHeight))
        let margin: CGFloat = 16
        let width = min(size.width, max(1, visible.width - margin * 2))
        let height = min(size.height, max(1, visible.height - margin * 2))
        let left = self == .upperLeft || self == .lowerLeft
        let upper = self == .upperLeft || self == .upperRight
        if let free {
            let x = free.x.isFinite ? min(1, max(0, free.x)) : 0.5
            let y = free.y.isFinite ? min(1, max(0, free.y)) : 0.5
            return CGRect(x: visible.minX + x * max(0, visible.width - width), y: visible.minY + y * max(0, visible.height - height), width: width, height: height)
        }
        return CGRect(x: left ? visible.minX + margin : visible.maxX - margin - width,
                      y: upper ? visible.maxY - margin - height : visible.minY + margin,
                      width: width, height: height)
    }
}
