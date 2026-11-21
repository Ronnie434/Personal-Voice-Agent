import AppKit
import SwiftUI

/// Shown when Claude's sign-in has lapsed: why Friday has gone quiet, what to
/// do about it, and, once the sign-in works again, that Friday is back.
public struct SignInView: View {
    @ObservedObject var engine: EngineModel
    public static let windowID = "signin"
    public static let title = "Sign in to Claude"

    public init(engine: EngineModel) {
        self.engine = engine
    }

    /// Close the window this is shown in, through AppKit, which closes a
    /// `Window` scene reliably in a menu bar app.
    private func close() {
        NSApp.windows.first {
            $0.identifier?.rawValue.hasPrefix(Self.windowID) == true || $0.title == Self.title
        }?.close()
    }

    private var waiting: Bool { engine.warning == .claudeAuth }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("CLAUDE SIGN-IN").eyebrow()
            Text(waiting ? "Sign in to Claude" : "You’re signed in")
                .font(FridayFont.setupTitle).tracking(-0.84).foregroundStyle(Color.ink)
            Text(waiting
                 ? "Friday answers you through Claude Code, and Claude’s sign-in has expired. Until you sign in again, Friday can hear you but can’t reply.\n\nThe sign-in page is open in your browser. Finish signing in there, and Friday picks up where it left off."
                 : "Claude is signed in again, so Friday is back to answering you.")
                .font(.system(size: 15)).foregroundStyle(Color.muted).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                if waiting {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to sign in…").font(FridayFont.body).foregroundStyle(Color.ink2)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.fridayAccent)
                    Text("Signed in").font(FridayFont.body).foregroundStyle(Color.ink2)
                }
            }
            .padding(.top, Space.xs)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if waiting {
                    Button("Open the sign-in page again") { engine.openSignIn() }
                        .buttonStyle(PillButtonStyle(.secondary, height: 36))
                    Button("Later") { close() }
                        .buttonStyle(PillButtonStyle(.secondary, height: 36))
                } else {
                    Button("Done") { close() }.buttonStyle(PillButtonStyle(.primary, height: 36))
                }
            }
        }
        .padding(40)
        .frame(width: 520, height: 400, alignment: .topLeading)
        .background(Color.surface)
        .animation(Motion.spring, value: waiting)
        .task(id: waiting) {
            // Once signed in, the good news stays up a moment, then goes.
            guard !waiting else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { close() }
        }
    }
}
