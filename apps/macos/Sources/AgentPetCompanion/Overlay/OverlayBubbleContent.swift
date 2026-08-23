//! Bubble content projection models: session groups, session
//! cards, bubble copy, and the accessibility model.
import AppKit
import AgentPetCompanionCore
import Combine
import CoreGraphics
import Foundation
import QuartzCore

enum OverlaySessionGroupTone: Int, CaseIterable, Equatable {
    case running = 0
    case ready = 1
    case failed = 2
    case needsInput = 3

    init(eventType: AgentEventKind?) {
        self = switch eventType {
        case .waiting: .needsInput
        case .failed: .failed
        case .done: .ready
        case .start, .thinking, .plan, .tool, nil: .running
        }
    }

    static func aggregate(_ sessions: [OverlaySessionContent]) -> OverlaySessionGroupTone {
        sessions
            .map { OverlaySessionGroupTone(eventType: $0.eventType) }
            .max(by: { $0.rawValue < $1.rawValue })
            ?? .running
    }
}

enum OverlayBubbleProjection {
    static func contents(
        states: [ActiveAgentState],
        omittedCount: Int,
        dismissedSessionIDs: Set<String>,
        groupSessionsByAgent: Bool = false,
        standaloneSessionOrder: [String] = [],
        standaloneStackExpanded: Bool = true,
        isExpanded: (AgentSource) -> Bool
    ) -> [OverlayBubbleContent] {
        let visibleStates = states.filter {
            !dismissedSessionIDs.contains(OverlaySessionContent.stableID(
                source: $0.source,
                sessionID: $0.sessionID ?? $0.event.sessionID,
                anonymousSessionAlias: $0.anonymousSessionAlias,
                fallbackEventID: $0.event.id
            ))
        }
        if !groupSessionsByAgent {
            let stateByID = Dictionary(
                visibleStates.map { state in
                    (
                        OverlaySessionContent.stableID(
                            source: state.source,
                            sessionID: state.sessionID ?? state.event.sessionID,
                            anonymousSessionAlias: state.anonymousSessionAlias,
                            fallbackEventID: state.event.id
                        ),
                        state
                    )
                },
                uniquingKeysWith: { _, latest in latest }
            )
            var orderedStates = standaloneSessionOrder.compactMap { stateByID[$0] }
            let orderedIDs = Set(orderedStates.map {
                OverlaySessionContent.stableID(
                    source: $0.source,
                    sessionID: $0.sessionID ?? $0.event.sessionID,
                    anonymousSessionAlias: $0.anonymousSessionAlias,
                    fallbackEventID: $0.event.id
                )
            })
            // Direct projection callers may not own App presentation state.
            // Use PetCore's canonical attention/latest-first order as the
            // fallback so the first expanded card matches the folded card.
            orderedStates.append(contentsOf: visibleStates.filter {
                !orderedIDs.contains(OverlaySessionContent.stableID(
                    source: $0.source,
                    sessionID: $0.sessionID ?? $0.event.sessionID,
                    anonymousSessionAlias: $0.anonymousSessionAlias,
                    fallbackEventID: $0.event.id
                ))
            })
            // The visual list is priority-first. Stable presentation order is
            // retained inside a tone so ordinary thinking/tool churn cannot
            // make concurrent cards hop.
            orderedStates = orderedStates.enumerated().sorted { left, right in
                let leftTone = OverlaySessionGroupTone(eventType: left.element.event.eventType)
                let rightTone = OverlaySessionGroupTone(eventType: right.element.event.eventType)
                if leftTone != rightTone {
                    return leftTone.rawValue > rightTone.rawValue
                }
                return left.offset < right.offset
            }.map(\.element)

            let representedSessionCount = orderedStates.count + omittedCount
            if !standaloneStackExpanded,
               representedSessionCount > 1,
               let primaryState = orderedStates.first
            {
                return [OverlayBubbleContent(
                    standaloneState: primaryState,
                    stackSessionCount: representedSessionCount,
                    isStackExpanded: false
                )]
            }
            var cards = orderedStates.enumerated().map { index, state in
                OverlayBubbleContent(
                    standaloneState: state,
                    stackSessionCount: index == 0
                        ? representedSessionCount
                        : 1,
                    isStackExpanded: true
                )
            }
            if omittedCount > 0 {
                cards.append(.omittedSummary(count: omittedCount))
            }
            return cards
        }

        var grouped = AgentSource.allCases.compactMap { source -> OverlayBubbleContent? in
            let sourceStates = visibleStates.filter { $0.source == source }
            return sourceStates.isEmpty ? nil : OverlayBubbleContent(
                source: source,
                states: sourceStates,
                isExpanded: isExpanded(source)
            )
        }
        if omittedCount > 0 {
            grouped.append(.omittedSummary(count: omittedCount))
        }
        // The pet itself communicates idle. No session means no bubble.
        return grouped
    }
}

