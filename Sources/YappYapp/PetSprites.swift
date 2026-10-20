import SwiftUI

struct PetSprite {
    let walkA: [[Character]]
    let walkB: [[Character]]
    let sit: [[Character]]
    let sleep: [[Character]]
    let palette: [Character: Color]
    let gait: PetGait
    /// Side-view sprites flip when walking left; front-view sprites do not.
    let mirrors: Bool
    /// Grid column where a hat's left edge sits, and the row of the head top.
    let hatAnchor: (column: Int, row: Int)
    /// Rows a worn (non-floating) hat sinks below the anchor row so it rests
    /// on the skull instead of hovering on ear/horn/eye-stalk tips. The row
    /// just below the hat's sunken bottom row must be solid head outline.
    var hatSink: Int = 0
    /// Movement speed multiplier; the snail is contractually slow.
    var speedFactor: CGFloat = 1

    func grid(for frame: PetFrame) -> [[Character]] {
        switch frame {
        case .walkA: walkA
        case .walkB: walkB
        case .sit: sit
        case .sleep: sleep
        }
    }

    /// Rows this frame's artwork sits below (positive) or above (negative)
    /// walkA's, measured from each grid's first non-empty row. Some frames
    /// bake vertical motion into the grid — the ghost's walkB bobs up a row,
    /// the crab hunkers down a row when sitting — and the hat must ride along
    /// instead of staying pinned to the walkA head position.
    func hatFrameShift(for frame: PetFrame) -> Int {
        firstSolidRow(grid(for: frame)) - firstSolidRow(walkA)
    }

    private func firstSolidRow(_ grid: [[Character]]) -> Int {
        grid.firstIndex { row in row.contains { $0 != "." } } ?? 0
    }
}

func parse(_ art: String) -> [[Character]] {
    var lines = art.split(separator: "\n").map(String.init)

    // Trailing empty rows make the sprite float above whatever it stands on.
    while let last = lines.last, !last.contains(where: { $0 != "." }) {
        lines.removeLast()
    }

    let width = lines.map(\.count).max() ?? 0
    return lines.map { line in
        Array(line.padding(toLength: width, withPad: ".", startingAt: 0))
    }
}

let ink = Color(red: 0.10, green: 0.09, blue: 0.07)
let zColor = Color(red: 1.0, green: 0.97, blue: 0.92)
let catSprite = PetSprite(
    walkA: parse("""
    ..........##..##..
    ..........#d##d#..
    .........#oooooo#.
    .#.......#o#oo#o#.
    .##......#odppdo#.
    ..#d.....#owwwwo#.
    ..##..####oooooo#.
    ...##oood#ood#o#..
    ....#oooooooooo#..
    ....#wooooooowo#..
    ....###########...
    ....#w#....#w#....
    ....##.....##.....
    """),
    walkB: parse("""
    ..........##..##..
    ..........#d##d#..
    .........#oooooo#.
    .#.......#o#oo#o#.
    .##......#odppdo#.
    ..#d.....#owwwwo#.
    ..##..####oooooo#.
    ...##oood#ood#o#..
    ....#oooooooooo#..
    ....#wooooooowo#..
    ....###########...
    ...#w#.......#w#..
    ...##........##...
    """),
    sit: parse("""
    ..........##..##..
    ..........#d##d#..
    .........#oooooo#.
    .........#o#oo#o#.
    .#.......#odppdo#.
    .##......#owwwwo#.
    ..#d..####oooooo#.
    ..##.#ood#ood#o#..
    ...###ooooooooo#..
    ....#ooooooooo#...
    ....#woo#oo#ww#...
    ....###.####......
    """),
    sleep: parse("""
    ..............w...
    ............w.....
    ..........w.......
    ..##.##...........
    ..#d#d#...........
    .#ooooo########...
    .#o##o##ooooooo#..
    #oooooooooooooo#..
    #ooooodddoddooo#..
    #ooooooooooooo#d#.
    .#oooooooooood#d#.
    ..###########.##..
    """),
    palette: [
        "#": ink,
        "o": Color(red: 1.0, green: 0.60, blue: 0.24),
        "d": Color(red: 0.84, green: 0.43, blue: 0.12),
        "w": zColor,
        "p": Color(red: 1.0, green: 0.59, blue: 0.63)
    ],
    gait: .walk,
    mirrors: true,
    hatAnchor: (column: 10, row: 0),
    hatSink: 2
)

