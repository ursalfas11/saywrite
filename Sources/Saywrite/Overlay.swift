import AppKit
import SaywriteCore
import SwiftUI

enum OverlayState: Equatable {
    case hidden
    case recording(handsFree: Bool, rewrite: Bool)
    case processing
    /// The text really landed at the cursor.
    case done(String, undo: Bool)
    /// Something the user has to act on (press ⌘V, speak again): longer than `.done`, orange, own symbol.
    case notice(String, symbol: String)
    /// A forgotten recording stopped by itself: nothing was inserted, the pill offers to insert it now.
    case autoStopped(String)
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
    /// Label of the button an actionable error shows ("Settings"); nil shows none.
    @Published var actionTitle: String?
    /// The current session rewrites a selection (changes the processing label).
    @Published var isRewrite = false
    /// Seconds since the recording started, shown in hands-free mode.
    @Published var elapsed: TimeInterval = 0
    /// Seconds until the recording stops by itself, once that is near.
    @Published var countdown: TimeInterval?
    /// System accessibility display settings, read whenever the panel is shown.
    @Published var reduceMotion = false
    @Published var increaseContrast = false

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    func reset() {
        levels = Array(repeating: 0, count: Self.dotCount)
        committedText = ""
        partialText = ""
        elapsed = 0
        countdown = nil
    }
}

/// The floating recorder panel at the bottom of the screen. Clickable, but never takes focus.
@MainActor
final class OverlayController {
    let model = OverlayModel()
    var onErrorClick: (() -> Void)?
    var onStop: (() -> Void)?
    var onUndo: (() -> Void)?
    /// The × of a recording: discard it.
    var onCancel: (() -> Void)?
    /// "Insert" on the pill of an automatically stopped recording.
    var onInsertPending: (() -> Void)?
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
            onErrorTap: { [weak self] in self?.onErrorClick?() },
            onCancel: { [weak self] in self?.onCancel?() },
            onInsertPending: { [weak self] in self?.onInsertPending?() })
        let host = NSHostingView(rootView: view)
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    func show(_ state: OverlayState) {
        hideTask?.cancel()
        let previous = model.state
        if case .recording = state, !isRecording { model.reset() }
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        withAnimation(model.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { model.state = state }
        if state != previous, let text = Self.announcement(for: state, rewrite: model.isRewrite) { Self.announce(text) }
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
        case .notice:
            // The user still has to do something (⌘V, speak again): long enough to read it.
            scheduleHide(after: 3.5)
        case .autoStopped:
            // The text is in the history as well ("Paste last dictation"); the button is a shortcut.
            scheduleHide(after: 12)
        case .error:
            scheduleHide(after: model.actionTitle == nil ? 4.0 : 6.0)
        default:
            break
        }
    }

    private var isRecording: Bool {
        if case .recording = model.state { return true }
        return false
    }

    /// What VoiceOver says when the panel changes; the panel never takes focus, so it would say nothing.
    static func announcement(for state: OverlayState, rewrite: Bool) -> String? {
        switch state {
        case .hidden, .processing: return nil
        case .recording:
            return rewrite ? L("Recording – say what should change", "Aufnahme – sag, was sich ändern soll") : L("Recording", "Aufnahme läuft")
        case .done(let summary, _):
            return summary.isEmpty ? L("Inserted", "Eingefügt") : summary
        case .notice(let text, _), .autoStopped(let text), .error(let text):
            return text
        }
    }

    private static func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
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
    /// Hints the user has to act on; clearly not the green "done".
    static let notice = Color(red: 1.0, green: 0.58, blue: 0.20)
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var onStop: () -> Void
    var onUndo: () -> Void = {}
    var onErrorTap: () -> Void
    var onCancel: () -> Void = {}
    var onInsertPending: () -> Void = {}

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.state != .hidden {
                card
                    .transition(model.reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
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
                    .fill(Palette.background.opacity(model.increaseContrast ? 1 : 0.96))
                    .overlay(Capsule(style: .continuous).strokeBorder(
                        Color.white.opacity(model.increaseContrast ? 0.6 : 0.08), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .onTapGesture { if case .error = model.state { onErrorTap() } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Saywrite")
    }

    private var processingLabel: String {
        model.isRewrite ? L("Rewriting…", "Formuliere um …") : L("Inserting…", "Wird eingefügt …")
    }

    private var handsFreeHelp: String {
        L("Tap again = done, Esc = discard", "Nochmal tippen = fertig, Esc = verwerfen")
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .recording(let handsFree, let rewrite):
            HStack(spacing: 10) {
                StopButton(color: rewrite ? Palette.rewrite : Palette.record, animated: !model.reduceMotion, action: onStop)
                DotMeter(levels: model.levels, animated: !model.reduceMotion)
                    .accessibilityHidden(true)
                Image(systemName: rewrite ? "wand.and.stars" : "mic.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(rewrite ? Palette.rewrite : .white.opacity(0.9))
                    .frame(width: 18)
                    .help(rewrite
                        ? L("Say what should happen to the selected text", "Sag, was mit dem markierten Text passieren soll")
                        : (handsFree ? handsFreeHelp : L("Listening", "Hört zu")))
                    .accessibilityHidden(true)
                if let countdown = model.countdown {
                    // A forgotten recording is about to stop by itself.
                    Text(L("\(RecordingClock.text(countdown)) left", "noch \(RecordingClock.text(countdown))"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.notice)
                        .help(L("Stops by itself soon; the text is then kept, not inserted",
                                "Stoppt gleich von selbst; der Text wird dann aufbewahrt, nicht eingefügt"))
                } else if handsFree {
                    Text(RecordingClock.text(model.elapsed))
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.7))
                        .help(handsFreeHelp)
                        .accessibilityLabel(L("Hands-free, \(RecordingClock.text(model.elapsed))", "Freihändig, \(RecordingClock.text(model.elapsed))"))
                }
                CancelButton(highContrast: model.increaseContrast, action: onCancel)
            }
        case .processing:
            HStack(spacing: 8) {
                ProcessingDots(color: Palette.busy, animated: !model.reduceMotion)
                    .accessibilityHidden(true)
                statusLabel(processingLabel)
            }
            .padding(.horizontal, 4)
        case .done(let summary, let undo):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.success)
                    .accessibilityLabel(L("Inserted", "Eingefügt"))
                if !summary.isEmpty { statusLabel(summary) }
                if undo {
                    PillButton(title: L("Original", "Original"), systemImage: "arrow.uturn.backward", action: onUndo)
                        .help(L("Insert the text without AI changes", "Text ohne KI-Änderungen einfügen"))
                        .accessibilityHint(L("Insert the text without AI changes", "Text ohne KI-Änderungen einfügen"))
                }
            }
            .padding(.horizontal, 4)
        case .notice(let text, let symbol):
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.notice)
                    .accessibilityHidden(true)
                statusLabel(text)
            }
            .padding(.horizontal, 4)
        case .autoStopped(let text):
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.notice)
                    .accessibilityHidden(true)
                statusLabel(text)
                PillButton(title: L("Insert", "Einfügen"), systemImage: "text.insert", action: onInsertPending)
                    .help(L("Insert at the cursor now. Also in the menu: Paste last dictation",
                            "Jetzt an der Schreibmarke einfügen. Auch im Menü: Letztes Diktat einfügen"))
            }
            .padding(.horizontal, 4)
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.warning)
                    .accessibilityHidden(true)
                statusLabel(message)
                if let title = model.actionTitle {
                    PillButton(title: title, systemImage: "gearshape", action: onErrorTap)
                }
            }
            .padding(.horizontal, 4)
            .help(model.errorActionable ? L("Click to open the setting", "Klicken, um die Einstellung zu öffnen") : "")
        }
    }

    private func statusLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(model.increaseContrast ? 1 : 0.85))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// A small capsule button inside the pill ("Original", "Insert", "Settings").
