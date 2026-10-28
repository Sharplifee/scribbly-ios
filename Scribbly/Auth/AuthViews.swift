import SwiftUI
import AuthenticationServices
import AVFoundation

/// Keeps the app (and its recorder) alive underneath; sign-in and the short
/// setup sit on top until they're done. QA runs (SCRIBBLY_* env) skip it.
struct AuthGate<Content: View>: View {
    @ObservedObject private var auth = AuthSession.shared
    @ViewBuilder var content: () -> Content
    /// QA: any SCRIBBLY_* launch hook skips the gate; SCRIBBLY_AUTH=signin|onboarding shows that screen.
    private let forced = ProcessInfo.processInfo.environment["SCRIBBLY_AUTH"]
    private var qa: Bool { ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("SCRIBBLY_") } }

    var body: some View {
        ZStack {
            content()
            if forced == "signin" { SignInView() }
            else if forced == "onboarding" { OnboardingView() }
            else if !qa {
                switch auth.phase {
                case .loading:
                    Color.black.ignoresSafeArea().overlay(Wordmark(size: 34))
                        .transition(.opacity)
                case .signedOut:
                    SignInView().transition(.opacity)
                case .onboarding:
                    OnboardingView().transition(.move(edge: .trailing).combined(with: .opacity))
                case .ready:
                    EmptyView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: auth.phase)
        .task { if auth.phase == .loading, forced == nil { await auth.restore() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await auth.refreshIfNeeded() }
        }
    }
}

/// "Scribbly®" in the brand face.
struct Wordmark: View {
    var size: CGFloat = 30
    var body: some View {
        HStack(alignment: .top, spacing: 1) {
            Text("Scribbly").font(.custom("Geist-SemiBold", fixedSize: size)).foregroundColor(P.ink)
            Text("®").font(.custom("Geist-Regular", fixedSize: size * 0.36)).foregroundColor(P.ink).padding(.top, size * 0.12)
        }
    }
}

// MARK: - Sign in

struct SignInView: View {
    @ObservedObject private var auth = AuthSession.shared
    enum Mode { case choose, email, phone }
    @State private var mode: Mode = .choose
    @State private var target = ""      // email or phone
    @State private var code = ""
    @State private var sent = false
    @State private var busy = false
    @State private var password = ""
    @State private var useCode = false
    @State private var hasFaceID = FaceIDVault.hasLogin
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    FinsBackground()
                    VStack(alignment: .leading, spacing: 8) {
                        Wordmark(size: 40)
                        Text("Every word. One library.").font(.geist(size: 17)).foregroundColor(P.ink.opacity(0.85))
                    }
                    .padding(22)
                }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 12)

                Spacer(minLength: 20)
                VStack(spacing: 12) {
                    switch mode {
                    case .choose: chooser
                    case .email: if useCode { codeFlow } else { passwordFlow }
                    case .phone: codeFlow
                    }
                    if let e = auth.error {
                        Text(e).font(.geist(size: 13)).foregroundColor(P.danger)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                Spacer(minLength: 16)
                Text("Your library is private to you.").font(.geist(size: 12)).foregroundColor(P.textDim)
                    .padding(.bottom, 12)
            }
            .padding(.top, 8)
        }
        .task {
            // Face ID is the default: if a login is saved, ask straight away.
            if hasFaceID, mode == .choose, ProcessInfo.processInfo.environment["SCRIBBLY_AUTH"] == nil { faceID() }
        }
    }

    private var chooser: some View {
        VStack(spacing: 12) {
            if hasFaceID {
                pill(busy ? "Signing in…" : "Sign in with Face ID", icon: "faceid", primary: true) { faceID() }
            }
            SignInWithAppleButton(.continue) { auth.prepareApple($0) } onCompletion: { r in
                Task { busy = true; await auth.finishApple(r); busy = false }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 52)
            .clipShape(Capsule())
            pill("Continue with email", icon: "envelope") { start(.email) }
            pill("Continue with phone", icon: "phone") { start(.phone) }
        }
        .disabled(busy)
    }

    private var passwordFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { mode = .choose; auth.error = nil } label: {
                Label("Other ways", systemImage: "chevron.left").font(.geist(size: 14)).foregroundColor(P.textSec)
            }
            Text("Sign in with email").font(.geist(size: 24, weight: .semibold)).foregroundColor(P.ink)
            field("you@example.com", text: $target, kb: .emailAddress, content: .username)
            SecureField("Password", text: $password)
                .textContentType(.password).submitLabel(.go).onSubmit { passwordSignIn() }
                .font(.geist(size: 18)).foregroundColor(P.ink)
                .padding(.horizontal, 18).frame(height: 54)
                .background(Capsule().fill(P.surface2)).overlay(Capsule().stroke(P.border))
            pill(busy ? "Signing in…" : "Sign in", icon: nil, primary: true) { passwordSignIn() }
                .disabled(busy || !valid || password.isEmpty)
            Text("Face ID will sign you in next time.").font(.geist(size: 13)).foregroundColor(P.textDim)
            Button("Email me a code instead") { auth.error = nil; useCode = true; sent = false }
                .font(.geist(size: 14)).foregroundColor(P.textSec)
        }
    }

    private func passwordSignIn() {
        Task { busy = true; await auth.signInWithPassword(target, password); busy = false }
    }
    private func faceID() {
        Task {
            busy = true
            let ok = await auth.signInWithFaceID()
            busy = false
            if !ok { hasFaceID = FaceIDVault.hasLogin }
        }
    }

    private var codeFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { mode = .choose; sent = false; code = ""; auth.error = nil } label: {
                Label("Other ways", systemImage: "chevron.left").font(.geist(size: 14)).foregroundColor(P.textSec)
            }
            Text(sent ? "Enter the code" : (mode == .email ? "Your email" : "Your phone number"))
                .font(.geist(size: 24, weight: .semibold)).foregroundColor(P.ink)
            if sent {
                Text("Sent to \(target). It can take a minute.").font(.geist(size: 14)).foregroundColor(P.textSec)
                field("Code", text: $code, kb: .numberPad, content: .oneTimeCode)
                pill(busy ? "Checking…" : "Sign in", icon: nil, primary: true) { verify() }
                    .disabled(busy || code.filter(\.isNumber).count < 6)
                Button("Send a new code") { send() }.font(.geist(size: 14)).foregroundColor(P.textSec)
            } else {
                field(mode == .email ? "you@example.com" : "(801) 555-0123", text: $target,
                      kb: mode == .email ? .emailAddress : .phonePad,
                      content: mode == .email ? .emailAddress : .telephoneNumber)
                pill(busy ? "Sending…" : "Send code", icon: nil, primary: true) { send() }
                    .disabled(busy || !valid)
            }
        }
    }

    private var valid: Bool {
        mode == .email ? (target.contains("@") && target.contains(".")) : target.filter(\.isNumber).count >= 10
    }

    private func start(_ m: Mode) { auth.error = nil; mode = m; target = ""; code = ""; password = ""; useCode = false; sent = false; focused = true }
    private func send() {
        Task {
            busy = true
            let ok = mode == .email ? await auth.sendEmailCode(target) : await auth.sendPhoneCode(target)
            busy = false
            if ok { sent = true; code = ""; focused = true }
        }
    }
    private func verify() {
        Task {
            busy = true
            if mode == .email { await auth.verifyEmail(target, code: code) } else { await auth.verifyPhone(target, code: code) }
            busy = false
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, kb: UIKeyboardType, content: UITextContentType) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(kb).textContentType(content)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .focused($focused)
            .font(.geist(size: 18)).foregroundColor(P.ink)
            .padding(.horizontal, 18).frame(height: 54)
            .background(Capsule().fill(P.surface2))
            .overlay(Capsule().stroke(P.border))
    }

    private func pill(_ title: String, icon: String?, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.geist(size: 17, weight: .semibold))
            .foregroundColor(primary ? .black : P.ink)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(Capsule().fill(primary ? P.ink : P.surface2))
            .overlay(Capsule().stroke(primary ? Color.clear : P.border))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Setup: name → text size → permissions

