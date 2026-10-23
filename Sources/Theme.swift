import SwiftUI

let amber = Color(red: 1, green: 0.69, blue: 0)
let rowBG = Color(white: 0.09)

/// Receiver row used in the Atlas, favorites and the import picker.
struct ReceiverRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var favorite = false
    var onAir = false            // the receiver that was listened to last

    var body: some View {
        HStack(spacing: 12) {
            if onAir {
                OnAirBadge(size: 36)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(amber)
                    .frame(width: 36, height: 36)
                    .background(amber.opacity(0.14), in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if favorite { Image(systemName: "star.fill").font(.caption).foregroundColor(amber) }
        }
        .padding(.vertical, 2)
    }
}

/// Menu row: icon, title, subtitle (and an optional trailing symbol).
struct ActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold)).foregroundColor(amber)
                .frame(width: 36, height: 36)
                .background(amber.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundColor(.primary)
                Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer()
            if let t = trailing {
                Image(systemName: t).font(.footnote.weight(.semibold)).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct GMTClock: View {
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 5) {
                Text(Self.fmt.string(from: ctx.date))
                    .font(.system(.headline, design: .monospaced))
                    .foregroundColor(.white)
                Text("GMT").font(.caption2.weight(.semibold)).foregroundColor(amber)
            }
        }
    }
}

/// Broadcast tower drawn with lines (works on every iOS version).
struct TowerShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: r.minX + CGFloat(x) * w, y: r.minY + CGFloat(y) * h)
        }
        var p = Path()
        p.move(to: pt(0.5, 0.34)); p.addLine(to: pt(0.30, 0.92))
        p.move(to: pt(0.5, 0.34)); p.addLine(to: pt(0.70, 0.92))
        for y in [0.52, 0.68, 0.84] {
            let half = 0.20 * (y - 0.34) / 0.58
            p.move(to: pt(0.5 - half, y)); p.addLine(to: pt(0.5 + half, y))
        }
        let c = pt(0.5, 0.26)
        for radius in [0.14, 0.24] {
            let rad = CGFloat(radius) * w
            for (start, end) in [(-45.0, 45.0), (135.0, 225.0)] {
                let a0 = start * Double.pi / 180
                p.move(to: CGPoint(x: c.x + rad * CGFloat(cos(a0)), y: c.y + rad * CGFloat(sin(a0))))
                p.addArc(center: c, radius: rad, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
            }
        }
        return p
    }
}

/// Red broadcast tower on a white disc ("on air").
struct OnAirBadge: View {
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().fill(Color.white)
            TowerShape()
                .stroke(Color.red, style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round, lineJoin: .round))
                .padding(size * 0.12)
            Circle().fill(Color.red)
                .frame(width: size * 0.11, height: size * 0.11)
                .offset(y: -size * 0.182)
        }
        .frame(width: size, height: size)
    }
}