let dogSprite = PetSprite(
    walkA: parse("""
    .........########.
    .........#oooooo#.
    ........##o#oo#o#.
    ........#e#oooooo#
    ........#e#owwww##
    .........##ow#ww#.
    ......####oooooo#.
    .#...#oooooooo#...
    .##.#orrrrrrrr#...
    ..###oooeeoooooo#.
    ....###########...
    ....#o#....#o#....
    ....##.....##.....
    """),
    walkB: parse("""
    .........########.
    .........#oooooo#.
    ........##o#oo#o#.
    ........#e#oooooo#
    ........#e#owwww##
    .........##ow#wp#.
    ......####ooooop#.
    .#...#oooooooo#...
    .##.#orrrrrrrr#...
    ..###oooeeoooooo#.
    ....###########...
    ...#o#.......#o#..
    ...##........##...
    """),
    sit: parse("""
    .........########.
    .........#oooooo#.
    ........##o#oo#o#.
    ........#e#oooooo#
    .#......#e#owwww##
    .##......##ow#ww#.
    ..#...####oooooo#.
    ..##.#oooooooo#...
    ...###orrrrrrr#...
    ....#oooeeoooo#...
    ....#oo#ooo#oo#...
    ....###..####.....
    """),
    sleep: parse("""
    ..............w...
    ............w.....
    ..........w.......
    ..................
    ...############...
    ..##eeeooooooo##..
    .#oo#eeoooooooo#..
    .#o##o#oooooooo#..
    #owwooooooooooo#..
    #ww#oooeeoooooo#..
    .###############..
    """),
    palette: [
        "#": ink,
        "o": Color(red: 0.74, green: 0.55, blue: 0.35),
        "e": Color(red: 0.43, green: 0.29, blue: 0.18),
        "w": zColor,
        "p": Color(red: 1.0, green: 0.47, blue: 0.51),
        "r": Color(red: 0.90, green: 0.23, blue: 0.20)
    ],
    gait: .walk,
    mirrors: true,
    hatAnchor: (column: 10, row: 0)
)

let ghostSprite = PetSprite(
    walkA: parse("""
    ................
    .....######.....
    ....#oooooo#....
    ...#oooooooo#...
    ...#o#oo#ooo#...
    ...#owoowooo#...
    ...#oooooooo#...
    ...#oooooooo#...
    ...#oooooooo#...
    ...#o#oo#oo#....
    ....#..##..#....
    """),
    walkB: parse("""
    .....######.....
    ....#oooooo#....
    ...#oooooooo#...
    ...#o#oo#ooo#...
    ...#owoowooo#...
    ...#oooooooo#...
    ...#oooooooo#...
    ...#oooooooo#...
    ...#o#oo#oo#....
    ....#..##..#....
    ................
    """),
    sit: parse("""
    ................
    .....######.....
    ....#oooooo#....
    ...#oooooooo#...
    ...#o#oo#ooo#...
    ...#owoowooo#...
    ...#oooooooo#...
    ...#oooooooo#...
    ...#oooooooo#...
    ...#o#oo#oo#....
    ....#..##..#....
    """),
    sleep: parse("""
    ................
    .....######..w..
    ....#oooooo#w...
    ...#oooooooo#...
    ...#o##o##oo#...
    ...#oooooooo#...
    ...#oooooooo#...
    ...#oooooooo#...
    ...#oooooooo#...
    ...#o#oo#oo#....
    ....#..##..#....
    """),
    palette: [
        "#": ink,
        "o": Color(red: 0.96, green: 0.94, blue: 1.0),
        "w": Color(red: 0.36, green: 0.36, blue: 0.64)
    ],
    gait: .float,
    mirrors: true,
    hatAnchor: (column: 5, row: 1)
)

