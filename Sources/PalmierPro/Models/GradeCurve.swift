import CoreImage
import Foundation

struct CurvePoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
}

/// Master (Rec.709 luma) + per-channel R/G/B tone curves, compiled to a `CIColorCube`.
struct GradeCurve: Codable, Sendable, Equatable {
    var master: [CurvePoint] = []
    var red: [CurvePoint] = []
    var green: [CurvePoint] = []
    var blue: [CurvePoint] = []

    static let identityPoints = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    var isIdentity: Bool {
        [master, red, green, blue].allSatisfy { $0.isEmpty || $0 == Self.identityPoints }
    }

    /// Piecewise-linear interpolation, clamped flat outside the point range.
    static func eval(_ pts: [CurvePoint], _ x: Double) -> Double {
        let p = (pts.isEmpty ? identityPoints : pts).sorted { $0.x < $1.x }
        if x <= p[0].x { return p[0].y }
        if x >= p[p.count - 1].x { return p[p.count - 1].y }
        for i in 1..<p.count where x <= p[i].x {
            let a = p[i - 1], b = p[i]
            let t = (b.x - a.x) == 0 ? 0 : (x - a.x) / (b.x - a.x)
            return a.y + (b.y - a.y) * t
        }
        return x
    }

    func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// RGBA float32 cube (red fastest) for `CIColorCube`; nil when identity. `master` is a luma curve.
    func cubeData(dimension n: Int = 17) -> (dimension: Int, data: Data)? {
        guard !isIdentity else { return nil }
        func clamp(_ v: Double) -> Float { Float(min(1, max(0, v))) }
        let hasMaster = !(master.isEmpty || master == Self.identityPoints)
        var table = [Float]()
        table.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    var rf = Double(r) / Double(n - 1)
                    var gf = Double(g) / Double(n - 1)
                    var bf = Double(b) / Double(n - 1)
                    if hasMaster {
                        let y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                        let yp = Self.eval(master, y)
                        if y > 1e-5 {
                            let f = yp / y
                            rf *= f; gf *= f; bf *= f
                        } else {
                            rf = yp; gf = yp; bf = yp  // no chroma to preserve → neutral
                        }
                    }
                    table.append(clamp(Self.eval(red, rf)))
                    table.append(clamp(Self.eval(green, gf)))
                    table.append(clamp(Self.eval(blue, bf)))
                    table.append(1)
                }
            }
        }
        return (n, table.withUnsafeBytes { Data($0) })
    }
}

/// Failable JSON init kept in an extension so the memberwise initializer survives.
extension GradeCurve {
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(GradeCurve.self, from: data) else { return nil }
        self = decoded
    }
}

/// Caches compiled cubes by curve JSON so the 17³ table builds once per curve, not per frame.
enum CurveLUTCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (Int, Data)] = [:]

    static func cube(forJSON json: String) -> (dimension: Int, data: Data)? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[json] { return hit }
        guard let curve = GradeCurve(json: json), let cube = curve.cubeData() else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[json] = cube
        return cube
    }
}