enum OverlaySessionSurfaceKind: Equatable {
    case app
    case cli
}

enum OverlaySessionNavigationNotice: Equatable, Sendable {
    case unavailable
    case failed
    case degradedToHost

    func localizedText(
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        switch self {
        case .unavailable:
            APCLocalization.text(.overlaySessionNavigationUnavailable, locale: locale)
        case .failed:
            APCLocalization.text(.overlaySessionNavigationFailed, locale: locale)
        case .degradedToHost:
            APCLocalization.text(.overlaySessionNavigationDegraded, locale: locale)
        }
    }
}

struct OverlaySessionContent: Equatable, Identifiable {
    var id: String
    var eventID: String
    var source: AgentSource?
    var sessionID: String?
    var eventType: AgentEventKind?
    var sessionTitle: String
    var activityText: String
    var messageText: String
    var statusText: String
    var acknowledgementID: String?
    var navigation: AgentSessionNavigation
    var navigationNotice: OverlaySessionNavigationNotice?

    var needsUserAttention: Bool {
        eventType == .waiting || eventType == .failed
    }

    var navigationCapability: NavigationCapability {
        AgentSessionRouter.validatedCapability(
            source: source,
            sessionID: sessionID,
            navigation: navigation
        )
    }
    var canOpen: Bool {
        source == nil || navigationCapability != .unavailable
    }
    var actionLabel: String {
        actionLabel()
    }
    func actionLabel(
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        guard let source else {
            return APCLocalization.text(.overlayActionOpen, locale: locale)
        }
        return APCLocalizedPresentation.navigationActionTitle(
            navigationCapability,
            source: source,
            navigation: navigation,
            locale: locale
        ) ?? APCLocalizedPresentation.navigationUnavailableTitle(locale: locale)
    }
    var surfaceKind: OverlaySessionSurfaceKind? {
        switch navigation.surface {
        case "chatgpt_app", "claude_app", "opencode_app":
            .app
        case "cli_terminal":
            .cli
        default:
            nil
        }
    }
    var surfaceLabel: String? {
        surfaceLabel()
    }
    func surfaceLabel(
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        surfaceKind.map {
            APCLocalizedPresentation.sessionSurfaceTitle($0, locale: locale)
        }
    }
    var primaryDetailText: String {
        detailCandidates.first ?? ""
    }
    var standaloneSummaryText: String {
        primaryDetailText
    }
    var detailText: String {
        primaryDetailText
    }
    var accessibilityReadingOrder: [String] {
        [
            source?.title,
            surfaceLabel,
            sessionTitle,
            statusText,
            primaryDetailText,
            accessibilityFallbackDetailText,
            actionLabel,
        ]
        .compactMap(Self.compactMessage)
    }
    var accessibilityLabel: String {
        accessibilityReadingOrder.joined(separator: ", ")
    }
    private var detailCandidates: [String] {
        if let navigationNotice {
            return [navigationNotice.localizedText()]
        }
        if let message = Self.compactMessage(messageText) {
            return [message]
        }
        if let activity = Self.compactMessage(activityText) {
            return [activity]
        }
        return []
    }
    /// Preserves a complete VoiceOver state-to-action reading order when
    /// PetCore intentionally omits displayable session copy. This text is
    /// localized product guidance, never raw connector event detail, and is
    /// not inserted into the visual bubble.
    private var accessibilityFallbackDetailText: String? {
        guard detailCandidates.isEmpty else { return nil }
        let key: APCLocalizationKey? = switch eventType {
        case .start:
            .overlayDetailRunning
        case .thinking:
            .overlayActivityThinking
        case .plan:
            .overlayActivityPlan
        case .tool:
            .overlayActivityTool
        case .waiting:
            .overlayDetailNeedsInput
        case .done:
            .overlayDetailCompleted
        case .failed:
            .overlayDetailBlocked
        case nil:
            nil
        }
        guard let key else { return nil }
        return Self.compactMessage(Self.nonredundantDetail(
            APCLocalization.text(key),
            title: sessionTitle,
            status: statusText
        ))
    }
    var dismissesAfterActivation: Bool {
        switch eventType {
        case .done: true
        case .start, .thinking, .plan, .tool, .waiting, .failed, nil: false
        }
    }

