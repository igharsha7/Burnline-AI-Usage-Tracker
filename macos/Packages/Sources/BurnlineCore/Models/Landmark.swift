//
//  Landmark.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// Everything ever processed, printed and stacked: the measure the Activity
/// page's climb is drawn in and the Landmarks medals are awarded by. The
/// constants match the comparison corpus's paper stack, which a test holds
/// them to.
public enum PaperStack {
    public static let tokensPerWord = 1.3
    public static let wordsPerPage = 500.0
    /// 80gsm paper, about a tenth of a millimetre a sheet.
    public static let sheetMeters = 0.0001

    public static func meters(tokens: Int64) -> Double {
        Double(tokens) / tokensPerWord / wordsPerPage * sheetMeters
    }

    /// The tokens whose stack stands `meters` tall.
    public static func tokens(meters: Double) -> Int64 {
        Int64((meters / sheetMeters * wordsPerPage * tokensPerWord).rounded(.up))
    }
}

/// A height the stack can pass, from a leaning tower to orbit.
public struct Landmark: Hashable, Sendable, Identifiable {
    /// How the landmark is drawn.
    public enum Silhouette: String, Sendable {
        case leaningTower, statue, pyramid, needle, bridgeTower, lattice, steppedTower, pagoda, twistedTower, spire
        case waterfall, tableMountain, volcano, observatory, halfDome, cone, horn, snowDome, mountain
        case airliner, concorde, weatherBalloon, recordBalloon, edgeOfSpace, satellite, orbit

        /// Whether it flies at its height rather than standing that tall.
        public var flies: Bool {
            switch self {
            case .airliner, .concorde, .weatherBalloon, .recordBalloon, .edgeOfSpace, .satellite, .orbit: true
            default: false
            }
        }
    }

    public let id: String
    public let name: String
    public let meters: Double
    public let silhouette: Silhouette

    /// The tokens that stack this high: the medal's threshold.
    public var tokens: Int64 { PaperStack.tokens(meters: meters) }

    /// Shortest first: the buildings, then the falls and the mountains up to
    /// Everest, then what flies, out to orbit. Each is at most about twice
    /// the one before, so the climb is never long without one ahead.
    public static let all: [Landmark] = [
        Landmark(id: "pisa", name: "Tower of Pisa", meters: 56, silhouette: .leaningTower),
        Landmark(id: "liberty", name: "Statue of Liberty", meters: 93, silhouette: .statue),
        Landmark(id: "pyramid", name: "Great Pyramid", meters: 139, silhouette: .pyramid),
        Landmark(id: "needle", name: "Space Needle", meters: 184, silhouette: .needle),
        Landmark(id: "goldengate", name: "Golden Gate Bridge", meters: 227, silhouette: .bridgeTower),
        Landmark(id: "eiffel", name: "Eiffel Tower", meters: 330, silhouette: .lattice),
        Landmark(id: "empire", name: "Empire State", meters: 443, silhouette: .steppedTower),
        Landmark(id: "taipei", name: "Taipei 101", meters: 508, silhouette: .pagoda),
        Landmark(id: "shanghai", name: "Shanghai Tower", meters: 632, silhouette: .twistedTower),
        Landmark(id: "burj", name: "Burj Khalifa", meters: 828, silhouette: .spire),
        Landmark(id: "angel", name: "Angel Falls", meters: 979, silhouette: .waterfall),
        Landmark(id: "table", name: "Table Mountain", meters: 1_085, silhouette: .tableMountain),
        Landmark(id: "vesuvius", name: "Mount Vesuvius", meters: 1_281, silhouette: .volcano),
        Landmark(id: "washington", name: "Mount Washington", meters: 1_917, silhouette: .observatory),
        Landmark(id: "halfdome", name: "Half Dome", meters: 2_696, silhouette: .halfDome),
        Landmark(id: "fuji", name: "Mount Fuji", meters: 3_776, silhouette: .cone),
        Landmark(id: "matterhorn", name: "Matterhorn", meters: 4_478, silhouette: .horn),
        Landmark(id: "kilimanjaro", name: "Kilimanjaro", meters: 5_895, silhouette: .snowDome),
        Landmark(id: "everest", name: "Mount Everest", meters: 8_849, silhouette: .mountain),
        Landmark(id: "cruise", name: "Cruising Altitude", meters: 10_700, silhouette: .airliner),
        Landmark(id: "concorde", name: "Concorde", meters: 18_300, silhouette: .concorde),
        Landmark(id: "weatherballoon", name: "Weather Balloon", meters: 30_000, silhouette: .weatherBalloon),
        Landmark(id: "recordballoon", name: "Record Balloon", meters: 53_000, silhouette: .recordBalloon),
        Landmark(id: "karman", name: "Edge of Space", meters: 100_000, silhouette: .edgeOfSpace),
        Landmark(id: "sputnik", name: "Sputnik 1", meters: 215_000, silhouette: .satellite),
        Landmark(id: "iss", name: "Space Station", meters: 408_000, silhouette: .orbit),
    ]
}

