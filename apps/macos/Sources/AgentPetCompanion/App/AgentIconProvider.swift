import AgentPetCompanionCore
import AppKit
import SwiftUI

struct AgentIconCandidate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case appBundle
        case fileIcon
        case bundledResource
        case resource
    }

    let kind: Kind
    let path: String

    static func appBundle(_ path: String) -> Self { Self(kind: .appBundle, path: path) }
    static func fileIcon(_ path: String) -> Self { Self(kind: .fileIcon, path: path) }
    static func bundledResource(_ path: String) -> Self { Self(kind: .bundledResource, path: path) }
    static func resource(_ path: String) -> Self { Self(kind: .resource, path: path) }
}

enum AgentIconCandidates {
    static func candidates(for source: AgentSource, discoveredAppPaths: [String] = []) -> [AgentIconCandidate] {
        let candidates: [AgentIconCandidate]
        switch source {
        case .codex:
            let appPaths = discoveredAppPaths + ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
            candidates = appPaths.flatMap { appPath -> [AgentIconCandidate] in
                let resources = "\(appPath)/Contents/Resources"
                return [
                    .resource("\(resources)/icon-codex-dark-color.png"),
                    .resource("\(resources)/icon-codex-light.png"),
                    .appBundle(appPath),
                    .resource("\(resources)/app.icns"),
                    .resource("\(resources)/electron.icns"),
                    .resource("\(resources)/default_app/icon.png")
                ]
            } + executableCandidates(named: "codex")
        case .claudeCode:
            candidates = discoveredAppPaths.map(AgentIconCandidate.appBundle) + [
                .appBundle("/Applications/Claude.app"),
                .resource("/Applications/Claude.app/Contents/Resources/electron.icns")
            ] + executableCandidates(named: "claude")
        case .pi:
            candidates = [.bundledResource("PiBadge.svg")]
                + discoveredAppPaths.map(AgentIconCandidate.appBundle)
                + [
                    .appBundle("/Applications/Pi.app"),
                    .appBundle("/Applications/Pi Coding Agent.app"),
                    .resource("/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/assets/icon.png"),
                    .resource("/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/resources/icon.png"),
                    .resource("/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/icon.png")
                ] + executableCandidates(named: "pi")
        case .opencode:
            candidates = discoveredAppPaths.map(AgentIconCandidate.appBundle) + [
                .appBundle("/Applications/OpenCode.app"),
                .appBundle("/Applications/opencode.app"),
                .resource("/Applications/OpenCode.app/Contents/Resources/icon.icns"),
                .resource("/Applications/opencode.app/Contents/Resources/icon.icns")
            ] + executableCandidates(named: "opencode")
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert("\($0.kind):\($0.path)").inserted }
    }

    private static func executableCandidates(named name: String) -> [AgentIconCandidate] {
        [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            NSHomeDirectory() + "/.local/bin/\(name)"
        ].map(AgentIconCandidate.fileIcon)
    }
}

@MainActor
enum AgentIconProvider {
    private static var cache: [AgentSource: NSImage] = [:]

    static func image(for source: AgentSource) -> NSImage? {
        if let cached = cache[source] { return cached }
        for candidate in AgentIconCandidates.candidates(
            for: source,
            discoveredAppPaths: discoveredAppPaths(for: source)
        ) {
            guard let image = load(candidate) else { continue }
            image.size = NSSize(width: 32, height: 32)
            cache[source] = image
            return image
        }
        return nil
    }

    private static func discoveredAppPaths(for source: AgentSource) -> [String] {
        let identifiers: [String]
        switch source {
        case .codex:
            identifiers = ["com.openai.chat", "com.openai.chatgpt", "com.openai.codex"]
        case .claudeCode:
            identifiers = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .pi:
            identifiers = []
        case .opencode:
            identifiers = ["ai.opencode.desktop", "com.opencode.desktop"]
        }
        return identifiers.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
    }

    private static func load(_ candidate: AgentIconCandidate) -> NSImage? {
        switch candidate.kind {
        case .bundledResource:
            let url = APCResourceBundle.resourceURL(candidate.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return NSImage(contentsOf: url)
        case .appBundle, .fileIcon:
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            return NSWorkspace.shared.icon(forFile: candidate.path)
        case .resource:
            guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
            return NSImage(contentsOfFile: candidate.path)
        }
    }
}

struct AgentIconView: View {
    let source: AgentSource?
    var size: CGFloat

    var body: some View {
        Group {
            if let source, let icon = AgentIconProvider.image(for: source) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.22), style: .continuous))
        .accessibilityLabel(source?.title ?? "Agent")
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: max(4, size * 0.22), style: .continuous)
            .fill(fallbackColor)
            .overlay {
                Text(fallbackLabel)
                    .font(.system(size: max(8, size * 0.36), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }

    private var fallbackLabel: String {
        switch source {
        case .codex: "C"
        case .claudeCode: "Cl"
        case .pi: "π"
        case .opencode: "O"
        case .none: "A"
        }
    }

    private var fallbackColor: Color {
        switch source {
        case .codex: Color(red: 0.18, green: 0.45, blue: 0.95)
        case .claudeCode: Color(red: 0.78, green: 0.39, blue: 0.25)
        case .pi: Color(red: 0.04, green: 0.04, blue: 0.05)
        case .opencode: Color(red: 0.12, green: 0.12, blue: 0.14)
        case .none: Color.secondary
        }
    }
}
