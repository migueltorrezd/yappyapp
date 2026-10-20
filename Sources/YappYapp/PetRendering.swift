import SwiftUI

enum PetPreviewAnimationPolicy {
    static let interval: TimeInterval = 0.28

    static func frame(at date: Date, reduceMotion: Bool) -> PetFrame {
        guard !reduceMotion else { return .walkA }
        let index = Int(date.timeIntervalSinceReferenceDate / interval)
        return index.isMultiple(of: 2) ? .walkA : .walkB
    }
}

/// Animated walk-cycle preview for the Pet tab.
struct AnimatedPetPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: PetKind
    var pixel: CGFloat = 5
    var accessory: PetAccessory = .none
    var reduceMotionOverride: Bool? = nil

    private var shouldReduceMotion: Bool {
        reduceMotionOverride ?? reduceMotion
    }

    var body: some View {
        if let sprite = petSprite(for: kind) {
            // WARDROBE-WINS: mirror the live pet; the equipped accessory beats
            // the festive calendar so the Pet tab reflects what was just put on.
            let hat = accessory.hat ?? PetView.seasonalHat(for: Date())

            if shouldReduceMotion {
                preview(
                    sprite: sprite,
                    hat: hat,
                    frame: PetPreviewAnimationPolicy.frame(at: .distantPast, reduceMotion: true)
                )
            } else {
                TimelineView(.periodic(from: .now, by: PetPreviewAnimationPolicy.interval)) { context in
                    preview(
                        sprite: sprite,
                        hat: hat,
                        frame: PetPreviewAnimationPolicy.frame(at: context.date, reduceMotion: false)
                    )
                }
            }
        }
    }

    private func preview(sprite: PetSprite, hat: PetHat?, frame: PetFrame) -> some View {
        ZStack(alignment: .topLeading) {
            PixelSpriteCanvas(
                grid: sprite.grid(for: frame),
                palette: sprite.palette,
                pixel: pixel,
                mirrored: false
            )

            if let hat {
                let bottom = hat.bottomRow(anchorRow: sprite.hatAnchor.row, sink: sprite.hatSink)
                    + sprite.hatFrameShift(for: frame)
                PixelSpriteCanvas(
                    grid: hat.grid,
                    palette: hatColors,
                    pixel: pixel,
                    mirrored: false
                )
                .offset(
                    x: CGFloat(sprite.hatAnchor.column) * pixel,
                    y: CGFloat(bottom - hat.grid.count + 1) * pixel
                )
            }
        }
    }
}

/// Small static thumbnail for pet pickers and leaderboards. Locked pets show
/// as silhouettes; unhatched pets show as the egg.
struct PetThumb: View {
    let kind: PetKind
    var pixel: CGFloat = 1.6
    var silhouette = false
    var asEgg = false

    var body: some View {
        if let sprite = asEgg ? .some(eggSprite) : petSprite(for: kind) {
            let palette = silhouette
                ? sprite.palette.mapValues { _ in Color(red: 0.10, green: 0.09, blue: 0.07).opacity(0.7) }
                : sprite.palette

            PixelSpriteCanvas(
                grid: sprite.walkA,
                palette: palette,
                pixel: pixel,
                mirrored: false
            )
        }
    }
}

struct PixelSpriteCanvas: View {
    let grid: [[Character]]
    let palette: [Character: Color]
    let pixel: CGFloat
    let mirrored: Bool

    var body: some View {
        Canvas { context, _ in
            let width = grid.first?.count ?? 0

            for (y, row) in grid.enumerated() {
                for (x, character) in row.enumerated() {
                    guard let color = palette[character] else { continue }

                    let drawX = mirrored ? width - 1 - x : x
                    let rect = CGRect(
                        x: CGFloat(drawX) * pixel,
                        y: CGFloat(y) * pixel,
                        width: pixel,
                        height: pixel
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(
            width: CGFloat(grid.first?.count ?? 0) * pixel,
            height: CGFloat(grid.count) * pixel
        )
    }
}
