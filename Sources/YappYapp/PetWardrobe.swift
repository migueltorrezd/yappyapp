import SwiftUI

enum PetAccessory: String, CaseIterable, Identifiable {
    case none
    case beanie
    case party
    case halo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: L10n.tr("None")
        case .beanie: L10n.tr("Beanie")
        case .party: L10n.tr("Party hat")
        case .halo: L10n.tr("Halo")
        }
    }

    var unlockLevel: Int {
        switch self {
        case .none: 1
        case .beanie: 3
        case .party: 6
        case .halo: 10
        }
    }

    var hat: PetHat? {
        switch self {
        case .none: nil
        case .beanie: PetHat(grid: beanieGrid, floats: false)
        case .party: PetHat(grid: partyGrid, floats: false)
        case .halo: PetHat(grid: haloGrid, floats: true)
        }
    }
}

/// A composited headwear sprite. Worn hats sink by the pet's `hatSink` so
/// they hug the skull and cover ear/horn tips; floating hats (halo, the
/// Valentine heart) keep their airborne placement above the anchor row.
struct PetHat {
    let grid: [[Character]]
    let floats: Bool

    /// Grid row the hat's bottom row lands on, relative to the sprite.
    func bottomRow(anchorRow: Int, sink: Int) -> Int {
        anchorRow + (floats ? 0 : sink)
    }
}

private let beanieGrid = parse("""
.bbbbb.
bbbbbbb
b.b.b.b
""")

private let partyGrid = parse("""
...#...
..#y#..
.#pp#..
#pppp#.
""")

private let haloGrid = parse("""
.yyyy.
y....y
.yyyy.
""")
private let hatRed = Color(red: 0.90, green: 0.23, blue: 0.20)
private let hatGold = Color(red: 1.0, green: 0.78, blue: 0.16)
let heartPink = Color(red: 1.0, green: 0.43, blue: 0.55)

let hatColors: [Character: Color] = [
    "#": ink,
    "r": hatRed,
    "y": hatGold,
    "w": zColor,
    "b": Color(red: 0.27, green: 0.51, blue: 1.0),
    "p": Color(red: 1.0, green: 0.41, blue: 0.71),
    "o": Color(red: 1.0, green: 0.51, blue: 0.13),   // pumpkin orange
    "g": Color(red: 0.32, green: 0.66, blue: 0.30)    // stem / shades green
]

let santaHat = parse("""
.....ww
..rrrww
.rrrrr.
wwwwww.
""")

private let crownHat = parse("""
y.y.y
yyyyy
""")

// Late October: a tiny jack-o'-lantern perched on the head.
let pumpkinHat = parse("""
..g..
.ooo.
ooooo
o#o#o
.ooo.
""")

// Mid-February: a small heart floating just above the head.
let valentineHat = parse("""
.p.p.
ppppp
.ppp.
..p..
""")

// New Year: a party popper / confetti burst.
let newYearHat = parse("""
y.r.b
.ryb.
..#..
.##..
##...
""")

// Summer: sunglasses (two dark lenses on a green bridge), sitting low so
// they read as eyewear rather than a hat.
let summerHat = parse("""
##g##
#w#w#
""")