let penguinSprite = PetSprite(
    walkA: parse("""
    ....#####....
    ...#kkkkk#...
    ..#kk#kkkk#..
    ..#kkkkkkk#bb
    ..#kkwwwkk#b.
    ..#kwwwwwk#..
    ..#kwwwwwk#..
    .##kwwwwwk#..
    .#k#wwwwwk#..
    ..#kwwwwwk#..
    ..#kkwwwkk#..
    ...#######...
    ...bb#.#bb...
    """),
    walkB: parse("""
    ....#####....
    ...#kkkkk#...
    ..#kk#kkkk#..
    ..#kkkkkkk#bb
    ..#kkwwwkk#b.
    ..#kwwwwwk#..
    ..#kwwwwwk#..
    ..#kwwwwwk##.
    ..#kwwwwwk#k#
    ..#kwwwwwk#..
    ..#kkwwwkk#..
    ...#######...
    ....bb#bb....
    """),
    sit: parse("""
    ....#####....
    ...#kkkkk#...
    ..#kk#kkkk#..
    ..#kkkkkkk#bb
    ..#kkwwwkk#b.
    ..#kwwwwwk#..
    ..#kwwwwwk#..
    ..#kwwwwwk#..
    ..#kwwwwwk#..
    ..#kwwwwwk#..
    ..#kkwwwkk#..
    ...#######...
    ...bb...bb...
    """),
    sleep: parse("""
    .............
    ...........w.
    .........w...
    ....#####....
    ...#kkkkk#...
    ..#kkkkkkk#..
    ..#kk##kkk#..
    ..#kbbkkkk#..
    ..#kwbwwwk#..
    ..#kwwwwwk#..
    ..#kwwwwwk#..
    ..#kwwwwwk#..
    ..#kkwwwkk#..
    ...#######...
    ...bb...bb...
    """),
    palette: [
        "#": ink,
        "k": Color(red: 0.18, green: 0.19, blue: 0.24),
        "w": Color(red: 0.98, green: 0.97, blue: 0.94),
        "b": Color(red: 1.0, green: 0.63, blue: 0.16)
    ],
    gait: .walk,
    mirrors: true,
    hatAnchor: (column: 4, row: 0)
)

let foxSprite = PetSprite(
    walkA: parse("""
    ..........##...##.
    ..........#o#.#o#.
    ..........#oo#oo#.
    .##.......#ooooo#.
    .#w#......#o#oo#o#
    .#ww#.....#oooooo#
    ..#ww#.####ooowww#
    ...#o##oooooooow#.
    ....#ooooooooow#..
    ....#oowwwwoo##...
    ....##########....
    ....#d#....#d#....
    ....##.....##.....
    """),
    walkB: parse("""
    ..........##...##.
    ..........#o#.#o#.
    ..........#oo#oo#.
    .##.......#ooooo#.
    .#w#......#o#oo#o#
    .#ww#.....#oooooo#
    ..#ww#.####ooowww#
    ...#o##oooooooow#.
    ....#ooooooooow#..
    ....#oowwwwoo##...
    ....##########....
    ...#d#.......#d#..
    ...##........##...
    """),
    sit: parse("""
    ..........##...##.
    ..........#o#.#o#.
    ..........#oo#oo#.
    ..........#ooooo#.
    .##.......#o#oo#o#
    .#w#......#oooooo#
    ..#w#..###ooowww#.
    ..#wo##ooooooow#..
    ...##oooooooow#...
    ....#oowwwwoo#....
    ....#d#ww##dd#....
    ....##...##.......
    """),
    sleep: parse("""
    ..............w...
    ............w.....
    ..........w.......
    ..##..##..........
    ..#o##o#..........
    .#oooooo########..
    .#o##o##ooooooo#..
    #oooooooooooooo#..
    #ooooooooooooooo#.
    #wwwoooddddoooo#..
    .##############...
    """),
    palette: [
        "#": ink,
        "o": Color(red: 0.94, green: 0.43, blue: 0.16),
        "w": Color(red: 0.99, green: 0.96, blue: 0.91),
        "d": Color(red: 0.47, green: 0.24, blue: 0.10)
    ],
    gait: .walk,
    mirrors: true,
    hatAnchor: (column: 11, row: 0),
    hatSink: 2
)

