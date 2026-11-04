import SwiftUI

private let ink = Color(red: 0.07, green: 0.09, blue: 0.15)
private let muted = Color(red: 0.42, green: 0.45, blue: 0.5)
private let soft = Color(red: 0.945, green: 0.949, blue: 0.965)
private let seenGreen = Color(red: 0.09, green: 0.47, blue: 0.31)

private enum ChatRow: Identifiable {
    case day(id: String, label: String)
    case message(m: OctokanMessage, starts: Bool, ends: Bool, status: String?)
    case typing

    var id: String {
        switch self {
        case .day(let id, _): return "day-\(id)"
        case .message(let m, _, _, _): return m.id
        case .typing: return "typing"
        }
    }
}

private func dayLabel(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    let f = DateFormatter()
    f.dateFormat = "EEE, MMM d"
    return f.string(from: date)
}

private func clock(_ date: Date) -> String {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f.string(from: date)
}

/// Messages in order, with day dividers, bubble grouping and the delivery status of the last message.
private func buildRows(_ messages: [OctokanMessage], seenAt: Date?, typing: Bool) -> [ChatRow] {
    var rows: [ChatRow] = []
    let gap: TimeInterval = 5 * 60
    let cal = Calendar.current
    let lastMine = messages.lastIndex(where: { $0.fromVisitor })
    for (i, m) in messages.enumerated() {
        let prev = i > 0 ? messages[i - 1] : nil
        let next = i < messages.count - 1 ? messages[i + 1] : nil
        let newDay = prev == nil || !cal.isDate(prev!.at, inSameDayAs: m.at)
        if newDay { rows.append(.day(id: m.id, label: dayLabel(m.at))) }
        let starts = newDay || prev!.fromVisitor != m.fromVisitor || m.at.timeIntervalSince(prev!.at) > gap
        let ends = next == nil || next!.fromVisitor != m.fromVisitor || !cal.isDate(next!.at, inSameDayAs: m.at) || next!.at.timeIntervalSince(m.at) > gap
        var status: String?
        if i == lastMine {
            if m.pending { status = "Sending…" } else if let seenAt, seenAt >= m.at { status = "✓✓ Seen" } else { status = "✓ Sent" }
        }
        rows.append(.message(m: m, starts: starts, ends: ends, status: status))
    }
    if typing { rows.append(.typing) }
    return rows
}

/// Three dots that bounce one after another.
private struct BouncingDots: View {
    var color: Color = muted

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (sin(t * 6 - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .fill(color.opacity(0.35 + 0.65 * phase))
                        .frame(width: 7, height: 7)
                        .offset(y: -4 * phase)
                }
            }
        }
        .frame(height: 14)
    }
}

