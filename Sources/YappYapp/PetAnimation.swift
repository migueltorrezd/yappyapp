import SwiftUI

private struct PetParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var velocityX: CGFloat
    var velocityY: CGFloat
    let color: Color
    let born: Date
    let isHeart: Bool
}
private let heartGrid = parse("""
.h.h.
hhhhh
.hhh.
..h..
""")

private let zzzGrid = parse("""
zz..
.z..
..zz
""")

private let emotePalette: [Character: Color] = [
    "h": heartPink,
    "z": Color(red: 0.16, green: 0.35, blue: 1.0)
]

private let confettiPalette: [Color] = [
    Color(red: 1.0, green: 0.83, blue: 0.10),
    Color(red: 1.0, green: 0.29, blue: 0.16),
    Color(red: 0.16, green: 0.35, blue: 1.0),
    Color(red: 0.05, green: 0.65, blue: 0.40),
    heartPink
]

enum PetEmote: CaseIterable, Equatable, Hashable {
    case hop
    case spin
    case heart
    case zzz
    case wiggle

    static let stepInterval: TimeInterval = 0.12

    var duration: TimeInterval {
        switch self {
        case .hop: 1.05
        case .spin: 1.2
        case .heart: 1.3
        case .zzz: 1.45
        case .wiggle: 1.1
        }
    }

    var usesSleepFrame: Bool {
        self == .zzz
    }

    func step(startedAt: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt) / Self.stepInterval))
    }

    func horizontalOffset(step: Int, pixel: CGFloat) -> CGFloat {
        switch self {
        case .wiggle:
            return CGFloat([0, -2, 2, -2, 2, 0][step % 6]) * pixel
        case .spin:
            return CGFloat([0, 1, 0, -1][step % 4]) * pixel
        default:
            return 0
        }
    }

    func lift(step: Int, pixel: CGFloat) -> CGFloat {
        switch self {
        case .hop:
            return CGFloat([0, 4, 8, 4, 0, 3, 6, 3, 0][step % 9]) * pixel
        case .heart:
            return CGFloat([0, 1, 2, 1][step % 4]) * pixel
        default:
            return 0
        }
    }

    func mirrored(base: Bool, step: Int) -> Bool {
        switch self {
        case .spin:
            return step % 4 >= 2 ? !base : base
        case .wiggle:
            return step.isMultiple(of: 2) ? base : !base
        default:
            return base
        }
    }
}

private enum PetAnimationSchedule {
    case nextFrame
    case wake(at: Date)
    case dormant
}

private struct PetAnimationTaskID: Hashable {
    let kind: String
    let platformWidth: CGFloat?
    let isEggPhase: Bool
    let phase: String
    let lastSuccessAt: Date?
    let generation: Int
    let reduceMotion: Bool
}