    /// Geometry-only fixture for callers that do not have live bubble
    /// content. AppStore never publishes this as a user-visible session.
    static let measurementPlaceholder = OverlaySessionContent(
        id: "measurement-placeholder",
        eventID: "measurement-placeholder",
        source: nil,
        sessionID: nil,
        eventType: nil,
        sessionTitle: "Agent Pet Companion",
        activityText: "",
        messageText: "",
        statusText: "",
        navigation: AgentSessionNavigation()
    )

    static func omittedSummary(count: Int) -> OverlaySessionContent {
        OverlaySessionContent(
            id: "omitted-session-summary",
            eventID: "omitted-session-summary",
            source: nil,
            sessionID: nil,
            eventType: nil,
            sessionTitle: APCLocalization.text(.overlayMoreSessionsTitle),
            activityText: "",
            messageText: APCLocalization.format(.overlayMoreSessionsDetailFormat, count),
            statusText: "",
            navigation: AgentSessionNavigation()
        )
    }

    init(
        id: String,
        eventID: String? = nil,
        source: AgentSource?,
        sessionID: String?,
        eventType: AgentEventKind?,
        sessionTitle: String,
        activityText: String? = nil,
        messageText: String,
        statusText: String,
        acknowledgementID: String? = nil,
        navigation: AgentSessionNavigation = AgentSessionNavigation(),
        navigationNotice: OverlaySessionNavigationNotice? = nil
    ) {
        self.id = id
        self.eventID = eventID ?? id
        self.source = source
        self.sessionID = sessionID
        self.eventType = eventType
        self.sessionTitle = sessionTitle
        self.activityText = activityText ?? ""
        self.messageText = messageText
        self.statusText = statusText
        self.acknowledgementID = acknowledgementID
        self.navigation = navigation
        self.navigationNotice = navigationNotice
    }

    init(state: ActiveAgentState) {
        let event = state.event
        let resolvedSessionID = state.sessionID ?? event.sessionID
        id = Self.stableID(
            source: event.source,
            sessionID: resolvedSessionID,
            anonymousSessionAlias: state.anonymousSessionAlias,
            fallbackEventID: event.id
        )
        eventID = event.id
        source = event.source
        sessionID = resolvedSessionID
        eventType = event.eventType
        acknowledgementID = state.acknowledgementID
        statusText = Self.displayStatus(
            for: state.overlayDisplay?.summaryKind
                ?? Self.summaryKind(for: event.eventType)
        )
        let proposedTitle = Self.sessionTitle(for: state)
        sessionTitle = Self.normalizedText(proposedTitle) == Self.normalizedText(statusText)
            ? Self.genericSessionTitle(for: state)
            : proposedTitle
        navigation = state.overlayDisplay?.navigation ?? AgentSessionNavigation()
        navigationNotice = nil
        activityText = Self.nonredundantDetail(
            Self.activityDetail(for: state),
            title: sessionTitle,
            status: statusText
        )
        messageText = Self.nonredundantMessage(
            Self.assistantMessage(for: state) ?? "",
            title: sessionTitle,
            status: statusText
        )
    }

    init(event: AgentEvent) {
        id = Self.stableID(
            source: event.source,
            sessionID: event.sessionID,
            fallbackEventID: event.id
        )
        eventID = event.id
        source = event.source
        sessionID = event.sessionID
        eventType = event.eventType
        acknowledgementID = nil
        sessionTitle = APCLocalization.format(.overlaySessionTitleFormat, event.source.shortTitle)
        statusText = Self.displayStatus(for: Self.summaryKind(for: event.eventType))
        navigation = event.sessionNavigation
        navigationNotice = nil
        activityText = ""
        messageText = ""
    }

