import Foundation

enum ExifEnumLabels {
    private static let exposureProgram: [Int: String] = [
        0: "Not Defined",
        1: "Manual",
        2: "Program AE",
        3: "Aperture-priority AE",
        4: "Shutter speed priority AE",
        5: "Creative (Slow speed)",
        6: "Action (High speed)",
        7: "Portrait",
        8: "Landscape",
        9: "Bulb",
    ]

    private static let flash: [Int: String] = [
        0: "No Flash",
        1: "Fired",
        5: "Fired, Return not detected",
        7: "Fired, Return detected",
        8: "On, Did not fire",
        9: "On, Fired",
        13: "On, Return not detected",
        15: "On, Return detected",
        16: "Off, Did not fire",
        20: "Off, Did not fire, Return not detected",
        24: "Auto, Did not fire",
        25: "Auto, Fired",
        29: "Auto, Fired, Return not detected",
        31: "Auto, Fired, Return detected",
        32: "No flash function",
        48: "Off, No flash function",
        65: "Fired, Red-eye reduction",
        69: "Fired, Red-eye reduction, Return not detected",
        71: "Fired, Red-eye reduction, Return detected",
        73: "On, Red-eye reduction",
        77: "On, Red-eye reduction, Return not detected",
        79: "On, Red-eye reduction, Return detected",
        80: "Off, Red-eye reduction",
        88: "Auto, Did not fire, Red-eye reduction",
        89: "Auto, Fired, Red-eye reduction",
        93: "Auto, Fired, Red-eye reduction, Return not detected",
        95: "Auto, Fired, Return detected",
    ]

    private static let meteringMode: [Int: String] = [
        0: "Unknown",
        1: "Average",
        2: "Center-weighted average",
        3: "Spot",
        4: "Multi-spot",
        5: "Multi-segment",
        6: "Partial",
        255: "Other",
    ]

    static func exposureProgram(_ rawValue: Int) -> String {
        exposureProgram[rawValue] ?? String(rawValue)
    }

    static func flash(_ rawValue: Int) -> String {
        flash[rawValue] ?? String(rawValue)
    }

    static func meteringMode(_ rawValue: Int) -> String {
        meteringMode[rawValue] ?? String(rawValue)
    }
}
