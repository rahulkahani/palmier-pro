import CoreImage
import Foundation

/// Lift/Gamma/Gain primary color wheels compiled to a `CIColorCube`.
/// Each wheel is a luma-neutral chroma offset (its pad position) plus a master luma
/// scalar; combined per channel as `((in·(1−L) + L) · Gain) ^ (1/Gamma)`.
enum ColorWheels {
    static let dimension = 33

    private static let chromaLift = 0.2
    private static let chromaGain = 0.35
    private static let chromaGamma = 0.35

    /// Fully-saturated hue at `h ∈ [0,1)`.
    static func hueRGB(_ h: Double) -> (Double, Double, Double) {
        let x = (h - floor(h)) * 6
        let f = x - floor(x)
        switch Int(x) % 6 {
        case 0: return (1, f, 0)
        case 1: return (1 - f, 1, 0)
        case 2: return (0, 1, f)
        case 3: return (0, 1 - f, 1)
        case 4: return (f, 0, 1)
        default: return (1, 0, 1 - f)
        }
    }

    /// Luma-neutral per-channel offset for a pad position (angle = hue, radius = strength).
    static func chromaOffset(x: Double, y: Double) -> (Double, Double, Double) {
        let r = min(1, (x * x + y * y).squareRoot())
        guard r > 1e-6 else { return (0, 0, 0) }
        let (cr, cg, cb) = hueRGB(atan2(y, x) / (2 * .pi))
        let mean = (cr + cg + cb) / 3
        return ((cr - mean) * r, (cg - mean) * r, (cb - mean) * r)
    }

    /// Wheel-face color — a dark, lightly tinted body fading to a vivid saturated rim (DaVinci-style).
    static func displayColor(x: Double, y: Double) -> (Double, Double, Double) {
        let r = min(1, (x * x + y * y).squareRoot())
        let (hr, hg, hb) = hueRGB(atan2(y, x) / (2 * .pi))
        let v = 0.08 + 0.5 * pow(r, 1.7)
        let s = pow(r, 1.4)
        let rim = rimRamp((r - 0.86) / 0.14)
        func face(_ h: Double) -> Double {
            let body = v * ((1 - s) + h * s)
            return body + (h - body) * rim
        }
        return (face(hr), face(hg), face(hb))
    }

    private static func rimRamp(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    /// Cached 33³ cube for the resolved wheel params; nil when neutral.
    static func cube(for p: ResolvedEffectParams) -> (dimension: Int, data: Data)? {
        guard !isNeutral(p) else { return nil }
        return Cache.cube(for: p)
    }

    private static func isNeutral(_ p: ResolvedEffectParams) -> Bool {
        p.value("lift_x") == 0 && p.value("lift_y") == 0 && p.value("lift_m") == 0 &&
        p.value("gamma_x") == 0 && p.value("gamma_y") == 0 && p.value("gamma_m") == 1 &&
        p.value("gain_x") == 0 && p.value("gain_y") == 0 && p.value("gain_m") == 1
    }

    private static func cacheKey(_ p: ResolvedEffectParams) -> String {
        ["lift_x", "lift_y", "lift_m", "gamma_x", "gamma_y", "gamma_m", "gain_x", "gain_y", "gain_m"]
            .map { String(format: "%.4f", p.value($0)) }
            .joined(separator: ",")
    }

    private static func cubeData(_ p: ResolvedEffectParams) -> (Int, Data) {
        let n = dimension
        let lift = chromaOffset(x: p.value("lift_x"), y: p.value("lift_y"))
        let gamma = chromaOffset(x: p.value("gamma_x"), y: p.value("gamma_y"))
        let gain = chromaOffset(x: p.value("gain_x"), y: p.value("gain_y"))
        let liftM = p.value("lift_m"), gammaM = p.value("gamma_m"), gainM = p.value("gain_m")

        func channelLUT(_ liftC: Double, _ gammaC: Double, _ gainC: Double) -> [Float] {
            let l = liftM + liftC * chromaLift
            let g = gainM * (1 + gainC * chromaGain)
            let invGamma = 1 / max(0.01, gammaM * (1 + gammaC * chromaGamma))
            return (0..<n).map { i in
                let v = Double(i) / Double(n - 1)
                let lit = max(0, v * (1 - l) + l) * g
                return Float(min(1, max(0, pow(lit, invGamma))))
            }
        }
        let lutR = channelLUT(lift.0, gamma.0, gain.0)
        let lutG = channelLUT(lift.1, gamma.1, gain.1)
        let lutB = channelLUT(lift.2, gamma.2, gain.2)

        var table = [Float]()
        table.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    table.append(lutR[r]); table.append(lutG[g]); table.append(lutB[b]); table.append(1)
                }
            }
        }
        return (n, table.withUnsafeBytes { Data($0) })
    }

    /// Caches compiled cubes by param values so the table builds once per grade, not per frame.
    private enum Cache {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var store: [String: (Int, Data)] = [:]

        static func cube(for p: ResolvedEffectParams) -> (dimension: Int, data: Data) {
            let key = cacheKey(p)
            lock.lock(); defer { lock.unlock() }
            if let hit = store[key] { return hit }
            if store.count > 64 { store.removeAll() }
            let cube = cubeData(p)
            store[key] = cube
            return cube
        }
    }
}