let frogSprite = PetSprite(
    walkA: parse("""
    ..##......##..
    .#gg#....#gg#.
    .#g#g#..#g#g#.
    .#gggggggggg#.
    #gggggggggggg#
    #gglllllllggg#
    #glllllllllg#.
    .#gg#llll#gg#.
    .#g##g##g##g#.
    ..##..##..##..
    """),
    walkB: parse("""
    ..##......##..
    .#gg#....#gg#.
    .#g#g#..#g#g#.
    .#gggggggggg#.
    #gggggggggggg#
    #gglllllllggg#
    #glllllllllgg#
    .#g.#llll#.g#.
    .#g..####..g#.
    ..#g......g#..
    ...##....##...
    """),
    sit: parse("""
    ..##......##..
    .#gg#....#gg#.
    .#g#g#..#g#g#.
    .#gggggggggg#.
    #gggggggggggg#
    #gglllllllggg#
    #glllllllllg#.
    .#gg#llll#gg#.
    .#g##g##g##g#.
    ..##..##..##..
    """),
    sleep: parse("""
    .............w
    ...........w..
    ..##......##..
    .#gg#....#gg#.
    .######.######
    .#gggggggggg#.
    #gggggggggggg#
    #gglllllllggg#
    .#gggggggggg#.
    ..##########..
    """),
    palette: [
        "#": ink,
        "g": Color(red: 0.35, green: 0.75, blue: 0.27),
        "l": Color(red: 0.59, green: 0.86, blue: 0.35),
        "w": zColor
    ],
    gait: .hop,
    mirrors: false,
    hatAnchor: (column: 4, row: 0),
    hatSink: 1
)

let crabSprite = PetSprite(
    walkA: parse("""
    .##........##.
    #rr#......#rr#
    #r#........#r#
    .#..#r##r#..#.
    ..#r#r##r#r#..
    .#rrrrrrrrrr#.
    #rr#rr##rr#rr#
    #rrrrrrrrrrrr#
    .#rrrrrrrrrr#.
    ..#r#.##.#r#..
    ..##..##..##..
    """),
    walkB: parse("""
    .##........##.
    #rr#......#rr#
    #r#........#r#
    .#..#r##r#..#.
    ..#r#r##r#r#..
    .#rrrrrrrrrr#.
    #rr#rr##rr#rr#
    #rrrrrrrrrrrr#
    .#rrrrrrrrrr#.
    .#r#..##..#r#.
    .##...##...##.
    """),
    sit: parse("""
    ..............
    .#r#......#r#.
    ..#..#r##r#..#
    ..#r#r##r#r#..
    .#rrrrrrrrrr#.
    #rr#rr##rr#rr#
    #rrrrrrrrrrrr#
    .#rrrrrrrrrr#.
    ..#r#.##.#r#..
    ..##..##..##..
    """),
    sleep: parse("""
    .............w
    ...........w..
    ....#r##r#....
    ...#rrrrrr#...
    ..#rr#rr#rr#..
    .#rrrrrrrrrr#.
    #rrrrrrrrrrrr#
    #rdd#rrrr#ddr#
    .####.##.####.
    """),
    palette: [
        "#": ink,
        "r": Color(red: 0.92, green: 0.29, blue: 0.22),
        "d": Color(red: 0.67, green: 0.16, blue: 0.12),
        "w": zColor
    ],
    gait: .walk,
    mirrors: false,
    hatAnchor: (column: 5, row: 0),
    hatSink: 3
)

let robotSprite = PetSprite(
    walkA: parse("""
    ......#y#.....
    .......#......
    ....#######...
    ...#mmmmmmm#..
    ...#m#ccc#m#..
    ...#m#ccc#m#..
    ...#mmmmmmm#..
    ....##mmm##...
    ..##mmmmmmm##.
    ..#mmsmmmsmm#.
    ..###########.
    ..#s#s#s#s#s#.
    ...#########..
    """),
    walkB: parse("""
    ......#.#.....
    .......#......
    ....#######...
    ...#mmmmmmm#..
    ...#m#ccc#m#..
    ...#m#ccc#m#..
    ...#mmmmmmm#..
    ....##mmm##...
    ..##mmmmmmm##.
    ..#mmsmmmsmm#.
    ..###########.
    ..#s#s#s#s#s#.
    ...#########..
    """),
    sit: parse("""
    ......#y#.....
    .......#......
    ....#######...
    ...#mmmmmmm#..
    ...#m#ccc#m#..
    ...#m#ccc#m#..
    ...#mmmmmmm#..
    ....##mmm##...
    ..##mmmmmmm##.
    ..#mmsmmmsmm#.
    ..###########.
    ..#s#s#s#s#s#.
    ...#########..
    """),
    sleep: parse("""
    ..............
    ...........c..
    .........c....
    .......#......
    ....#######...
    ...#mmmmmmm#..
    ...#m##s##m#..
    ...#mmmmmmm#..
    ..##mmmmmmm##.
    ..#mmsmmmsmm#.
    ..###########.
    ...#########..
    """),
    palette: [
        "#": ink,
        "m": Color(red: 0.63, green: 0.67, blue: 0.73),
        "s": Color(red: 0.43, green: 0.47, blue: 0.53),
        "c": Color(red: 0.35, green: 0.86, blue: 1.0),
        "y": Color(red: 1.0, green: 0.78, blue: 0.16)
    ],
    gait: .walk,
    mirrors: false,
    hatAnchor: (column: 4, row: 2)
)