struct OnboardingView: View {
    @ObservedObject private var auth = AuthSession.shared
    @AppStorage(TextSizeOption.storageKey) private var textSize = TextSizeOption.standard.rawValue
    @State private var step = 0
    @State private var name = ""
    @State private var showSizes = false
    @State private var saving = false
    @State private var micAsked = false
    @State private var locAsked = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Wordmark(size: 24)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(0..<3) { i in
                            Capsule().fill(i <= step ? P.ink : P.border).frame(width: i == step ? 22 : 8, height: 6)
                        }
                    }
                }
                .padding(.top, 8)
                Spacer(minLength: 10)
                SwiftUI.Group {
                    switch step {
                    case 0: nameStep
                    case 1: sizeStep
                    default: permissionStep
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                Spacer()
                if let e = auth.error { Text(e).font(.geist(size: 13)).foregroundColor(P.danger) }
                HStack {
                    if step > 0 {
                        Button("Back") { withAnimation { step -= 1 } }
                            .font(.geist(size: 16)).foregroundColor(P.textSec)
                    }
                    Spacer()
                    Button { next() } label: {
                        Text(step == 2 ? (saving ? "Saving…" : "Start using Scribbly") : "Continue")
                            .font(.geist(size: 17, weight: .semibold)).foregroundColor(.black)
                            .padding(.horizontal, 26).frame(height: 52)
                            .background(Capsule().fill(P.ink))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || (step == 0 && name.trimmingCharacters(in: .whitespaces).isEmpty))
                    .opacity(step == 0 && name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                }
            }
            .padding(.horizontal, 22).padding(.bottom, 12)
        }
        .onAppear {
            if name.isEmpty { name = auth.profile?.display_name ?? auth.pendingName ?? "" }
            nameFocused = true
        }
        .sheet(isPresented: $showSizes) { sizeSheet }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should we call you?").font(.geist(size: 30, weight: .semibold)).foregroundColor(P.ink)
            Text("Just a first name or nickname is fine.").font(.geist(size: 15)).foregroundColor(P.textSec)
            TextField("Your name", text: $name)
                .textContentType(.givenName).submitLabel(.continue).onSubmit { next() }
                .focused($nameFocused)
                .font(.geist(size: 22)).foregroundColor(P.ink)
                .padding(.horizontal, 18).frame(height: 58)
                .background(Capsule().fill(P.surface2)).overlay(Capsule().stroke(P.border))
        }
    }

    private var sizeStep: some View {
        let current = TextSizeOption(rawValue: textSize) ?? .standard
        return VStack(alignment: .leading, spacing: 12) {
            Text("How big should text be?").font(.geist(size: 30, weight: .semibold)).foregroundColor(P.ink)
            Text("You can change this any time in Settings.").font(.geist(size: 15)).foregroundColor(P.textSec)
            Button { showSizes = true } label: {
                HStack {
                    Text("Aa").font(.custom("Geist-SemiBold", fixedSize: current.sample + 4))
                    Text(current.rawValue).font(.geist(size: 17, weight: .medium))
                    Spacer()
                    Text("Change").font(.geist(size: 15)).foregroundColor(P.textSec)
                }
                .foregroundColor(P.ink).padding(.horizontal, 18).frame(height: 58)
                .background(Capsule().fill(P.surface2)).overlay(Capsule().stroke(P.border))
            }
            .buttonStyle(.plain)
        }
        .onAppear { showSizes = true }
    }

    private var sizeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Text size").font(.geist(size: 22, weight: .semibold)).foregroundColor(P.ink)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(TextSizeOption.allCases) { o in
                    let on = textSize == o.rawValue
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { textSize = o.rawValue } } label: {
                        VStack(spacing: 6) {
                            Text("A").font(.custom("Geist-SemiBold", fixedSize: o.sample))
                                .foregroundColor(on ? .black : P.ink)
                                .frame(maxWidth: .infinity).frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? P.ink : P.surface2))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? Color.clear : P.border))
                            Text(o.rawValue).font(.custom("GeistMono-Regular", fixedSize: 9)).textCase(.uppercase)
                                .foregroundColor(on ? P.ink : P.textDim).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Text size \(o.rawValue)")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Morning walk notes").font(.geist(size: 17, weight: .semibold)).foregroundColor(P.ink)
                Text("Transcribed, summarized, searchable — this is how text will look.")
                    .font(.geist(size: 15)).foregroundColor(P.textSec)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(P.surface))
            .modifier(AppTextSize())
            Button { showSizes = false } label: {
                Text("Done").font(.geist(size: 17, weight: .semibold)).foregroundColor(.black)
                    .frame(maxWidth: .infinity).frame(height: 50).background(Capsule().fill(P.ink))
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Two quick permissions").font(.geist(size: 30, weight: .semibold)).foregroundColor(P.ink)
            Text("Scribbly needs the microphone to record. Location is optional — it labels where a recording happened.")
                .font(.geist(size: 15)).foregroundColor(P.textSec).fixedSize(horizontal: false, vertical: true)
            permRow("Microphone", icon: "mic.fill", done: micAsked) {
                AVAudioSession.sharedInstance().requestRecordPermission { _ in
                    DispatchQueue.main.async { micAsked = true }
                }
            }
            permRow("Location", icon: "location.fill", done: locAsked) {
                PlaceTagger.shared.tag { _ in }
                locAsked = true
            }
        }
        .onAppear {
            micAsked = AVAudioSession.sharedInstance().recordPermission != .undetermined
        }
    }

    private func permRow(_ title: String, icon: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22)
                Text(title).font(.geist(size: 17, weight: .medium))
                Spacer()
                Image(systemName: done ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundColor(done ? P.good : P.textDim)
            }
            .foregroundColor(P.ink).padding(.horizontal, 18).frame(height: 56)
            .background(Capsule().fill(P.surface2)).overlay(Capsule().stroke(P.border))
        }
        .buttonStyle(.plain)
        .disabled(done)
    }

    private func next() {
        if step < 2 {
            if step == 0, name.trimmingCharacters(in: .whitespaces).isEmpty { return }
            withAnimation(.easeInOut(duration: 0.3)) { step += 1 }
        } else {
            Task {
                saving = true
                await auth.finishOnboarding(name: name, textSize: textSize)
                saving = false
            }
        }
    }
}