/// The stack's climb over every tracked day: its height as it grew, the day
/// it passed each landmark, and what is next.
public struct Climb: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let at: Timestamp
        public let meters: Double
    }

    /// The height at the end of each day, thinned to at most `maximumPoints`
    /// with the first and last day kept, so a long history draws as cheaply
    /// as a short one.
    public let points: [Point]
    public let meters: Double
    /// When the stack first stood past each landmark, by its id.
    public let passed: [String: Timestamp]

    public init(days: [ActivityDay], maximumPoints: Int = 160) {
        var total: Int64 = 0
        var heights: [Point] = []
        var passed: [String: Timestamp] = [:]
        var remaining = Landmark.all[...]
        for day in days {
            let (sum, overflow) = total.addingReportingOverflow(day.totals.tokens.processed)
            total = overflow ? .max : sum
            while let landmark = remaining.first, total >= landmark.tokens {
                passed[landmark.id] = day.window.start
                remaining.removeFirst()
            }
            heights.append(Point(at: day.window.start, meters: PaperStack.meters(tokens: total)))
        }
        let stride = max(1, Int((Double(heights.count) / Double(max(2, maximumPoints))).rounded(.up)))
        var thinned = Swift.stride(from: 0, to: heights.count, by: stride).map { heights[$0] }
        if let last = heights.last, thinned.last != last { thinned.append(last) }
        points = thinned
        meters = PaperStack.meters(tokens: total)
        self.passed = passed
    }

    private init(points: [Point], meters: Double, passed: [String: Timestamp]) {
        self.points = points
        self.meters = meters
        self.passed = passed
    }

    /// The climb as it stood at `at`: the days up to it, the height part
    /// way between the two days around it, and the landmarks passed by
    /// then. The Activity page's replay draws one each frame.
    public func asOf(_ at: Timestamp) -> Climb {
        guard let first = points.first else { return self }
        let at = max(at, first.at)
        let before = points.lastIndex { $0.at <= at } ?? 0
        var height = points[before].meters
        if before + 1 < points.count {
            let from = points[before], to = points[before + 1]
            let share = Double(at.epochSeconds - from.at.epochSeconds) / Double(to.at.epochSeconds - from.at.epochSeconds)
            height = from.meters + (to.meters - from.meters) * share
        }
        var shown = Array(points[...before])
        if at > points[before].at { shown.append(Point(at: at, meters: height)) }
        // By height, so a landmark the height has reached is always passed,
        // on its day or, between thinned points, at the latest now.
        let reached = Landmark.all.filter { $0.meters <= height }
        let passedThen = Dictionary(uniqueKeysWithValues: reached.compactMap { landmark in
            passed[landmark.id].map { (landmark.id, min($0, at)) }
        })
        return Climb(points: shown, meters: height, passed: passedThen)
    }

    /// The next landmark up, nil above them all.
    public var next: Landmark? { Landmark.all.first { $0.meters > meters } }

    /// The last landmark passed, nil below the first.
    public var lastPassed: Landmark? { Landmark.all.last { $0.meters <= meters } }

    /// The metres climbed over the last `days` of the climb and the days
    /// that span covers; nil with under a week of history in it, or nothing
    /// climbed.
    public func climbed(days: Int = 30) -> (meters: Double, days: Double)? {
        guard let last = points.last,
              let from = points.first(where: { $0.at.epochSeconds >= last.at.epochSeconds - Int64(days) * 86_400 })
        else { return nil }
        let elapsed = Double(last.at.epochSeconds - from.at.epochSeconds) / 86_400
        let climbed = last.meters - from.meters
        guard elapsed >= 7, climbed > 0 else { return nil }
        return (climbed, elapsed)
    }

    /// Metres a day over the last `days` of the climb.
    public func pace(days: Int = 30) -> Double? {
        climbed(days: days).map { $0.meters / $0.days }
    }

    /// When the stack would reach the next landmark at `pace` metres a day.
    public func arrival(pace: Double) -> Timestamp? {
        guard let next, let last = points.last, pace > 0 else { return nil }
        let days = (next.meters - meters) / pace
        guard days < 36_500 else { return nil }
        return Timestamp(epochSeconds: last.at.epochSeconds + Int64(days * 86_400))
    }

    /// How far from the last landmark passed to the next, 0 to 1.
    public var towardNext: Double {
        guard let next else { return 1 }
        let floor = Landmark.all.last { $0.meters <= meters }?.meters ?? 0
        return max(0, min(1, (meters - floor) / (next.meters - floor)))
    }
}