let dinoSprite = PetSprite(
    walkA: parse("""
    ..........######..
    .........#gggggg#.
    .........#g#gggg#.
    .........#gggggg#.
    .........#gg####..
    .##......#ggg#....
    .#g##...#gggg#....
    ..#gg###ggggg#....
    ...#gggglllgg#....
    ....#ggglllgg#....
    .....#gglllg#.....
    .....#g#..#g#.....
    .....##...##......
    """),
    walkB: parse("""
    ..........######..
    .........#gggggg#.
    .........#g#gggg#.
    .........#gggggg#.
    .........#gg####..
    .##......#ggg#....
    .#g##...#gggg#....
    ..#gg###ggggg#....
    ...#gggglllgg#....
    ....#ggglllgg#....
    .....#gglllg#.....
    ....#g#....#g#....
    ....##.....##.....
    """),
    sit: parse("""
    ..........######..
    .........#gggggg#.
    .........#g#gggg#.
    .........#gggggg#.
    .........#gg####..
    .##......#ggg#....
    .#g##...#gggg#....
    ..#gg###ggggg#....
    ...#gggglllgg#....
    ....#ggglllggg#...
    .....#gglllggg#...
    .....#g##g##gg#...
    .....##..##.......
    """),
    sleep: parse("""
    .............w....
    ...........w......
    ....##############
    ...#gggggggggggg#.
    ..#gg#ggg##gggg#..
    .#ggggglllgggggg#.
    ..#ggggllllgggg#..
    ...##############.
    """),
    palette: [
        "#": ink,
        "g": Color(red: 0.37, green: 0.71, blue: 0.43),
        "l": Color(red: 0.63, green: 0.84, blue: 0.55),
        "w": zColor
    ],
    gait: .walk,
    mirrors: true,
    hatAnchor: (column: 10, row: 0)
)

let duckSprite = PetSprite(
    walkA: parse("""
    ....#####....
    ...#yyyyy#...
    ..#yy#yyyy#..
    ..#yyyyyyy#bb
    ..#yyyyyyy#b.
    .##yyyyyyy#..
    .#y#yyyyyy#..
    ..#yyyyyyy#..
    ..#yywwyyy#..
    ...#######...
    ...bb#.#bb...
    """),
    walkB: parse("""
    ....#####....
    ...#yyyyy#...
    ..#yy#yyyy#..
    ..#yyyyyyy#bb
    ..#yyyyyyy#b.
    ..#yyyyyyy##.
    ..#yyyyyyy#y#
    ..#yyyyyyy#..
    ..#yywwyyy#..
    ...#######...
    ....bb#bb....
    """),
    sit: parse("""
    ....#####....
    ...#yyyyy#...
    ..#yy#yyyy#..
    ..#yyyyyyy#bb
    ..#yyyyyyy#b.
    ..#yyyyyyy#..
    ..#yyyyyyy#..
    ..#yyyyyyy#..
    ..#yywwyyy#..
    ...#######...
    ...bb...bb...
    """),
    sleep: parse("""
    .............
    ...........w.
    .........w...
    ....#####....
    ...#yyyyy#...
    ..#yy##yyy#..
    ..#ybbyyyy#..
    ..#ywbwwyy#..
    ..#yywwyyy#..
    ..#yyyyyyy#..
    ...#######...
    ...bb...bb...
    """),
    palette: [
        "#": ink,
        "y": Color(red: 1.0, green: 0.82, blue: 0.24),
        "b": Color(red: 1.0, green: 0.55, blue: 0.12),
        "w": Color(red: 0.99, green: 0.97, blue: 0.92)
    ],
    gait: .walk,
    mirrors: true,
    hatAnchor: (column: 4, row: 0)
)