/// The chat screen. Embed it anywhere, or call `Octokan.presentChat()` to show it as a sheet.
public struct OctokanChatView: View {
    @StateObject private var model = OctokanChatModel()
    @State private var draft = ""
    @FocusState private var focused: Bool
    private let onClose: (() -> Void)?

    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            if let error = model.error {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer
        }
        .background(Color(.systemBackground))
        .task { await model.start() }
        .onDisappear { model.stop() }
    }

    private var initial: String { String((model.title.first ?? "S")).uppercased() }

    private func avatar(_ size: CGFloat, _ font: CGFloat) -> some View {
        Text(initial)
            .font(.system(size: font, weight: .heavy))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(model.accent, in: Circle())
    }

    private var header: some View {
        HStack(spacing: 12) {
            avatar(40, 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.system(size: 17, weight: .bold)).foregroundColor(ink)
                if model.typing {
                    HStack(spacing: 6) {
                        Text("typing").font(.system(size: 12, weight: .semibold)).foregroundColor(seenGreen)
                        BouncingDots(color: seenGreen)
                    }
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("We usually reply within minutes").font(.system(size: 12)).foregroundColor(muted)
                    }
                }
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundColor(muted)
                        .frame(width: 32, height: 32)
                        .background(soft, in: Circle())
                }
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var conversation: some View {
        let rows = buildRows(model.messages, seenAt: model.seenAt, typing: model.typing)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    welcome
                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.id)
                            .transition(.scale(scale: 0.94, anchor: .bottom).combined(with: .opacity))
                    }
                }
                .padding(16)
                .animation(.spring(response: 0.35, dampingFraction: 0.78), value: rows.count)
            }
            .onChange(of: rows.count) { _ in
                if let last = rows.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 10) {
            Text("👋").font(.system(size: 26)).frame(width: 56, height: 56).background(model.accent, in: Circle())
            Text(model.welcome).font(.system(size: 15)).foregroundColor(Color(red: 0.22, green: 0.25, blue: 0.32)).multilineTextAlignment(.center).frame(maxWidth: 300)
            if model.messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        starter("🐞", "Report a problem", "Something isn't working: ")
                        starter("💡", "Share an idea", "I have an idea: ")
                        starter("❓", "Ask a question", "I have a question: ")
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.top, 6)
            }
        }
        .padding(.bottom, 8)
    }

    private func starter(_ emoji: String, _ label: String, _ prefill: String) -> some View {
        Button {
            draft = prefill
            focused = true
        } label: {
            HStack(spacing: 6) {
                Text(emoji)
                Text(label).font(.system(size: 14, weight: .semibold)).foregroundColor(ink)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(soft, in: Capsule())
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row {
        case .day(_, let label):
            HStack(spacing: 10) {
                Rectangle().fill(Color(.separator)).frame(height: 1)
                Text(label.uppercased()).font(.system(size: 11, weight: .bold)).foregroundColor(Color(.tertiaryLabel))
                Rectangle().fill(Color(.separator)).frame(height: 1)
            }
            .padding(.vertical, 14)
        case .typing:
            HStack(alignment: .bottom, spacing: 8) {
                avatar(28, 12)
                BouncingDots()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(soft, in: bubbleShape(mine: false, ends: true))
                Spacer()
            }
            .padding(.top, 12)
        case .message(let m, let starts, let ends, let status):
            bubble(m, starts: starts, ends: ends, status: status)
        }
    }

    private func bubbleShape(mine: Bool, ends: Bool) -> some Shape {
        UnevenRoundedBubble(bottomLeft: !mine && ends ? 6 : 18, bottomRight: mine && ends ? 6 : 18)
    }

    private func bubble(_ m: OctokanMessage, starts: Bool, ends: Bool, status: String?) -> some View {
        let mine = m.fromVisitor
        return VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 8) {
                if mine { Spacer(minLength: 48) }
                if !mine { if ends { avatar(28, 12) } else { Color.clear.frame(width: 28, height: 28) } }
                Text(m.body)
                    .font(.system(size: 16))
                    .foregroundColor(mine ? .white : ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(mine ? model.accent : soft, in: bubbleShape(mine: mine, ends: ends))
                    .opacity(m.pending ? 0.65 : 1)
                if !mine { Spacer(minLength: 48) }
            }
            if ends || status != nil {
                Text(clock(m.at) + (status.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10, weight: status == "✓✓ Seen" ? .bold : .regular))
                    .foregroundColor(status == "✓✓ Seen" ? seenGreen : Color(.tertiaryLabel))
                    .padding(.leading, mine ? 0 : 36)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.top, starts ? 12 : 3)
    }

    // multi-line growth needs iOS 16; iOS 15 gets a single-line field
    @ViewBuilder
    private var messageField: some View {
        if #available(iOS 16.0, *) {
            TextField("Write a message…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
        } else {
            TextField("Write a message…", text: $draft)
        }
    }

    private var composer: some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            messageField
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(soft, in: RoundedRectangle(cornerRadius: 22))
                .onChange(of: draft) { value in
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.notifyTyping() }
                }
            Button {
                model.send(draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(model.accent, in: Circle())
            }
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.35)
            .scaleEffect(canSend ? 1 : 0.9)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: canSend)
            .accessibilityLabel("Send")
        }
        .padding(12)
        .background(Color(.systemBackground))
        .overlay(Divider(), alignment: .top)
    }
}

/// A rounded bubble whose bottom corners can be tighter, for the "tail" at the end of a group.
private struct UnevenRoundedBubble: Shape {
    var bottomLeft: CGFloat
    var bottomRight: CGFloat
    let top: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tl = top, tr = top, bl = min(bottomLeft, rect.height / 2), br = min(bottomRight, rect.height / 2)
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// A ready-made button that opens the chat. Drop it anywhere in your UI.
public struct OctokanChatButton: View {
    @State private var open = false
    private let label: String

    public init(_ label: String = "Chat with us") {
        self.label = label
    }

    public var body: some View {
        Button(label) { open = true }
            .sheet(isPresented: $open) { OctokanChatView(onClose: { open = false }) }
    }
}