    static func stableID(
        source: AgentSource,
        sessionID: String?,
        anonymousSessionAlias: String? = nil,
        fallbackEventID _: String
    ) -> String {
        let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionID, !sessionID.isEmpty else {
            if let anonymousSessionAlias = validatedAnonymousAlias(anonymousSessionAlias) {
                return "session-\(source.rawValue)-\(anonymousSessionAlias)"
            }
            // PetCore groups unattributed events into one source-scoped session.
            // Match that identity here so hook revisions update the existing row
            // instead of removing/reinserting it and clearing manual dismissal.
            return "session-\(source.rawValue)-unattributed"
        }
        return "session-\(source.rawValue)-\(sessionID)"
    }

    static func reopenID(for state: ActiveAgentState) -> String {
        let stableID = stableID(
            source: state.source,
            sessionID: state.sessionID ?? state.event.sessionID,
            anonymousSessionAlias: state.anonymousSessionAlias,
            fallbackEventID: state.event.id
        )
        switch state.event.eventType {
        case .waiting, .failed:
            return "attention:\(stableID):\(state.event.id)"
        case .start, .thinking, .plan, .tool, .done:
            return "activation:\(stableID):\(state.sessionActivatedAt ?? "initial")"
        }
    }

    private static func sessionTitle(for state: ActiveAgentState) -> String {
        if let title = compactTitle(state.sessionTitle) {
            return title
        }
        if state.sessionUserMessage?.role == "user",
           let title = compactTitle(state.sessionUserMessage?.content)
        {
            return title
        }
        return genericSessionTitle(for: state)
    }

    private static func genericSessionTitle(for state: ActiveAgentState) -> String {
        if let label = anonymousAliasLabel(state.anonymousSessionAlias) {
            return APCLocalization.format(
                .overlaySessionAliasTitleFormat,
                state.source.shortTitle,
                label
            )
        }
        return APCLocalization.format(.overlaySessionTitleFormat, state.source.shortTitle)
    }

    static func anonymousAliasLabel(_ value: String?) -> String? {
        guard let value = validatedAnonymousAlias(value),
              value.hasPrefix("anon-"),
              let sequence = UInt64(value.dropFirst(5), radix: 36),
              sequence > 0
        else {
            return nil
        }

        var index = sequence
        var characters: [Character] = []
        while index > 0 {
            index -= 1
            let scalar = UnicodeScalar(65 + Int(index % 26))!
            characters.append(Character(scalar))
            index /= 26
        }
        return String(characters.reversed())
    }

    private static func validatedAnonymousAlias(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(
                  of: "^anon-[0-9a-z]{1,13}$",
                  options: .regularExpression
              ) != nil
        else {
            return nil
        }
        return value
    }

    private static func activityDetail(for state: ActiveAgentState) -> String? {
        // Only PetCore's bounded, normalized projection is displayable. Raw
        // connector payloads may contain commands, paths, or serialized JSON.
        compactMessage(state.sessionActivity?.content)
    }

    private static func assistantMessage(for state: ActiveAgentState) -> String? {
        guard state.sessionMessage?.role == "assistant" else { return nil }
        return compactMessage(state.sessionMessage?.content)
    }

    private static func compactTitle(_ value: String?) -> String? {
        guard let value = compactMessage(value) else { return nil }
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        return firstLine.count > 80 ? "\(firstLine.prefix(79))…" : firstLine
    }

    private static func compactMessage(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Compiled once instead of per call. `replacingOccurrences(options:
    /// .regularExpression)` builds a fresh `NSRegularExpression` every time,
    /// and this normalization runs several times per session on every bubble
    /// projection. The pattern and match options are unchanged, so the
    /// resulting text is identical.
    private static let redundancyNormalizationPattern = try? NSRegularExpression(
        pattern: "[\\s\\p{P}]+"
    )

    private static func normalizedText(_ value: String) -> String {
        let folded = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard let pattern = redundancyNormalizationPattern else { return folded }
        return pattern.stringByReplacingMatches(
            in: folded,
            range: NSRange(folded.startIndex..., in: folded),
            withTemplate: ""
        )
    }

    private static func nonredundantMessage(
        _ proposed: String,
        title: String,
        status: String
    ) -> String {
        let occupied = Set([title, status].map(normalizedText))
        return occupied.contains(normalizedText(proposed)) ? "" : proposed
    }

    private static func nonredundantDetail(
        _ proposed: String?,
        title: String,
        status: String
    ) -> String {
        guard let proposed = compactMessage(proposed) else { return "" }
        let occupied = Set([title, status].map(normalizedText))
        return occupied.contains(normalizedText(proposed)) ? "" : proposed
    }

    static func displayStatus(for summaryKind: AgentOverlaySummaryKind) -> String {
        APCLocalizedPresentation.overlayEventTitle(summaryKind)
    }

    static func summaryKind(for eventType: AgentEventKind) -> AgentOverlaySummaryKind {
        switch eventType {
        case .start: .start
        case .thinking: .thinking
        case .plan: .plan
        case .tool: .tool
        case .waiting: .needsInput
        case .done: .done
        case .failed: .failed
        }
    }

}

enum OverlayBubbleSessionPrimaryAction: Equatable {
    case expandSessions
    case activateSession