let snailSprite = PetSprite(
    walkA: parse("""
    ......######....
    .....#ssssss#...
    ....#ss####ss#..
    .##.#ss#dd#ss#..
    .#b##s#dddd#s#..
    ..#b#ss####ss#..
    ..#bb#ssssss#...
    .#bbbb######....
    #bbbbbbbbbbbb#..
    .############...
    """),
    walkB: parse("""
    ......######....
    .....#ssssss#...
    ....#ss####ss#..
    ##..#ss#dd#ss#..
    #b##.s#dddd#s#..
    .#b#sss####ss#..
    ..#bb#ssssss#...
    .#bbbb######....
    #bbbbbbbbbbbbb#.
    .#############..
    """),
    sit: parse("""
    ......######....
    .....#ssssss#...
    ....#ss####ss#..
    .##.#ss#dd#ss#..
    .#b##s#dddd#s#..
    ..#b#ss####ss#..
    ..#bb#ssssss#...
    .#bbbb######....
    #bbbbbbbbbbbb#..
    .############...
    """),
    sleep: parse("""
    .............w..
    ...........w....
    ......######....
    .....#ssssss#...
    ....#ss####ss#..
    ....#ss#dd#ss#..
    ....#s#dddd#s#..
    ....#ss####ss#..
    ..###ssssss#....
    .#bb#######.....
    #bbbbbbbbbbbb#..
    .############...
    """),
    palette: [
        "#": ink,
        "s": Color(red: 0.78, green: 0.55, blue: 0.31),
        "d": Color(red: 0.59, green: 0.37, blue: 0.20),
        "b": Color(red: 0.67, green: 0.78, blue: 0.47),
        "w": zColor
    ],
    gait: .walk,
    mirrors: true,
    hatAnchor: (column: 6, row: 0),
    speedFactor: 0.35
)

let dragonSprite = PetSprite(
    walkA: parse("""
    .......#..........
    ......##...##..##.
    .....#d#...#d##d#.
    ....#dd#..#rrrrrr#
    ...#ddd#..#r#rrrr#
    ..#dddd###rrrrrr##
    .#..#ddrrrrrrrr#y#
    #y#..#rrrrrrrr##..
    .#y##rryyyyyrr#...
    ..#y#rryyyyyr#....
    ....#rrrrrrr#.....
    .....#r#..#r#.....
    ......#....#......
    """),
    walkB: parse("""
    ...........##..##.
    ...........#d##d#.
    ..........#rrrrrr#
    ..........#r#rrrr#
    .....#####rrrrrr##
    ....#dddddrrrrr#y#
    .#..#ddrrrrrrrr##.
    #y#..#rrrrrrrr#...
    .#y##rryyyyyrr#...
    ..#y#rryyyyyr#....
    ....#rrrrrrr#.....
    ....#r#....#r#....
    .....#......#.....
    """),
    sit: parse("""
    .......#..........
    ......##...##..##.
    .....#d#...#d##d#.
    ....#dd#..#rrrrrr#
    ...#ddd#..#r#rrrr#
    ..#dddd###rrrrrr##
    .#..#ddrrrrrrrr#y#
    #y#..#rrrrrrrr##..
    .#y##rryyyyyrr#...
    ..#y#rryyyyyr#....
    ....#rrrrrrr#.....
    .....#r#..#r#.....
    ......#....#......
    """),
    sleep: parse("""
    .............w....
    ...........w......
    ......##..##......
    ......#d##d#......
    ....##rrrrrr###...
    ...#rrr##rrrrrr#..
    ..#rrrrrrrrrrrrr#.
    .#rryyyyyyyrrrdd#.
    ..#ryyyyyyyrrr##..
    ...#############..
    """),
    palette: [
        "#": ink,
        "r": Color(red: 0.90, green: 0.31, blue: 0.24),
        "d": Color(red: 0.67, green: 0.16, blue: 0.14),
        "y": Color(red: 1.0, green: 0.78, blue: 0.31),
        "w": zColor
    ],
    gait: .float,
    mirrors: true,
    hatAnchor: (column: 11, row: 1),
    hatSink: 1
)

