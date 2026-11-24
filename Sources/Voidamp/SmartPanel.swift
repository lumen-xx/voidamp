import SwiftUI
import AppKit

/// Smart mode's panel, laid out like Control Centre's Sound: the output level, a quieter slider for each playing
/// app, and the outputs to choose from. Microphones aren't shown; in Smart mode the microphone follows the output.
struct SmartPanel: View {
    @ObservedObject var audio: AudioController
    @State private var draggingApps: Set<String> = []
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sound").font(MixerStyle.title)
                Spacer()
                // No Mic button here, so a muted microphone says so until it is unmuted.
                if audio.micMuted {
                    Button { audio.toggleMicMute() } label: {
                        Label("Mic Muted", systemImage: "mic.slash.fill")
                            .font(MixerStyle.caption)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            .modifier(ToolbarIslandSurface())
                    }
                    .buttonStyle(.plain)
                    .help("Unmute microphone")
                }
            }
            .frame(height: 22)
            SoundLevelSlider(value: Binding(get: {
                output.map { audio.displayVolume($0) } ?? 0
            }, set: { volume in
                // Without a Sound button, moving the level unmutes, as in Control Centre.
                audio.unmuteSound()
                if let output { audio.setVolume(output, volume) }
            }), muted: audio.soundMuted)
            .disabled(output?.channels.isEmpty ?? true)
            .help(output.map { "\(audio.displayName($0)) volume" } ?? "No output device")
            CappedScroll {
                VStack(alignment: .leading, spacing: 10) {
                    // Only apps giving output right now; with none, the section goes. Paused apps aren't kept listed
                    // as in the full panel.
                    if !playing.isEmpty {
                        Divider()
                        ForEach(playing) { app in appRow(app) }
                        if !audio.mixingEnabled {
                            Button("Turn On App Volumes") { audio.enableMixing() }
                                .buttonStyle(.link).font(MixerStyle.caption)
                        } else if audio.captureBlocked {
                            CaptureNotice(audio: audio)
                        }
                    }
                    Divider()
                    sectionLabel("Output")
                    VStack(spacing: 2) {
                        // Virtual mics are microphones to apps; their output side is only for the Suite to feed.
                        ForEach(audio.sources.filter { !$0.input && !$0.isVirtualMic }) { source in outputRow(source) }
                    }
                }
                // Room for the output rows' highlight, which reaches past the labels: the scroll view clips at its
                // edges, which cut the highlight's rounded corners square.
                .padding(.horizontal, 6)
            }
            .padding(.horizontal, -6)
        }
    }

    private var output: AudioSource? { audio.sources.first { !$0.input && $0.isDefault } }
    private var playing: [AppSource] { audio.apps.filter(\.isPlaying) }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(MixerStyle.section).foregroundStyle(.secondary)
    }

    /// The app's icon, its name and a small level slider. Clicking the icon mutes the app; clicking the name returns
    /// it to 100%.
    private func appRow(_ app: AppSource) -> some View {
        let adjustable = audio.canAdjust(app)
        let live = audio.apps.first { $0.id == app.id } ?? app
        return HStack(spacing: 8) {
            Button { audio.toggleAppMute(app) } label: {
                Group {
                    if let icon = app.icon { Image(nsImage: icon).resizable() }
                    else { Image(systemName: app.isSystem ? "bell.fill" : "app.dashed").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                .frame(width: 16, height: 16)
                .opacity(live.muted ? 0.4 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if live.muted {
                        Image(systemName: "speaker.slash.fill").font(.system(size: 7, weight: .bold))
                            .padding(1.5).background(Circle().fill(.background)).offset(x: 3, y: 3)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!adjustable)
            .help(live.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(live.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            // With no percentage to click, the name returns the app to 100%.
            Button { audio.setAppGain(app, 1) } label: {
                Text(app.name).lineLimit(1).frame(width: 92, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!adjustable)
            .help(abs(live.gain - 1) < 0.005 ? "\(app.name) plays at 100%" : "Reset \(app.name) to 100%")
            .accessibilityLabel("Reset \(app.name) to 100 percent")
            SoundLevelSlider(value: Binding(get: { live.gain }, set: { audio.setAppGain(app, $0, snapping: draggingApps.contains(app.id)) }),
                             muted: live.muted, height: 16, maximum: 2, showsSymbol: false, label: "\(app.name) volume, up to 200 percent") { editing in
                if editing { draggingApps.insert(app.id) } else { draggingApps.remove(app.id) }
            }
            .disabled(!adjustable)
            .help("Snaps to 100% · boost up to 200%")
            if audio.routeFailures[app.id] != nil {
                Button { audio.retryMixing() } label: {
                    Image(systemName: "exclamationmark.triangle").font(MixerStyle.value).foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Voidamp can’t mix \(app.name), so it plays normally. Click to try again.")
                .accessibilityLabel("Retry mixing \(app.name)")
            }
        }
        .opacity(adjustable ? 1 : 0.55)
    }

    /// A device in a filled circle, accent-coloured when it is the output, like Control Centre's list. The row
    /// highlights under the pointer as menu items do; its icon lines up with the section labels while the
    /// highlight reaches a little past them.
    private func outputRow(_ source: AudioSource) -> some View {
        let selected = source.isDefault
        return Button { audio.select(source) } label: {
            HStack(spacing: 8) {
                Image(systemName: audio.deviceSymbol(source))
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.1)))
                Text(audio.displayName(source)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered == source.id ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { inside in
            if inside { hovered = source.id } else if hovered == source.id { hovered = nil }
        }
        .help(source.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