    static func resolve(content: OverlayBubbleContent) -> Self {
        content.isStacked ? .expandSessions : .activateSession
    }
}

struct OverlayBubbleContent: Equatable, Identifiable {
    var id: String
    var source: AgentSource?
    var agentName: String
    var sessions: [OverlaySessionContent]
    var isExpanded: Bool
    var omittedSessionCount: Int
    var isStandaloneSessionCard: Bool
    var standaloneStackSessionCount: Int

    var eventIDs: [String] { sessions.map(\.eventID) }
    var dismissalIDs: [String] { canDismiss ? sessions.map(\.id) : [] }
    var visibleSessions: [OverlaySessionContent] {
        guard !sessions.isEmpty, !isOmittedSummary else { return sessions }
        let ordered = sessions.enumerated().sorted { left, right in
            let leftTone = OverlaySessionGroupTone(eventType: left.element.eventType)
            let rightTone = OverlaySessionGroupTone(eventType: right.element.eventType)
            if leftTone != rightTone {
                return leftTone.rawValue > rightTone.rawValue
            }
            return left.offset < right.offset
        }.map(\.element)
        return isExpanded ? ordered : Array(ordered.prefix(1))
    }
    var sessionCount: Int { sessions.count }
    var representedSessionCount: Int {
        if isStandaloneSessionCard, !isExpanded {
            return disclosureSessionCount
        }
        return omittedSessionCount > 0 ? omittedSessionCount : sessionCount
    }
    var disclosureSessionCount: Int {
        isStandaloneSessionCard
            ? max(sessionCount, standaloneStackSessionCount)
            : sessionCount
    }
    var isOmittedSummary: Bool { omittedSessionCount > 0 }
    var canDismiss: Bool { !isOmittedSummary }
    var hasMultipleSessions: Bool { disclosureSessionCount > 1 }
    var isStacked: Bool { hasMultipleSessions && !isExpanded }
    var stackDecorationLayerCount: Int {
        guard isStacked else { return 0 }
        return min(
            OverlayGeometry.bubbleCollapsedStackLayerCount,
            max(0, disclosureSessionCount - 1)
        )
    }
    var showsStackDecoration: Bool { stackDecorationLayerCount > 0 }
    var stackDecorationDepth: CGFloat {
        let layerOffset = isStandaloneSessionCard
            ? OverlayGeometry.bubbleStandaloneStackLayerOffset
            : OverlayGeometry.bubbleCollapsedStackLayerOffset
        return CGFloat(stackDecorationLayerCount) * layerOffset
    }
    var statusTone: OverlaySessionGroupTone {
        OverlaySessionGroupTone.aggregate(sessions)
    }

    /// Geometry-only fixture; idle product state intentionally emits no
    /// bubble from AppStore.
    static let measurementPlaceholder = OverlayBubbleContent(
        id: "measurement-placeholder",
        source: nil,
        agentName: "Agent Pet Companion",
        sessions: [.measurementPlaceholder],
        isExpanded: true,
        omittedSessionCount: 0,
        isStandaloneSessionCard: false,
        standaloneStackSessionCount: 0
    )

    static func omittedSummary(count: Int) -> OverlayBubbleContent {
        OverlayBubbleContent(
            id: "omitted-session-summary",
            source: nil,
            agentName: "Agent Pet Companion",
            sessions: [.omittedSummary(count: count)],
            isExpanded: true,
            omittedSessionCount: count,
            isStandaloneSessionCard: false,
            standaloneStackSessionCount: 0
        )
    }