let eggSprite = PetSprite(
    walkA: parse("""
    ...####...
    ..#wwww#..
    .#wwwwww#.
    .#wowwow#.
    #wwwwwwww#
    #wwwowwww#
    #wwwwwoww#
    .#wwwwww#.
    ..######..
    """),
    walkB: parse("""
    ..####....
    .#wwww#...
    .#wwwwww#.
    .#wowwow#.
    #wwwwwwww#
    #wwwowwww#
    #wwwwwoww#
    .#wwwwww#.
    ..######..
    """),
    sit: parse("""
    ...####...
    ..#wwww#..
    .#wwwwww#.
    .#wowwow#.
    #wwwwwwww#
    #wwwowwww#
    #wwwwwoww#
    .#wwwwww#.
    ..######..
    """),
    sleep: parse("""
    ...####...
    ..#wwww#..
    .#wwwwww#.
    .#wowwow#.
    #wwwwwwww#
    #wwwowwww#
    #wwwwwoww#
    .#wwwwww#.
    ..######..
    """),
    palette: [
        "#": ink,
        "w": Color(red: 0.98, green: 0.95, blue: 0.88),
        "o": Color(red: 0.86, green: 0.76, blue: 0.59)
    ],
    gait: .walk,
    mirrors: false,
    hatAnchor: (column: 3, row: 0),
    speedFactor: 0.5
)

let otterSprite = PetSprite(
    walkA: parse("""
    .............###...
    ............#ooo##.
    ............#o#oo#.
    ............#oolll#
    ....###.....#ooo##.
    ..##ooo####ooooo#..
    .#oo#ooooooooooo#..
    #oo#olllllllloo#...
    .##.#oooooooooo#...
    ....#o#oo##oo#o#...
    ....##.##..##.##...
    """),
    walkB: parse("""
    .............###...
    ............#ooo##.
    ............#o#oo#.
    ............#oolll#
    ....###.....#ooo##.
    ..##ooo####ooooo#..
    .#oo#ooooooooooo#..
    #oo#olllllllloo#...
    .##.#oooooooooo#...
    ...#o#oo#..#oo#o#..
    ...##.##....##.##..
    """),
    sit: parse("""
    .............###...
    ............#ooo##.
    ............#o#oo#.
    ............#oolll#
    ....###.....#ooo##.
    ..##ooo####ooooo#..
    .#oo#ooooooooooo#..
    #oo#olllllllloo#...
    .##.#oooooooooo#...
    ....#o#oo##oo#o#...
    ....##.##..##.##...
    """),
    sleep: parse("""
    ..............w....
    ............w......
    .....#########.....
    ...##lllllllll##...
    ..#lll#ll#ll#lll#..
    .#oll#oo##oo#llo#..
    .#oolllllllllloo#..
    #oo#ollllllllo#oo#.
    .#o##oooooooo##o#..
    ..##############...
    """),
    palette: [
        "#": ink,
        "o": Color(red: 0.55, green: 0.37, blue: 0.24),
        "l": Color(red: 0.80, green: 0.67, blue: 0.49),
        "w": zColor
    ],
    gait: .walk,
    mirrors: true,
    hatAnchor: (column: 12, row: 0)
)

