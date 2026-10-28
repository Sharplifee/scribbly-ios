import Foundation
import AuthenticationServices
import CryptoKit
import Security

/// The signed-in person's tokens, readable from any thread (every request
/// to Supabase and the cloud computer carries them).
enum AuthTokens {
    private static let lock = NSLock()
    private static var _access: String?
    /// Signed-in user's id (for the event log).
    static var userID: String?
    private static var loaded = false
    /// Read from the Keychain on first use, so a recording started by Siri or
    /// the Control Center before any view appears still files to the right library.
    static var access: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            if !loaded {
                loaded = true
                if let d = Keychain.read("scribbly.session"),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    _access = o["access"] as? String
                }
            }
            return _access
        }
        set { lock.lock(); _access = newValue; loaded = true; lock.unlock() }
    }
}

/// Sign in (Apple, email code, phone code), keep the session fresh, and know
/// whether this person has finished the short setup.
@MainActor
final class AuthSession: ObservableObject {
    static let shared = AuthSession()

    enum Phase: Equatable { case loading, signedOut, onboarding, ready }

    struct User: Codable, Equatable { let id: String; let email: String?; let phone: String? }
    struct Profile: Codable, Equatable {
        var user_id: String
        var display_name: String?
        var text_size: String?
        var onboarded_at: String?
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var user: User?
    @Published private(set) var profile: Profile?
    @Published var error: String?

    private struct Stored: Codable { var access: String; var refresh: String; var expiresAt: Date; var user: User }
    private var stored: Stored? { didSet { AuthTokens.access = stored?.access; AuthTokens.userID = stored?.user.id } }
    private var refreshTask: Task<Void, Never>?

    private static let authBase = CorpusAPI.supabaseURL + "/auth/v1"
    private static let keychainKey = "scribbly.session"

    var displayName: String? {
        let n = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (n?.isEmpty == false) ? n : nil
    }

    // MARK: Launch

    func restore() async {
        guard let data = Keychain.read(Self.keychainKey),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { phase = .signedOut; return }
        stored = s
        user = s.user
        if s.expiresAt < Date().addingTimeInterval(300) { await refresh() }
        if stored == nil { phase = .signedOut; return }
        await afterSignIn()
    }

    // MARK: Sign in

    /// Sign in with Apple: the nonce goes to Apple hashed and to Supabase raw.
    private(set) var appleNonce = ""
    func prepareApple(_ request: ASAuthorizationAppleIDRequest) {
        appleNonce = Self.randomNonce()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(appleNonce)
    }

    func finishApple(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .failure(let e):
            if (e as? ASAuthorizationError)?.code == .canceled { return }
            error = "Apple sign-in didn't finish: \(e.localizedDescription)"
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken, let idToken = String(data: tokenData, encoding: .utf8) else {
                error = "Apple didn't return a sign-in token."; return
            }
            if let given = cred.fullName?.givenName, !given.isEmpty { pendingName = given }
            await exchange(path: "/token?grant_type=id_token",
                           body: ["provider": "apple", "id_token": idToken, "nonce": appleNonce])
        }
    }
    /// Apple only shares the name on the very first sign-in; it pre-fills setup.
    @Published var pendingName: String?

    /// Email + password. On success the login is kept behind Face ID so the
    /// next sign-in is just a glance.
    func signInWithPassword(_ email: String, _ password: String) async {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        if await exchange(path: "/token?grant_type=password", body: ["email": e, "password": password]) {
            FaceIDVault.save(email: e, password: password)
        } else if error?.lowercased().contains("invalid") == true {
            error = "That email and password don't match. Try again, or get a code instead."
        }
    }

    /// Face ID → saved login → signed in. Returns false if nothing is saved or Face ID is cancelled.
    @discardableResult
    func signInWithFaceID() async -> Bool {
        guard let c = await FaceIDVault.load() else { return false }
        await signInWithPassword(c.email, c.password)
        return phase != .signedOut
    }

