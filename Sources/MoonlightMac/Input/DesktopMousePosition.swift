import Foundation

struct DesktopMousePosition: Equatable {
    let x: Int16, y: Int16, width: Int16, height: Int16
    static func map(point: CGPoint, bounds: CGRect, video: CGSize, flipped: Bool = false) -> Self? {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let point = CGPoint(x: point.x, y: flipped ? bounds.minY + bounds.maxY - point.y : point.y)
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        guard point.x >= rect.minX, point.x <= rect.maxX, point.y >= rect.minY, point.y <= rect.maxY else { return nil }
        let width = Int16(min(32767, video.width)), height = Int16(min(32767, video.height))
        return Self(x: Int16(min(Double(width - 1), max(0, (point.x - rect.minX) / rect.width * Double(width)))),
                    y: Int16(min(Double(height - 1), max(0, (rect.maxY - point.y) / rect.height * Double(height)))),
                    width: width, height: height)
    }
}