let unicornSprite = PetSprite(
    // UNICORN-REDRAW: the old art grew the horn out of the BACK of the skull
    // and parked the head mid-left on a right-facing body, which read as a
    // white blob with a pink smear. Rebuilt on the cat/dog skeleton: head on
    // the right, horn on the forehead, mane cascading down the neck, tail left.
    walkA: parse("""
    ...............#y..
    ..............#y#..
    ...........####y#..
    ..........#pppww#..
    .........#ppw#ww##.
    .#p......#ppwwwww#.
    .#pp..####ppwww##..
    ..#pp#wwwwwwww#....
    ...#wwwwwwwwww#....
    ...#wwwwwwwwww#....
    ....##########.....
    ....#w#....#w#.....
    ....##.....##......
    """),
    walkB: parse("""
    ...............#y..
    ..............#y#..
    ...........####y#..
    ..........#pppww#..
    .........#ppw#ww##.
    .#p......#ppwwwww#.
    .#pp..####ppwww##..
    ..#pp#wwwwwwww#....
    ...#wwwwwwwwww#....
    ...#wwwwwwwwww#....
    ....##########.....
    ...#w#......#w#....
    ...##.......##.....
    """),
    sit: parse("""
    ...............#y..
    ..............#y#..
    ...........####y#..
    ..........#pppww#..
    .........#ppw#ww##.
    .#p......#ppwwwww#.
    .#pp..####ppwww##..
    ..#pp#wwwwwwww#....
    ...#wwwwwwwwwww#...
    ....#wwwwwwwww#....
    ....#w#ww#ww#w#....
    ....##..##...##....
    """),
    sleep: parse("""
    ..............w....
    ............w......
    ......#y...........
    .....#y#...........
    ....#y####.........
    ....#pp#ww##.......
    ....#pppww#w#......
    ...##pp##www#......
    ..#wwwwwwwwwww##...
    .#pwwwwwwwwwwwww#..
    .#ppwwwwwwwwwwww#..
    ..###############..
    """),
    palette: [
        "#": ink,
        "w": Color(red: 0.98, green: 0.97, blue: 0.96),
        "p": Color(red: 1.0, green: 0.51, blue: 0.71),
        "y": Color(red: 1.0, green: 0.78, blue: 0.24),
        "g": Color(red: 0.86, green: 0.84, blue: 0.89)
    ],
    gait: .walk,
    mirrors: true,
    hatAnchor: (column: 11, row: 2)
)

// CLAWD: Clawd is Anthropic's Claude Code mascot, included as a fan tribute
// (not affiliated with or endorsed by Anthropic) and removed on request; see
// THIRD_PARTY_NOTICES.md. The walkA grid follows the mascot's logo artwork
// (11x9 logical cells, coral #D97757), minus the sticker border.
// walkB steps the inner legs, sit tucks them, sleep closes the eyes into
// dashes like the squint variant of the logo.
let clawdSprite = PetSprite(
    // Full ink contour all the way around, per request: legs widened to 2px
    // (the sprite grew slightly) so the outline can wrap every edge, tab,
    // leg, and notch without drowning the coral. Silhouette proportions
    // still follow assets/logos/coding-tools/claude-code.png.
    walkA: parse("""
    ..#############..
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#cc##ccccc##cc#.
    #ccc##ccccc##ccc#
    #ccccccccccccccc#
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#cc#cc###cc#cc#.
    .#cc#cc#.#cc#cc#.
    ..##.##...##.##..
    """),
    walkB: parse("""
    ..#############..
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#cc##ccccc##cc#.
    #ccc##ccccc##ccc#
    #ccccccccccccccc#
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#cc#cc###cc#cc#.
    .#cc###...###cc#.
    ..##.........##..
    """),
    sit: parse("""
    ..#############..
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#cc##ccccc##cc#.
    #ccc##ccccc##ccc#
    #ccccccccccccccc#
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#cc#cc###cc#cc#.
    ..##.##...##.##..
    """),
    sleep: parse("""
    ...............w.
    ..............w..
    ..#############..
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    #ccc##ccccc##ccc#
    #ccccccccccccccc#
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#ccccccccccccc#.
    .#cc#cc###cc#cc#.
    ..##.##...##.##..
    """),
    palette: [
        "#": ink,
        "c": Color(red: 0.851, green: 0.467, blue: 0.341),
        "w": zColor
    ],
    gait: .walk,
    mirrors: false,
    hatAnchor: (column: 5, row: 0)
)

func petSprite(for kind: PetKind) -> PetSprite? {
    switch kind {
    case .none: nil
    case .cat: catSprite
    case .dog: dogSprite
    case .ghost: ghostSprite
    case .penguin: penguinSprite
    case .fox: foxSprite
    case .frog: frogSprite
    case .crab: crabSprite
    case .robot: robotSprite
    case .dino: dinoSprite
    case .duck: duckSprite
    case .snail: snailSprite
    case .otter: otterSprite
    case .dragon: dragonSprite
    case .unicorn: unicornSprite
    case .clawd: clawdSprite
    }
}

private func sprite(for kind: PetKind) -> PetSprite? {
    petSprite(for: kind)
}