    init(
        id: String,
        source: AgentSource?,
        agentName: String,
        sessions: [OverlaySessionContent],
        isExpanded: Bool = true,
        omittedSessionCount: Int = 0,
        isStandaloneSessionCard: Bool = false,
        standaloneStackSessionCount: Int = 0
    ) {
        self.id = id
        self.source = source
        self.agentName = agentName
        self.sessions = sessions
        self.isExpanded = isExpanded
        self.omittedSessionCount = omittedSessionCount
        self.isStandaloneSessionCard = isStandaloneSessionCard
        self.standaloneStackSessionCount = standaloneStackSessionCount
    }

    init(source: AgentSource, states: [ActiveAgentState], isExpanded: Bool = true) {
        id = "agent-\(source.rawValue)"
        self.source = source
        agentName = source.title
        let orderedStates = Array(states
            .enumerated()
            .sorted(by: Self.isMoreRecentlyActivated)
            .prefix(8))
        sessions = orderedStates.map { entry in
            OverlaySessionContent(state: entry.element)
        }
        self.isExpanded = isExpanded
        omittedSessionCount = 0
        isStandaloneSessionCard = false
        standaloneStackSessionCount = 0
    }

    init(state: ActiveAgentState) {
        self.init(source: state.source, states: [state])
    }

    init(
        standaloneState state: ActiveAgentState,
        stackSessionCount: Int = 1,
        isStackExpanded: Bool = true
    ) {
        let session = OverlaySessionContent(state: state)
        self.init(
            id: "session-card-\(session.id)",
            source: state.source,
            agentName: state.source.title,
            sessions: [session],
            isExpanded: isStackExpanded,
            isStandaloneSessionCard: true,
            standaloneStackSessionCount: stackSessionCount
        )
    }

    init(event: AgentEvent?) {
        guard let event else {
            self = .measurementPlaceholder
            return
        }
        id = "agent-\(event.source.rawValue)"
        source = event.source
        agentName = event.source.title
        sessions = [OverlaySessionContent(event: event)]
        isExpanded = true
        omittedSessionCount = 0
        isStandaloneSessionCard = false
        standaloneStackSessionCount = 0
    }

    private static func isMoreRecentlyActivated(
        _ left: EnumeratedSequence<[ActiveAgentState]>.Element,
        _ right: EnumeratedSequence<[ActiveAgentState]>.Element
    ) -> Bool {
        if let leftTime = left.element.sessionActivatedAt,
           let rightTime = right.element.sessionActivatedAt,
           leftTime != rightTime
        {
            return leftTime > rightTime
        }
        // PetCore has already projected a stable first-seen order for legacy
        // sessions without an activation timestamp. Preserve that order and
        // do not let a later Waiting/Failed status edge promote an old session.
        return left.offset < right.offset
    }
}

struct OverlayBubbleAccessibilityModel: Equatable {
    var sessionActionLabels: [String?]
    var sessionCloseActionLabels: [String?]
    var closeActionLabel: String?
    var closeActionHint: String?
    var groupActionLabel: String?

    init(content: OverlayBubbleContent, locale: String? = nil) {
        sessionActionLabels = content.visibleSessions.map { session in
            guard session.canOpen else { return nil }
            guard session.source != nil else {
                return Self.text(.overlayActionOpen, locale: locale)
            }
            return session.actionLabel(
                locale: locale ?? APCLocalization.interfaceLocaleIdentifier
            )
        }
        sessionCloseActionLabels = content.visibleSessions.map { _ in
            content.canDismiss
                ? Self.text(.overlayDismissSession, locale: locale)
                : nil
        }
        closeActionLabel = content.canDismiss
            ? Self.text(.overlayCloseBubbleAccessibility, locale: locale)
            : nil
        closeActionHint = content.canDismiss
            ? Self.text(.overlayCloseBubbleHint, locale: locale)
            : nil
        groupActionLabel = content.hasMultipleSessions
            ? Self.format(
                content.isExpanded
                    ? .overlayCollapseSessionsFormat
                    : .overlayExpandSessionsFormat,
                content.disclosureSessionCount,
                locale: locale
            )
            : nil
    }

    private static func text(_ key: APCLocalizationKey, locale: String?) -> String {
        locale.map { APCLocalization.text(key, locale: $0) }
            ?? APCLocalization.text(key)
    }

    private static func format(
        _ key: APCLocalizationKey,
        _ count: Int,
        locale: String?
    ) -> String {
        locale.map { APCLocalization.format(key, locale: $0, count) }
            ?? APCLocalization.format(key, count)
    }
}
