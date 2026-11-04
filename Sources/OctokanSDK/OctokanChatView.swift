import SwiftUI

/// The chat screen. Embed it anywhere, or call `Octokan.presentChat()` to show it as a sheet.
public struct OctokanChatView: View {
    @StateObject private var model = OctokanChatModel()
    @State private var draft = ""
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

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(model.accent).frame(width: 10, height: 10)
            Text(model.title).font(.headline)
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                        .padding(8)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    Text(model.welcome)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.bottom, 6)

                    ForEach(model.messages) { m in
                        bubble(m).id(m.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: model.messages) { messages in
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private func bubble(_ m: OctokanMessage) -> some View {
        HStack {
            if m.fromVisitor { Spacer(minLength: 48) }
            Text(m.body)
                .font(.body)
                .foregroundColor(m.fromVisitor ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(m.fromVisitor ? model.accent : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .opacity(m.pending ? 0.6 : 1)
            if !m.fromVisitor { Spacer(minLength: 48) }
        }
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
        HStack(alignment: .bottom, spacing: 8) {
            messageField
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            Button {
                model.send(draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(model.accent, in: Circle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            .accessibilityLabel("Send")
        }
        .padding(12)
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