private struct PillButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct StopButton: View {
    let color: Color
    var animated = true
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
            .scaleEffect(hovering && animated ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Done – insert text", "Fertig – Text einfügen"))
        .accessibilityLabel(L("Done – insert text", "Fertig – Text einfügen"))
    }
}

/// Discards the recording (like Esc).
private struct CancelButton: View {
    var highContrast = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(highContrast ? 1 : 0.75))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.white.opacity(highContrast ? 0.3 : 0.14)))
        }
        .buttonStyle(.plain)
        .help(L("Discard (Esc)", "Verwerfen (Esc)"))
        .accessibilityLabel(L("Discard recording", "Aufnahme verwerfen"))
    }
}

private struct DotMeter: View {
    let levels: [Float]
    var animated = true

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
        .animation(animated ? .easeOut(duration: 0.08) : nil, value: levels)
    }
}

private struct ProcessingDots: View {
    let color: Color
    var animated = true
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    // With Reduce Motion the dots stand still; the label says what happens.
                    .scaleEffect(animated ? (phase ? 1 : 0.5) : 0.8)
                    .opacity(animated ? (phase ? 1 : 0.4) : 0.8)
                    .animation(animated ? .easeInOut(duration: 0.45).repeatForever().delay(Double(index) * 0.15) : nil, value: phase)
            }
        }
        .onAppear { phase = true }
    }
}
