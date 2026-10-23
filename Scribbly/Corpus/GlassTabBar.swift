import SwiftUI

/// The bottom bar: four glass tabs with the Record button as the largest
/// element, a 76pt disc standing proud of the bar (per Connor's reference).
/// Replaces the system tab bar so the mic can overflow it.
///
/// While a recording is live (recording / paused / finishing) or its audio is
/// uploading, the SAME bar becomes the recorder — same capsule, same height,
/// no second bar stacked above it: ✕ discard · timer · [✓ finish in the centre
/// disc] · live wave · pause/resume. Upload shows its live percentage in the
/// same footprint, then the tabs morph back. Server processing afterwards rides
/// along as a thin line in the bar plus a ring and % badge on the record disc,
/// so the tabs stay usable while the server transcribes.
struct GlassTabBar: View {
    @Binding var selection: LibraryScreen.Section
    var onRecord: () -> Void

    private let left: [LibraryScreen.Section]  = [.home, .library]
    private let right: [LibraryScreen.Section] = [.groups, .more]

    @ObservedObject private var rec = Recorder.shared
    @ObservedObject private var up = Uploader.shared
    @State private var recordTaps = 0
    @State private var finishTaps = 0
    @State private var showDiscardConfirm = false
    @Namespace private var glassNS

    /// What the bar is right now.
    enum Mode: Equatable { case tabs, recorder, upload }

    private var mode: Mode {
        if rec.state != .idle { return .recorder }
        if up.isUploading { return .upload }
        return .tabs
    }

    private static let disc: CGFloat = 76
    private static let morph = Animation.spring(response: 0.42, dampingFraction: 0.86)

    var body: some View {
        let m = mode
        let live = m == .recorder && rec.state == .recording
        return ZStack {
            capsuleContent(m)
                .padding(.horizontal, 6).padding(.vertical, 6)
                .fixedSize(horizontal: false, vertical: true)
                .sinkyGlass(Capsule(), tint: live ? P.accent.opacity(0.22) : nil)
                .overlay(alignment: .bottom) { transferLine.padding(.horizontal, 30).padding(.bottom, 3) }
            centreDisc(m)
        }
        .frame(height: 74)
        .padding(.horizontal, 16).padding(.bottom, 2)
        .animation(Self.morph, value: m)
        .sinkyHaptic(selection)
        .sinkyHaptic(m)
        .alert("Discard this recording?", isPresented: $showDiscardConfirm) {
            Button("Keep recording", role: .cancel) {}
            Button("Discard", role: .destructive) { rec.discard() }
        } message: { Text("The audio will be deleted and cannot be recovered.") }
    }

    // MARK: Capsule content

