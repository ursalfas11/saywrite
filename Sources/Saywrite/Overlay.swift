import AppKit
import SwiftUI

enum OverlayState: Equatable {
    case hidden
    case recording(handsFree: Bool, rewrite: Bool)
    case processing
    case done(String, undo: Bool)
    case error(String)
}

@MainActor
final class OverlayModel: ObservableObject {
    static let dotCount = 11
    @Published var state: OverlayState = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: OverlayModel.dotCount)
    /// Finished, cleaned text of this dictation so far.
    @Published var committedText = ""
    /// Rough live transcript of what is being said right now.
    @Published var partialText = ""
    /// Whether clicking the error opens something that fixes it.
    @Published var errorActionable = false
    /// The current session rewrites a selection (changes the processing label).
    @Published var isRewrite = false

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        levels = Array(repeating: 0, count: Self.dotCount)
        committedText = ""
        partialText = ""
    }
}

/// The floating recorder panel at the bottom of the screen. Clickable, but never takes focus.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    var onErrorClick: (() -> Void)?
    var onStop: (() -> Void)?
    var onUndo: (() -> Void)?
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = OverlayView(
            model: model,
            onStop: { [weak self] in self?.onStop?() },
            onUndo: { [weak self] in self?.onUndo?() },
            onErrorTap: { [weak self] in self?.onErrorClick?() })
        let host = NSHostingView(rootView: view)
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    func show(_ state: OverlayState) {
        hideTask?.cancel()
        if case .recording = state, !isRecording { model.reset() }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.state = state }
        if state == .hidden {
            // Fade out instead of vanishing.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.state == .hidden else { return }
                    self.panel.orderOut(nil)
                }
            })
            return
        }
        position()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        switch state {
        case .done(_, let undo):
            // Out of the way right after pasting; with an "Original" button a bit longer to click it.
            scheduleHide(after: undo ? 2.5 : 0.7)
        case .error:
            scheduleHide(after: 4.0)
        default:
            break
        }
    }

    private var isRecording: Bool {
        if case .recording = model.state { return true }
        return false
    }

    private func scheduleHide(after seconds: Double) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.show(.hidden)
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let size = panel.frame.size
        // Horizontally centered on the whole screen (a side Dock must not shift it), just above
        // the Dock or the bottom edge.
        panel.setFrameOrigin(NSPoint(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: screen.visibleFrame.minY + 12))
    }
}

// MARK: - View

private enum Palette {
    static let background = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let record = Color(red: 0.90, green: 0.29, blue: 0.27)
    static let rewrite = Color(red: 0.58, green: 0.50, blue: 1.0)
    static let busy = Color(red: 0.45, green: 0.72, blue: 1.0)
    static let success = Color(red: 0.35, green: 0.84, blue: 0.55)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.25)
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var onStop: () -> Void
    var onUndo: () -> Void = {}
    var onErrorTap: () -> Void

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.state != .hidden {
                card
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One compact row: no live transcript, the words appear where they are inserted.
    private var card: some View {
        controls
            .padding(.horizontal, 8)
            .frame(height: 34)
            .frame(maxWidth: 340)
            .fixedSize()
            .background(
                Capsule(style: .continuous)
                    .fill(Palette.background.opacity(0.96))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .onTapGesture { if case .error = model.state { onErrorTap() } }
    }

    private var processingLabel: String {
        model.isRewrite ? L("Rewriting…", "Formuliere um …") : L("Inserting…", "Wird eingefügt …")
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .recording(_, let rewrite):
            HStack(spacing: 10) {
                StopButton(color: rewrite ? Palette.rewrite : Palette.record, action: onStop)
                DotMeter(levels: model.levels)
                Image(systemName: rewrite ? "wand.and.stars" : "mic.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(rewrite ? Palette.rewrite : .white.opacity(0.9))
                    .frame(width: 18)
                    .help(rewrite
                        ? L("Say what should happen to the selected text", "Sag, was mit dem markierten Text passieren soll")
                        : L("Listening", "Hört zu"))
            }
        case .processing:
            HStack(spacing: 8) {
                ProcessingDots(color: Palette.busy)
                statusLabel(processingLabel)
            }
            .padding(.horizontal, 4)
        case .done(let summary, let undo):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.success)
                if !summary.isEmpty { statusLabel(summary) }
                if undo {
                    Button(action: onUndo) {
                        Label(L("Original", "Original"), systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help(L("Insert the text without AI changes", "Text ohne KI-Änderungen einfügen"))
                }
            }
            .padding(.horizontal, 4)
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.warning)
                statusLabel(message)
            }
            .padding(.horizontal, 4)
            .help(model.errorActionable ? L("Click to open the setting", "Klicken, um die Einstellung zu öffnen") : "")
        }
    }

    private func statusLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct StopButton: View {
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color).frame(width: 20, height: 20)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.white)
                    .frame(width: 7, height: 7)
            }
            .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Done – insert text", "Fertig – Text einfügen"))
    }
}

private struct DotMeter: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                let level = CGFloat(levels[index])
                Capsule()
                    .fill(Color.white.opacity(0.55 + 0.45 * level))
                    .frame(width: 3, height: 3 + level * 11)
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

private struct ProcessingDots: View {
    let color: Color
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .scaleEffect(phase ? 1 : 0.5)
                    .opacity(phase ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.45).repeatForever().delay(Double(index) * 0.15), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}