struct PetView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: YappYappState
    let kind: PetKind
    var pixel: CGFloat = 2
    /// When set, the pet only walks on a platform of this width centered in
    /// the container (the pill or bar it stands on) instead of the full width.
    var platformWidth: CGFloat?
    /// Indicator at the top: the pet hangs upside down under the bar. The
    /// whole pet is mirrored vertically; hearts and Zzz are drawn so they
    /// still read the right way up.
    var hanging: Bool = false
    /// Indicator on the left or right: the pet sits still on the bar's
    /// upper end at this side of its window, facing the other way (toward
    /// the screen). It still steps in place while you dictate.
    var perch: HorizontalEdge? = nil

    @State private var x: CGFloat = 40
    @State private var direction: CGFloat = 1
    @State private var stepFlip = false
    @State private var containerWidth: CGFloat = 300
    @State private var containerHeight: CGFloat = 100
    @State private var jumpStartedAt: Date?
    @State private var jumpDuration: TimeInterval = 0.55
    @State private var lastTick = Date()
    @State private var strideDistance: CGFloat = 0
    @State private var particles: [PetParticle] = []
    @State private var eventUntil = Date.distantPast
    @State private var nextEventAfter = Date().addingTimeInterval(25)
    @State private var activeEmote: PetEmote?
    @State private var emoteStartedAt: Date?
    @State private var animationGeneration = 0
    /// Signature of the pet's last-rendered at-rest pose. `tick` compares the
    /// live pose against it to emit exactly one settle render per resting
    /// transition, so the pet never freezes mid-dash while staying quiet.
    @State private var settledSignature = 0

    /// Unlockable pets render as a wobbling egg until they hatch.
    private var isEggPhase: Bool {
        state.petStats.isEggPhase(kind)
    }

    var body: some View {
        if let baseSprite = petSprite(for: kind) {
            let sprite = isEggPhase ? eggSprite : baseSprite

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    particleCanvas
                        .allowsHitTesting(false)

                    spriteWithHat(sprite)
                        .opacity(inEvent && sprite.gait == .float ? 0.3 : 1)
                        .offset(
                            x: perchedX(sprite: sprite, containerWidth: geo.size.width) ?? x + emoteXOffset(),
                            y: geo.size.height - spriteHeight(sprite) - yLift(sprite) - emoteLift()
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            triggerRandomEmote(sprite: sprite)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.tr("%@ pet", kind.label))
                        .accessibilityHint(L10n.tr("Activate for a pet reaction"))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            triggerRandomEmote(sprite: sprite)
                        }
                }
                .onAppear {
                    containerWidth = geo.size.width
                    containerHeight = geo.size.height
                }
                .onChange(of: geo.size) { _, size in
                    containerWidth = size.width
                    containerHeight = size.height
                }
            }
            .scaleEffect(x: 1, y: hanging ? -1 : 1)
            .onChange(of: state.phase) { _, phase in
                // YA-03: celebrate a confirmed paste only.
                if PetCelebrationPolicy.celebrates(phase) {
                    celebrate(sprite: sprite)
                }
            }
            .onChange(of: platformWidth) { _, _ in
                snapOntoPlatform(sprite: sprite)
            }
            // External state changes and direct pet interactions restart this
            // task. Quiet pets suspend indefinitely; only visible motion uses
            // the 15 Hz frame cadence.
            .task(id: animationTaskID) {
                lastTick = Date()
                snapOntoPlatform(sprite: sprite, animated: false)

                while !Task.isCancelled {
                    let schedule = tick(sprite: sprite)

                    do {
                        switch schedule {
                        case .nextFrame:
                            try await Task.sleep(nanoseconds: 66_000_000)
                        case let .wake(date):
                            let delay = max(0, date.timeIntervalSinceNow)
                            try await Task.sleep(nanoseconds: nanoseconds(for: delay))
                        case .dormant:
                            try await Task.sleep(nanoseconds: UInt64.max)
                        }
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private var animationTaskID: PetAnimationTaskID {
        PetAnimationTaskID(
            kind: kind.rawValue,
            platformWidth: platformWidth,
            isEggPhase: isEggPhase,
            phase: String(reflecting: state.phase),
            lastSuccessAt: state.lastSuccessAt,
            generation: animationGeneration,
            reduceMotion: reduceMotion
        )
    }

    private func nanoseconds(for delay: TimeInterval) -> UInt64 {
        let clamped = min(max(delay, 0), TimeInterval(UInt64.max) / 1_000_000_000)
        return UInt64(clamped * 1_000_000_000)
    }

    private var inEvent: Bool {
        Date() < eventUntil
    }

    /// Wall-clock-driven inputs that select the pet's at-rest pose, packed into
    /// a signature. `active` is folded in so the active->quiet transition always
    /// lands one settle render (clearing a mid-dash walk pose, a mid-air jump,
    /// or the dimmed float-gait opacity); `recentlyActive` flips sit->sleep two
    /// minutes after the last success; `inEvent` toggles the float ghost's dim.
    private func restPose(active: Bool) -> Int {
        (active ? 1 : 0) | (recentlyActive ? 2 : 0) | (inEvent ? 4 : 0)
    }

    // MARK: - Rendering

    private func spriteWithHat(_ sprite: PetSprite) -> some View {
        let frame = currentFrame(for: sprite)
        let grid = sprite.grid(for: frame)
        let gridWidth = grid.first?.count ?? 0
        let baseMirrored = sprite.mirrors && (perchFacing ?? direction) < 0
        let mirrored = activeEmote?.mirrored(base: baseMirrored, step: emoteStep()) ?? baseMirrored

        return ZStack(alignment: .topLeading) {
            PixelSpriteCanvas(
                grid: grid,
                palette: sprite.palette,
                pixel: pixel,
                mirrored: mirrored
            )

            if let hat = currentHat, frame != .sleep {
                let hatWidth = hat.grid.first?.count ?? 0
                let anchorColumn = mirrored
                    ? gridWidth - sprite.hatAnchor.column - hatWidth
                    : sprite.hatAnchor.column
                let bottom = hat.bottomRow(anchorRow: sprite.hatAnchor.row, sink: sprite.hatSink)
                    + sprite.hatFrameShift(for: frame)

                PixelSpriteCanvas(
                    grid: hat.grid,
                    palette: hatColors,
                    pixel: pixel,
                    mirrored: mirrored
                )
                .offset(
                    x: CGFloat(anchorColumn) * pixel,
                    y: CGFloat(bottom - hat.grid.count + 1) * pixel
                )
            }

            emoteBadge(sprite: sprite, gridWidth: gridWidth)
        }
    }

    @ViewBuilder
    private func emoteBadge(sprite: PetSprite, gridWidth: Int) -> some View {
        if activeEmote == .heart {
            PixelSpriteCanvas(
                grid: uprightGrid(heartGrid),
                palette: emotePalette,
                pixel: pixel,
                mirrored: false
            )
            .offset(
                x: CGFloat(max(0, gridWidth - 3)) * pixel,
                y: -7 * pixel
            )
        } else if activeEmote == .zzz {
            // Upside down, Zzz needs a half turn (rows AND columns) to read.
            PixelSpriteCanvas(
                grid: uprightGrid(zzzGrid),
                palette: emotePalette,
                pixel: pixel,
                mirrored: hanging
            )
            .offset(
                x: CGFloat(max(0, gridWidth - 2)) * pixel,
                y: -6 * pixel
            )
        }
    }

    /// A badge grid that reads the right way up even when the pet hangs:
    /// the whole view is flipped, so the rows are flipped back.
    private func uprightGrid(_ grid: [[Character]]) -> [[Character]] {
        hanging ? grid.reversed() : grid
    }

    private var particleCanvas: some View {
        Canvas { context, _ in
            let now = Date()

            for particle in particles {
                let age = now.timeIntervalSince(particle.born)
                let life = particle.isHeart ? 1.2 : 0.9
                let opacity = max(0, 1 - age / life)
                guard opacity > 0 else { continue }

                if particle.isHeart {
                    for (gy, row) in uprightGrid(heartGrid).enumerated() {
                        for (gx, character) in row.enumerated() where character == "h" {
                            let rect = CGRect(
                                x: particle.x + CGFloat(gx) * pixel,
                                y: particle.y + CGFloat(gy) * pixel,
                                width: pixel,
                                height: pixel
                            )
                            context.fill(Path(rect), with: .color(heartPink.opacity(opacity)))
                        }
                    }
                } else {
                    let rect = CGRect(x: particle.x, y: particle.y, width: 3, height: 3)
                    context.fill(Path(rect), with: .color(particle.color.opacity(opacity)))
                }
            }
        }
    }

    // MARK: - Behavior

    private var isWalking: Bool {
        state.phase == .recording
    }

    private func currentFrame(for sprite: PetSprite) -> PetFrame {
        if let activeEmote {
            return activeEmote.usesSleepFrame ? .sleep : (stepFlip ? .walkA : .walkB)
        }

        switch state.phase {
        case .recording, .copied, .pasted:
            if sprite.gait == .hop {
                // Crouch on the ground, extend mid-air.
                return abs(sin(x / 16 * .pi)) > 0.45 ? .walkB : .walkA
            }
            return stepFlip ? .walkA : .walkB
        case .transcribing:
            return .sit
        default:
            if inEvent {
                return stepFlip ? .walkA : .walkB
            }
            return recentlyActive ? .sit : .sleep
        }
    }

    private func emoteStep(now: Date = Date()) -> Int {
        guard !reduceMotion else { return 0 }
        guard let activeEmote, let emoteStartedAt else { return 0 }
        return activeEmote.step(startedAt: emoteStartedAt, now: now)
    }

    private func emoteXOffset(now: Date = Date()) -> CGFloat {
        guard let activeEmote else { return 0 }
        return activeEmote.horizontalOffset(step: emoteStep(now: now), pixel: pixel)
    }

    private func emoteLift(now: Date = Date()) -> CGFloat {
        guard let activeEmote else { return 0 }
        return activeEmote.lift(step: emoteStep(now: now), pixel: pixel)
    }

    private func triggerRandomEmote(sprite: PetSprite) {
        let now = Date()
        // A static heart preserves interaction feedback without spatial motion.
        let emote = reduceMotion ? PetEmote.heart : (PetEmote.allCases.randomElement() ?? .hop)
        activeEmote = emote
        emoteStartedAt = now
        lastTick = now
        if !reduceMotion {
            stepFlip.toggle()
        }

        if emote == .heart, !reduceMotion {
            emitHeartEmote(sprite: sprite, now: now)
        }

        animationGeneration &+= 1
    }

    private func emitHeartEmote(sprite: PetSprite, now: Date) {
        let spriteWidth = CGFloat(sprite.walkA.first?.count ?? 16) * pixel
        let originX = x + spriteWidth / 2
        let originY = containerHeight - spriteHeight(sprite) - 8

        for offset in [-10.0, 0.0, 10.0] {
            particles.append(PetParticle(
                x: originX + CGFloat(offset),
                y: originY,
                velocityX: CGFloat(offset / 8),
                velocityY: -24,
                color: heartPink,
                born: now,
                isHeart: true
            ))
        }
    }

    /// The pet stays awake for a couple of minutes after a successful dictation.
    private var recentlyActive: Bool {
        guard let lastSuccessAt = state.lastSuccessAt else { return false }
        return Date().timeIntervalSince(lastSuccessAt) < 120
    }

    private var currentHat: PetHat? {
        guard !isEggPhase else { return nil }

        // WARDROBE-WINS: the user's equipped accessory always beats the
        // festive calendar; seasonal hats only dress pets with nothing on.
        if let equipped = state.petStats.accessory(for: kind).hat {
            return equipped
        }
        return PetView.seasonalHat(for: Date())
    }

    /// Deterministic seasonal wardrobe, a pure function of the date so it is
    /// testable and never touches the network. Festive hats dress pets that
    /// have NOTHING equipped; an explicit wardrobe choice always wins.
    /// The Valentine heart floats above the head; everything else is worn.
    static func seasonalHat(for date: Date) -> PetHat? {
        let parts = Calendar.current.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return nil }

        switch (month, day) {
        case (12, _):              return PetHat(grid: santaHat, floats: false)     // all of December
        case (10, 24...31):        return PetHat(grid: pumpkinHat, floats: false)   // Halloween week
        case (1, 1...2):           return PetHat(grid: newYearHat, floats: false)   // New Year
        case (2, 10...18):         return PetHat(grid: valentineHat, floats: true)  // Valentine's window
        case (7, _), (8, _):       return PetHat(grid: summerHat, floats: false)    // summer shades
        default:                   return nil
        }
    }

    private func spriteHeight(_ sprite: PetSprite) -> CGFloat {
        CGFloat(sprite.walkA.count) * pixel
    }

    private func yLift(_ sprite: PetSprite) -> CGFloat {
        var lift: CGFloat = 0

        if sprite.gait == .float, !reduceMotion {
            lift += 1 + (sin(Date().timeIntervalSinceReferenceDate * 2.2) + 1) * 1.2
        }

        if sprite.gait == .hop, isWalking {
            // Hop arc derived from position, so it stays in sync with movement.
            lift += abs(sin(x / 16 * .pi)) * 7
        }

        if let jumpStartedAt {
            let elapsed = Date().timeIntervalSince(jumpStartedAt)
            if elapsed < jumpDuration {
                // Big celebrations chain multiple 0.55s arcs.
                let arcProgress = (elapsed / 0.55).truncatingRemainder(dividingBy: 1)
                lift += CGFloat(sin(arcProgress * .pi)) * 13
            }
        }

        return lift
    }

    private func celebrate(sprite: PetSprite) {
        let intensity = state.celebrationIntensity
        guard intensity > 0 else { return }
        guard !reduceMotion else {
            jumpStartedAt = nil
            particles.removeAll()
            return
        }

        jumpStartedAt = Date()
        jumpDuration = [0, 0.55, 1.1, 1.65][min(intensity, 3)]

        let confettiCount = [0, 22, 40, 70][min(intensity, 3)]
        let spriteWidth = CGFloat(sprite.walkA.first?.count ?? 16) * pixel
        let originX = x + spriteWidth / 2
        let originY = containerHeight - spriteHeight(sprite) - 6

        for index in 0..<confettiCount {
            let angle = Double.pi * (0.15 + 0.7 * Double(index) / Double(max(confettiCount - 1, 1)))
            let speed = CGFloat(60 + (index % 7) * 26)
            particles.append(PetParticle(
                x: originX,
                y: originY,
                velocityX: CGFloat(cos(angle)) * speed * (index.isMultiple(of: 2) ? 1 : -1),
                velocityY: -CGFloat(sin(angle)) * speed,
                color: confettiPalette[index % confettiPalette.count],
                born: Date(),
                isHeart: false
            ))
        }

        for offset in [-12.0, 14.0] {
            particles.append(PetParticle(
                x: originX + offset,
                y: originY - 4,
                velocityX: CGFloat(offset > 0 ? 6 : -6),
                velocityY: -26,
                color: heartPink,
                born: Date(),
                isHeart: true
            ))
        }

        animationGeneration &+= 1
    }

    /// A perched pet never walks sideways, so its spot is computed from the
    /// container instead of waiting for the first animation tick (static
    /// renders and the first frame put it in the right place too).
    private func perchedX(sprite: PetSprite, containerWidth: CGFloat) -> CGFloat? {
        guard let perch else { return nil }
        let spriteWidth = CGFloat(sprite.walkA.first?.count ?? 16) * pixel
        let base: CGFloat = perch == .leading ? 0 : max(0, containerWidth - spriteWidth)
        return base + emoteXOffset()
    }

    /// A perched pet faces the screen: right on the left edge, left on the
    /// right edge.
    private var perchFacing: CGFloat? {
        perch.map { $0 == .leading ? 1 : -1 }
    }

    private func walkBounds(spriteWidth: CGFloat) -> (min: CGFloat, max: CGFloat) {
        switch perch {
        case .leading?:
            return (0, 0)
        case .trailing?:
            let x = max(0, containerWidth - spriteWidth)
            return (x, x)
        case nil:
            break
        }
        let width = min(platformWidth ?? containerWidth, containerWidth)
        let minX = max(0, (containerWidth - width) / 2)
        return (minX, max(minX, minX + width - spriteWidth))
    }

    /// Keeps the pet standing on its platform when the widget collapses or
    /// expands underneath it.
    private func snapOntoPlatform(sprite: PetSprite, animated: Bool = true) {
        if let facing = perchFacing, direction != facing {
            direction = facing
        }
        let spriteWidth = CGFloat(sprite.walkA.first?.count ?? 16) * pixel
        let bounds = walkBounds(spriteWidth: spriteWidth)
        let clamped = min(max(x, bounds.min), bounds.max)

        guard clamped != x else { return }

        if animated, !reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                x = clamped
            }
        } else {
            x = clamped
        }
    }

    private func tick(sprite: PetSprite) -> PetAnimationSchedule {
        let now = Date()
        let jumping = jumpStartedAt.map { now.timeIntervalSince($0) < jumpDuration } ?? false
        let emoteActive: Bool
        if let activeEmote, let emoteStartedAt {
            emoteActive = now.timeIntervalSince(emoteStartedAt) < activeEmote.duration
        } else {
            emoteActive = false
        }

        if activeEmote != nil && !emoteActive {
            activeEmote = nil
            emoteStartedAt = nil
        }

        if reduceMotion {
            if !particles.isEmpty {
                particles.removeAll()
            }
            jumpStartedAt = nil
            eventUntil = .distantPast

            let pose = restPose(active: false)
            if pose != settledSignature {
                settledSignature = pose
            }

            if let activeEmote, let emoteStartedAt {
                return .wake(at: emoteStartedAt.addingTimeInterval(activeEmote.duration))
            }
            return reducedMotionQuietSchedule(now: now)
        }

        let idleDashDue = !isWalking && !jumping && !inEvent
            && state.phase == .idle && recentlyActive && now >= nextEventAfter
        let active = isWalking || jumping || inEvent || !particles.isEmpty || idleDashDue || emoteActive

        // idle-tick-quiet: an asleep/idle pet must not touch @State every frame.
        // A bare `lastTick = now` write invalidates the view at ~15Hz, and
        // PetView lives in always-on HUD windows on every display, so that is
        // constant idle-CPU for nothing. Bail before any state write unless
        // something is actually animating or an idle micro-dash is due. `dt` is
        // capped below, so skipping lastTick updates while quiet cannot produce
        // a movement jump when animation resumes.
        //
        // settle-render: the at-rest pose is chosen by wall-clock-driven inputs
        // (an idle dash elapsing, `recentlyActive` lapsing after two minutes)
        // that flip with no @State change to invalidate the view. Bailing the
        // instant activity stopped would freeze the last render — a mid-dash
        // walk pose, a mid-air jump, or the dimmed float ghost (0.3 opacity) —
        // forever. `restPose` folds those inputs plus `active` into a signature;
        // on each edge we emit exactly one @State write so the pet lands in its
        // true resting pose, then fall silent again. Stable pose => zero writes.
        guard active else {
            let pose = restPose(active: false)
            if pose != settledSignature {
                settledSignature = pose
            }
            return quietSchedule(now: now)
        }

        // Keep the settle baseline current while active so the first quiet tick
        // fires exactly one render into the resting pose. Without this, an idle
        // dash's inEvent blip happens only during active ticks, leaving the
        // pre- and post-dash signatures equal and the walk pose frozen.
        settledSignature = restPose(active: true)

        let dt = min(now.timeIntervalSince(lastTick), 0.2)
        lastTick = now

        if !particles.isEmpty {
            for index in particles.indices {
                particles[index].x += particles[index].velocityX * CGFloat(dt)
                particles[index].y += particles[index].velocityY * CGFloat(dt)
                if !particles[index].isHeart {
                    particles[index].velocityY += 230 * CGFloat(dt)
                }
            }
            particles.removeAll { now.timeIntervalSince($0.born) > 1.3 }
        }

        if emoteActive {
            strideDistance += 8
            if strideDistance >= 8 {
                strideDistance = 0
                stepFlip.toggle()
            }
        }

        // Idle micro-events: an awake pet occasionally dashes around on its own.
        if idleDashDue {
            eventUntil = now.addingTimeInterval(1.3)
            nextEventAfter = now.addingTimeInterval(Double.random(in: 18...40))
            if Bool.random() {
                direction = -direction
            }
        }

        guard isWalking || jumping || inEvent else { return .nextFrame }

        let level = state.levelHistory.last ?? 0
        var speed: CGFloat = isWalking ? (16 + CGFloat(level) * 130) : 26
        if inEvent, !isWalking {
            speed = 85
        }
        speed *= sprite.speedFactor
        let spriteWidth = CGFloat(sprite.walkA.first?.count ?? 16) * pixel

        let step = speed * CGFloat(dt)
        x += step * direction

        let bounds = walkBounds(spriteWidth: spriteWidth)
        if x > bounds.max {
            x = bounds.max
            direction = -1
        } else if x < bounds.min {
            x = bounds.min
            direction = 1
        }
        if let facing = perchFacing {
            direction = facing
        }

        strideDistance += step
        if strideDistance > 8 {
            strideDistance = 0
            stepFlip.toggle()
        }

        return .nextFrame
    }

    private func quietSchedule(now: Date) -> PetAnimationSchedule {
        guard state.phase == .idle, let lastSuccessAt = state.lastSuccessAt else {
            return .dormant
        }

        let sleepAt = lastSuccessAt.addingTimeInterval(120)
        guard now < sleepAt else { return .dormant }
        return .wake(at: min(nextEventAfter, sleepAt))
    }

    /// Reduced Motion keeps the meaningful awake-to-sleep state change but
    /// skips the decorative idle dash entirely.
    private func reducedMotionQuietSchedule(now: Date) -> PetAnimationSchedule {
        guard state.phase == .idle, let lastSuccessAt = state.lastSuccessAt else {
            return .dormant
        }

        let sleepAt = lastSuccessAt.addingTimeInterval(120)
        return now < sleepAt ? .wake(at: sleepAt) : .dormant
    }
}
