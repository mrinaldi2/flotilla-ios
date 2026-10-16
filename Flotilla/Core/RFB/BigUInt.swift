import Foundation

/// Just enough unsigned big-integer arithmetic for the Diffie-Hellman step of
/// macOS Screen Sharing's sign-in: parse, multiply, reduce, raise to a power.
/// Little-endian 32-bit limbs; remainder by Knuth's algorithm D.
struct BigUInt: Equatable {
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        self.limbs = limbs
        trim()
    }

    /// Big-endian bytes, as they travel on the wire.
    init(bytes: [UInt8]) {
        var limbs: [UInt32] = []
        var index = bytes.count
        while index > 0 {
            let start = max(0, index - 4)
            var limb: UInt32 = 0
            for byte in bytes[start..<index] { limb = limb << 8 | UInt32(byte) }
            limbs.append(limb)
            index = start
        }
        self.init(limbs: limbs)
    }

    /// Big-endian bytes, left-padded (or truncated from the left) to `length`.
    func bytes(length: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            out += [UInt8(limb >> 24), UInt8(limb >> 16 & 0xFF), UInt8(limb >> 8 & 0xFF), UInt8(limb & 0xFF)]
        }
        while let first = out.first, first == 0, out.count > 1 { out.removeFirst() }
        if out == [0] { out = [] }
        if out.count >= length { return Array(out.suffix(length)) }
        return [UInt8](repeating: 0, count: length - out.count) + out
    }

    var isZero: Bool { limbs.isEmpty }

    private mutating func trim() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return BigUInt(limbs: []) }
        var out = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for (i, a) in lhs.limbs.enumerated() {
            var carry: UInt64 = 0
            for (j, b) in rhs.limbs.enumerated() {
                let t = UInt64(a) * UInt64(b) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            out[i + rhs.limbs.count] = UInt32(truncatingIfNeeded: carry)
        }
        return BigUInt(limbs: out)
    }

    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(!rhs.isZero, "division by zero")
        let u = lhs.limbs, v = rhs.limbs
        let n = v.count, m = u.count
        if m < n { return lhs }
        if n == 1 {
            var rem: UInt64 = 0
            for limb in u.reversed() { rem = (rem << 32 | UInt64(limb)) % UInt64(v[0]) }
            return BigUInt(limbs: [UInt32(rem)])
        }
        let shift = UInt32(v[n - 1].leadingZeroBitCount)
        var vn = [UInt32](repeating: 0, count: n)
        for i in stride(from: n - 1, to: 0, by: -1) {
            vn[i] = shift == 0 ? v[i] : (v[i] << shift) | (v[i - 1] >> (32 - shift))
        }
        vn[0] = v[0] << shift
        var un = [UInt32](repeating: 0, count: m + 1)
        un[m] = shift == 0 ? 0 : u[m - 1] >> (32 - shift)
        for i in stride(from: m - 1, to: 0, by: -1) {
            un[i] = shift == 0 ? u[i] : (u[i] << shift) | (u[i - 1] >> (32 - shift))
        }
        un[0] = u[0] << shift

        let base: UInt64 = 1 << 32
        for j in stride(from: m - n, through: 0, by: -1) {
            let numerator = UInt64(un[j + n]) << 32 | UInt64(un[j + n - 1])
            var qhat = numerator / UInt64(vn[n - 1])
            var rhat = numerator - qhat * UInt64(vn[n - 1])
            while qhat >= base || qhat * UInt64(vn[n - 2]) > (rhat << 32 | UInt64(un[j + n - 2])) {
                qhat -= 1
                rhat += UInt64(vn[n - 1])
                if rhat >= base { break }
            }
            var borrow: Int64 = 0
            var t: Int64 = 0
            for i in 0..<n {
                let p = qhat * UInt64(vn[i])
                t = Int64(un[i + j]) - borrow - Int64(p & 0xFFFF_FFFF)
                un[i + j] = UInt32(truncatingIfNeeded: t)
                borrow = Int64(p >> 32) - (t >> 32)
            }
            t = Int64(un[j + n]) - borrow
            un[j + n] = UInt32(truncatingIfNeeded: t)
            if t < 0 {
                var carry: UInt64 = 0
                for i in 0..<n {
                    let s = UInt64(un[i + j]) + UInt64(vn[i]) + carry
                    un[i + j] = UInt32(truncatingIfNeeded: s)
                    carry = s >> 32
                }
                un[j + n] = UInt32(truncatingIfNeeded: UInt64(un[j + n]) + carry)
            }
        }
        var remainder = [UInt32](repeating: 0, count: n)
        for i in 0..<n {
            remainder[i] = shift == 0 ? un[i] : (un[i] >> shift) | (un[i + 1] << (32 - shift))
        }
        return BigUInt(limbs: remainder)
    }

    /// self^exponent mod modulus, the exponent given as big-endian bytes.
    func power(_ exponent: [UInt8], modulus: BigUInt) -> BigUInt {
        var result = BigUInt(limbs: [1]) % modulus
        let base = self % modulus
        for byte in exponent {
            for bit in stride(from: 7, through: 0, by: -1) {
                result = (result * result) % modulus
                if byte >> UInt8(bit) & 1 == 1 { result = (result * base) % modulus }
            }
        }
        return result
    }
}