    func sendEmailCode(_ email: String) async -> Bool {
        await post("/otp", ["email": email.trimmingCharacters(in: .whitespaces).lowercased(), "create_user": true])
    }
    func verifyEmail(_ email: String, code: String) async {
        await exchange(path: "/verify", body: ["type": "email", "email": email.trimmingCharacters(in: .whitespaces).lowercased(),
                                               "token": code.filter(\.isNumber)])
    }
    func sendPhoneCode(_ phone: String) async -> Bool {
        await post("/otp", ["phone": Self.e164(phone)])
    }
    func verifyPhone(_ phone: String, code: String) async {
        await exchange(path: "/verify", body: ["type": "sms", "phone": Self.e164(phone), "token": code.filter(\.isNumber)])
    }

    func signOut() {
        EventLog.shared.log("auth.signed_out")
        if let t = stored?.access {
            var req = URLRequest(url: URL(string: Self.authBase + "/logout")!)
            req.httpMethod = "POST"
            req.setValue(CorpusAPI.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: req).resume()
        }
        Keychain.delete(Self.keychainKey)
        stored = nil; user = nil; profile = nil
        refreshTask?.cancel()
        phase = .signedOut
    }

    // MARK: Setup (onboarding)

    func finishOnboarding(name: String, textSize: String) async {
        guard let u = user else { return }
        var p = profile ?? Profile(user_id: u.id)
        p.display_name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.text_size = textSize
        p.onboarded_at = ISO8601DateFormatter().string(from: Date())
        if await saveProfile(p) { profile = p; phase = .ready }
    }

    func rename(_ name: String) async {
        guard var p = profile else { return }
        p.display_name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if await saveProfile(p) { profile = p }
    }

    // MARK: Internals

    private func afterSignIn() async {
        // The very first sign-in by the library's owner claims the existing library.
        _ = try? await rpc("scribbly_claim_library")
        await loadProfile()
        if let size = profile?.text_size, !size.isEmpty {
            UserDefaults.standard.set(size, forKey: TextSizeOption.storageKey)
        }
        phase = profile?.onboarded_at == nil ? .onboarding : .ready
        scheduleRefresh()
    }

    private func loadProfile() async {
        guard let u = user else { return }
        var req = restRequest("scribbly_profiles?user_id=eq.\(u.id)&select=user_id,display_name,text_size,onboarded_at")
        req.httpMethod = "GET"
        if let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
           let rows = try? JSONDecoder().decode([Profile].self, from: d) {
            profile = rows.first
        }
    }

    private func saveProfile(_ p: Profile) async -> Bool {
        var req = restRequest("scribbly_profiles")
        req.httpMethod = "POST"
        req.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try? JSONEncoder().encode(p)
        guard let (_, r) = try? await URLSession.shared.data(for: req),
              let code = (r as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            error = "Couldn't save your setup — check your connection and try again."
            return false
        }
        return true
    }