    /// The tabs always lay out (so the capsule keeps exactly the tab bar's
    /// height); in recorder / upload mode they fade out and the controls take
    /// the same footprint.
    private func capsuleContent(_ m: Mode) -> some View {
        ZStack {
            tabsRow
                .opacity(m == .tabs ? 1 : 0)
                .scaleEffect(m == .tabs ? 1 : 0.94)
                .allowsHitTesting(m == .tabs)
                .accessibilityHidden(m != .tabs)
            if m == .recorder {
                recorderRow
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if m == .upload {
                uploadRow
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private var tabsRow: some View {
        HStack(spacing: 0) {
            ForEach(left) { tab(for: $0) }
            Spacer().frame(width: Self.disc)          // room under the record button (fixed size)
            ForEach(right) { tab(for: $0) }
        }
    }

    // MARK: Recorder (recording / paused / finishing)

    private var timeString: String {
        let t = Int(rec.elapsed)
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    private var statusText: String {
        if rec.interrupted { return "Interrupted" }
        switch rec.state {
        case .recording: return rec.appendTo == nil ? "Recording" : "Adding"
        case .paused:    return "Paused"
        case .finishing: return "Saving"
        case .idle:      return ""
        }
    }

    private var statusColor: Color {
        if rec.interrupted { return .orange }
        return rec.state == .recording ? P.accent : P.textDim
    }

    private var recorderRow: some View {
        let busy = rec.state == .finishing
        let recording = rec.state == .recording
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { showDiscardConfirm = true } label: {
                    roundIcon("xmark", tint: P.danger, size: 38)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel("Discard recording")
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeString)
                        .font(.geist(size: 16, weight: .medium, design: .monospaced)).monospacedDigit()
                        .foregroundColor(P.ink).lineLimit(1).minimumScaleFactor(0.7)
                    Text(statusText).monoLabel(8.5, color: statusColor).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            .padding(.leading, 2)
            .frame(maxWidth: .infinity)
            Spacer().frame(width: Self.disc)
            HStack(spacing: 8) {
                WaveBars(level: rec.level, active: recording).frame(height: 24)
                    .accessibilityHidden(true)
                Button {
                    recording ? rec.pause() : rec.resume()
                } label: {
                    roundIcon(recording ? "pause.fill" : "play.fill", tint: P.ink, size: 40)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel(recording ? "Pause" : "Resume")
            }
            .padding(.trailing, 2)
            .frame(maxWidth: .infinity)
        }
    }

    private func roundIcon(_ name: String, tint: Color, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(P.surface2)
                .overlay(Circle().stroke(P.border, lineWidth: 1))
                .frame(width: size, height: size)
            Image(systemName: name)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundColor(tint)
        }
        .contentShape(Circle())
    }

    // MARK: Upload

    private var uploadFraction: Double { min(max(up.uploadFraction, 0), 1) }

    private var uploadRow: some View {
        let frac = uploadFraction
        let pct = Int((frac * 100).rounded())
        let label: String = up.stage.isEmpty ? (frac < 1 ? "Uploading…" : "Handed off") : up.stage
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Upload").monoLabel(8.5, color: P.accent)
                Text(label).font(.geist(size: 12, weight: .medium)).foregroundColor(P.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: Self.disc)
            Text("\(pct)%")
                .font(.geist(size: 17, weight: .medium, design: .monospaced)).monospacedDigit()
                .foregroundColor(P.ink)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uploading, \(pct) percent")
    }

    // MARK: Upload / server progress (thin line + ring)

    /// 0…1 for whatever is in flight: the upload's bytes, else the server
    /// job's own progress. nil when nothing is in flight or it reports none.
    private var transferFraction: Double? {
        if up.isUploading { return uploadFraction }
        if let p = up.serverJob?.progress { return min(max(p / 100, 0), 1) }
        return nil
    }

    private var transferActive: Bool { up.isUploading || up.serverJob != nil }

    @ViewBuilder private var transferLine: some View {
        if transferActive, let f = transferFraction {
            GradientProgress(value: f, height: 2.5, duration: 0.8)
                .transition(.opacity)
        }
    }

    /// Server processing while the tabs are back: "62%" (or a spinner) above the disc.
    @ViewBuilder private func serverBadge(_ m: Mode) -> some View {
        if m == .tabs, let job = up.serverJob {
            SwiftUI.Group {
                if let p = job.progress {
                    Text("\(Int(p.rounded()))%")
                        .font(.geist(size: 10, weight: .medium, design: .monospaced)).monospacedDigit()
                        .foregroundColor(P.ink)
                } else {
                    ProgressView().controlSize(.mini).tint(P.accent)
                }
            }
            .padding(.horizontal, 7).frame(height: 18)
            .background(Capsule().fill(P.surface2))
            .overlay(Capsule().stroke(P.accent.opacity(0.6), lineWidth: 1))
            .offset(y: -(Self.disc / 2) - 2)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .accessibilityLabel(job.stage)
        }
    }

    // MARK: Centre disc: Record ⇄ ✓ Finish

    private func centreDisc(_ m: Mode) -> some View {
        let finishing = m == .recorder
        let ringFrac: Double? = transferActive ? transferFraction : nil
        let pulse = rec.state == .recording ? CGFloat(rec.level) * 0.07 : 0
        return Button {
            if finishing {
                guard rec.state == .recording || rec.state == .paused else { return }
                finishTaps += 1
                rec.finishAndUpload()
            } else {
                recordTaps += 1
                onRecord()
            }
        } label: {
            ZStack {
                Circle().fill(P.bg).frame(width: Self.disc, height: Self.disc)
                Circle().stroke(finishing ? P.accent.opacity(0.75) : P.border, lineWidth: finishing ? 1.5 : 1)
                    .frame(width: Self.disc, height: Self.disc)
                    .scaleEffect(1 + pulse)
                    .animation(.linear(duration: 0.08), value: pulse)
                if let f = ringFrac, !finishing {
                    Circle().trim(from: 0, to: max(0.02, f))
                        .stroke(P.brand, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: Self.disc - 5, height: Self.disc - 5)
                        .animation(.easeInOut(duration: 0.8), value: f)
                }
                Circle().fill(P.ink).frame(width: 62, height: 62)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                discSymbol(finishing: finishing)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .center) { serverBadge(m) }
        .accessibilityLabel(finishing ? "Finish and save recording" : "Record")
        .sinkyHaptic(recordTaps)
        .sinkyHaptic(finishTaps)
    }

    @ViewBuilder private func discSymbol(finishing: Bool) -> some View {
        if finishing && rec.state == .finishing {
            ProgressView().tint(Color.black)
                .transition(.opacity)
        } else if finishing {
            Image(systemName: "checkmark")
                .font(.system(size: 24, weight: .heavy))
                .foregroundColor(.black)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        } else {
            Circle().fill(P.accent).frame(width: 20, height: 20)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }

    // MARK: Tabs

    private func tab(for s: LibraryScreen.Section) -> some View {
        let on = selection == s
        return Button {
            if on {
                // Already here: pop to this tab's root and scroll it to the top.
                BottomChrome.shared.reselect(s)
            } else {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = s }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: s.icon).font(.system(size: 19, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? AnyShapeStyle(P.brand) : AnyShapeStyle(P.textDim))
                Text(s.rawValue).font(.geist(size: 10.5, weight: .medium))
                    .foregroundColor(on ? P.ink : P.textDim)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background {
                if on {
                    Capsule().fill(Color.white.opacity(0.07))
                        .overlay(alignment: .bottom) { GradientRule(width: 18).padding(.bottom, 3) }
                        .matchedGeometryEffect(id: "sel", in: glassNS)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// "More" page: Collections · Query · Activity · Apple Watch · Settings, as cards.
struct MoreSection: View {
    let store: LibraryStore
    @ObservedObject private var up = Uploader.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {   // no gap above the banner
            PageHeader(title: "More", subtitle: "Collections · Query · Activity · Settings")
                .id(ScrollTop.anchor)
            VStack(spacing: 12) {
                tap(icon: "square.stack.fill", title: "Collections", sub: "Every batch you've queued, with progress.", go: .collections)
                tap(icon: "sparkle.magnifyingglass", title: "Query", sub: "Ask a question across everything in the library.", go: .query)
                tap(icon: "waveform.path.ecg", title: "Activity", sub: "Everything processing right now — pause, resume, retry, or cancel.", badge: up.pendingCount, go: .jobs)
                NavigationLink(value: Route.failed) {
                    rowLabel(icon: "exclamationmark.triangle.fill", title: "Didn't work", sub: "Every video, link or recording that failed — see why, retry, or remove.", badge: 0)
                }
                .buttonStyle(.plain)
                tap(icon: "applewatch", title: "Apple Watch", sub: "Record on the wrist; it lands here with the same place title.", go: .watch)
                tap(icon: "gearshape.fill", title: "Settings", sub: "Permissions, recording, storage, server status.", go: .settings)
            }
            .padding(16)
            }
        }
        .scrollsToTopOnReselect(.more)
    }

    private func tap(icon: String, title: String, sub: String, badge: Int = 0, go: LibraryScreen.Section) -> some View {
        Button { BottomChrome.shared.moreSub = go } label: { rowLabel(icon: icon, title: title, sub: sub, badge: badge) }
            .buttonStyle(.plain)
    }
    private func rowLabel(icon: String, title: String, sub: String, badge: Int) -> some View {
        SwiftUI.Group {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(P.surface2).frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(P.edge))
                    Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(P.brand)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.geist(size: 16, weight: .semibold)).tracking(-0.3).foregroundColor(P.ink)
                        if badge > 0 {
                            Text("\(badge)").monoLabel(10, color: Color(hex: 0xF2A57F))
                                .padding(.horizontal, 8).frame(height: 20)
                                .background(P.accent.opacity(0.16)).clipShape(Capsule())
                        }
                    }
                    Text(sub).font(.geist(size: 12.5)).foregroundColor(P.textSec).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(P.textDim)
            }
            .padding(14)
            .background(P.surface).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(P.edge))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
