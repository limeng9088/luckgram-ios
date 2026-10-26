import Foundation

/// Pure geometry and rules of "send gallery video as round video" (spec 03). Foundation only, so it
/// is unit tested on Linux too (`.github/workflows/luckgram-unit-tests.yml`) and on the simulator
/// (`//submodules/TelegramUI/Components/LuckgramRoundVideo:LuckgramRoundVideoTests`).
public enum LuckgramRoundVideoGeometry {
    public static let maxDuration: Double = 60.0
    public static let maxZoom: Double = 4.0
    /// Same ceiling as Telegram's own video message export.
    public static let maxOutputSide: Double = 480.0
    public static let minOutputSide: Int = 240

    public struct Rect: Equatable {
        public var x: Double
        public var y: Double
        public var side: Double

        public init(x: Double, y: Double, side: Double) {
            self.x = x
            self.y = y
            self.side = side
        }
    }

    /// Whether the option is offered for the current selection.
    public static func canOffer(enabled: Bool, selectedCount: Int, isVideo: Bool, hasPrice: Bool) -> Bool {
        return enabled && selectedCount == 1 && isVideo && !hasPrice
    }

    /// Display size of a track whose natural size is mapped by `rotationDegrees`.
    public static func displaySize(width: Double, height: Double, rotationDegrees: Int) -> (width: Double, height: Double) {
        let r = ((rotationDegrees % 360) + 360) % 360
        return r == 90 || r == 270 ? (height, width) : (width, height)
    }

    /// Even output side, never upscaled beyond the crop, clamped to 240...480.
    public static func outputSide(cropSide: Double) -> Int {
        var side = Int(min(maxOutputSide, cropSide).rounded(.down))
        side = max(minOutputSide, side - side % 2)
        return side
    }

    public static func videoBitrate(outputSide: Int) -> Int {
        return outputSide <= 400 ? 1000 * 1000 : 1200 * 1000
    }

    // MARK: time range

    public static func needsRange(duration: Double) -> Bool {
        return duration > maxDuration + 0.05
    }

    public static func initialRange(duration: Double) -> (start: Double, end: Double) {
        return (0.0, min(max(0.0, duration), maxDuration))
    }

    /// The range a drag produces: inside the video, at least `minLength`, at most 60 s.
    public enum DragMode {
        case left
        case right
        case window
    }

    public static func dragRange(mode: DragMode, start: Double, end: Double, delta: Double, duration: Double, minLength: Double) -> (start: Double, end: Double) {
        var start = start
        var end = end
        switch mode {
        case .left:
            start = max(0.0, min(end - minLength, start + delta))
            if end - start > maxDuration {
                start = end - maxDuration
            }
        case .right:
            end = min(duration, max(start + minLength, end + delta))
            if end - start > maxDuration {
                end = start + maxDuration
            }
        case .window:
            let length = end - start
            start = max(0.0, min(duration - length, start + delta))
            end = start + length
        }
        return (start, end)
    }

    /// Final export range, capped at 60 s.
    public static func exportRange(start: Double, end: Double) -> (start: Double, end: Double) {
        return (start, min(end, start + maxDuration))
    }

    // MARK: viewfinder

    public static func baseScale(circleDiameter: Double, width: Double, height: Double) -> Double {
        return circleDiameter / min(width, height)
    }

    public static func clampZoom(_ zoom: Double) -> Double {
        return max(1.0, min(maxZoom, zoom))
    }

    /// Clamps the drag offset so the video always covers the circle (no black edges).
    public static func clampOffset(width: Double, height: Double, baseScale: Double, zoom: Double, circleDiameter: Double, x: Double, y: Double) -> (x: Double, y: Double) {
        let maxX = max(0.0, (width * baseScale * zoom - circleDiameter) / 2.0)
        let maxY = max(0.0, (height * baseScale * zoom - circleDiameter) / 2.0)
        return (max(-maxX, min(maxX, x)), max(-maxY, min(maxY, y)))
    }

    /// Square of the display-oriented source under the circle, in source pixels.
    public static func cropSquare(width: Double, height: Double, baseScale: Double, zoom: Double, circleDiameter: Double, offsetX: Double, offsetY: Double) -> Rect {
        let scale = baseScale * zoom
        let side = min(circleDiameter / scale, min(width, height))
        var x = (width * scale / 2.0 - offsetX - circleDiameter / 2.0) / scale
        var y = (height * scale / 2.0 - offsetY - circleDiameter / 2.0) / scale
        x = max(0.0, min(width - side, x))
        y = max(0.0, min(height - side, y))
        return Rect(x: x, y: y, side: side)
    }
}