    func rpc(_ name: String, _ body: [String: Any] = [:]) async throws -> Data {
        var req = restRequest("rpc/\(name)")
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, _) = try await URLSession.shared.data(for: req)
        return d
    }

    private func restRequest(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: CorpusAPI.restBase + "/" + path)!)
        req.timeoutInterval = 30
        req.setValue(CorpusAPI.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(stored?.access ?? CorpusAPI.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func post(_ path: String, _ body: [String: Any]) async -> Bool {
        error = nil
        var req = URLRequest(url: URL(string: Self.authBase + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(CorpusAPI.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (d, r) = try await URLSession.shared.data(for: req)
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { return true }
            error = Self.message(d) ?? "Couldn't send the code (error \(code))."
        } catch { self.error = "No connection — try again." }
        return false
    }

    @discardableResult
    private func exchange(path: String, body: [String: Any]) async -> Bool {
        error = nil
        var req = URLRequest(url: URL(string: Self.authBase + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(CorpusAPI.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (d, r) = try await URLSession.shared.data(for: req)
            guard (r as? HTTPURLResponse)?.statusCode == 200, let s = Self.session(from: d) else {
                error = Self.message(d) ?? "That didn't work — check the code and try again."
                EventLog.shared.error("auth.sign_in_failed", error ?? "", ["method": path])
                return false
            }
            store(s)
            EventLog.shared.log("auth.signed_in", status: "ok", ["method": path])
            await afterSignIn()
            return true
        } catch { self.error = "No connection — try again." }
        return false
    }

    private func refresh() async {
        guard let r = stored?.refresh else { return }
        var req = URLRequest(url: URL(string: Self.authBase + "/token?grant_type=refresh_token")!)
        req.httpMethod = "POST"
        req.setValue(CorpusAPI.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": r])
        guard let (d, resp) = try? await URLSession.shared.data(for: req) else { return }   // offline: keep the old one
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200, let s = Self.session(from: d) { store(s) }
        else if code == 400 || code == 401 { signOut() }    // refresh token revoked/expired
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let exp = self.stored?.expiresAt else { return }
                let wait = max(30, exp.timeIntervalSinceNow - 300)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { return }
                await self.refresh()
            }
        }
    }

    func refreshIfNeeded() async {
        if let exp = stored?.expiresAt, exp < Date().addingTimeInterval(300) { await refresh() }
    }

    private func store(_ s: Stored) {
        stored = s
        user = s.user
        if let data = try? JSONEncoder().encode(s) { Keychain.write(Self.keychainKey, data) }
    }

    private static func session(from d: Data) -> Stored? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let access = o["access_token"] as? String, let refresh = o["refresh_token"] as? String,
              let u = o["user"] as? [String: Any], let id = u["id"] as? String else { return nil }
        let exp = (o["expires_in"] as? Double) ?? 3600
        let email = (u["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let phone = (u["phone"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Stored(access: access, refresh: refresh, expiresAt: Date().addingTimeInterval(exp),
                      user: User(id: id, email: email, phone: phone))
    }

    private static func message(_ d: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let m = (o["msg"] as? String) ?? (o["error_description"] as? String) ?? (o["message"] as? String)
        guard let m, !m.isEmpty else { return nil }
        if m.lowercased().contains("expired") || m.lowercased().contains("invalid") { return "That code didn't work or has expired — send a new one." }
        if m.lowercased().contains("rate limit") { return "Too many codes requested — wait a few minutes and try again." }
        return m
    }

    /// "(801) 555-1234" → "+18015551234"; anything starting with + is kept.
    static func e164(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        let digits = t.filter(\.isNumber)
        if t.hasPrefix("+") { return "+" + digits }
        return digits.count == 10 ? "+1" + digits : "+" + digits
    }

    private static func randomNonce(length: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var out = ""
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        for b in bytes { out.append(chars[Int(b) % chars.count]) }
        return out
    }
    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Minimal Keychain storage for the session (survives reinstalls of the same build line).
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.connor.scribbly.auth",
         kSecAttrAccount as String: key]
    }
    static func write(_ key: String, _ data: Data) {
        SecItemDelete(query(key) as CFDictionary)
        var q = query(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
    static func read(_ key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    static func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}

import LocalAuthentication

/// The email + password, stored in the Keychain so only Face ID (on this
/// iPhone, with the current enrolled face) can read it back.
enum FaceIDVault {
    private static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "com.connor.scribbly.faceid",
                                              kSecAttrAccount as String: "login"]
    static func save(email: String, password: String) {
        guard let data = try? JSONEncoder().encode([email, password]) else { return }
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = data
        if let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil) {
            q[kSecAttrAccessControl as String] = ac
        }
        SecItemAdd(q as CFDictionary, nil)
    }
    /// True if a login is saved — checked without showing Face ID.
    static var hasLogin: Bool {
        var q = base
        let ctx = LAContext(); ctx.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = ctx
        let st = SecItemCopyMatching(q as CFDictionary, nil)
        return st == errSecSuccess || st == errSecInteractionNotAllowed
    }
    static func load() async -> (email: String, password: String)? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var q = base
                let ctx = LAContext(); ctx.localizedReason = "Sign in to Scribbly"
                q[kSecUseAuthenticationContext as String] = ctx
                q[kSecReturnData as String] = true
                q[kSecMatchLimit as String] = kSecMatchLimitOne
                var out: CFTypeRef?
                guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                      let d = out as? Data, let a = try? JSONDecoder().decode([String].self, from: d), a.count == 2
                else { cont.resume(returning: nil); return }
                cont.resume(returning: (a[0], a[1]))
            }
        }
    }
}
