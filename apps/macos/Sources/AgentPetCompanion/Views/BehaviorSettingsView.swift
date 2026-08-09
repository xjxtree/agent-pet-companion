import AgentPetCompanionCore
import AppKit
import SwiftUI

enum BehaviorSettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case messages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: APCLocalization.text(.configSectionAppearance)
        case .messages: APCLocalization.text(.configSectionMessages)
        }
    }
}

enum BehaviorSettingsCatalog {
    static let sources: [AgentSource] = [.codex, .claudeCode, .pi, .opencode]
    static let events: [AgentEventKind] = [
        .start, .thinking, .plan, .tool, .waiting, .done, .failed,
    ]
    static let interfaceLanguages: [InterfaceLanguage] = [
        .system,
        .english,
        .simplifiedChinese,
    ]
    static let appearanceThemes: [AppearanceTheme] = [.system, .light, .dark]
    static let groupDisplays: [SessionGroupDisplay] = [.stacked, .expanded]
    static let bubbleFontScales: [BubbleFontScale] = [.standard, .large]

    static func title(for theme: AppearanceTheme) -> String {
        APCLocalizedPresentation.appearanceTitle(theme)
    }

    static func title(for language: InterfaceLanguage) -> String {
        APCLocalizedPresentation.interfaceLanguageTitle(language)
    }

    static func attentionPresetOptions(
        selection: AttentionPreset,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> [AttentionPresetOption] {
        let selectablePresets: [AttentionPreset] = [
            .onlyWhenNeeded,
            .standard,
            .allActivity,
        ]
        var options = selectablePresets.map {
            AttentionPresetOption(
                preset: $0,
                title: APCLocalizedPresentation.attentionPresetTitle($0, locale: locale),
                detail: attentionPresetDetail($0, locale: locale)
            )
        }
        if selection == .custom {
            options.append(AttentionPresetOption(
                preset: .custom,
                title: APCLocalizedPresentation.attentionPresetTitle(.custom, locale: locale),
                detail: attentionPresetDetail(.custom, locale: locale)
            ))
        }
        return options
    }

    static func attentionPresetDetail(
        _ preset: AttentionPreset,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let enabledEvents = preset.enabledEvents ?? []
        if preset == .custom {
            return APCLocalization.text(.configAttentionPresetCustomDetail, locale: locale)
        }
        let eventTitles = AgentEventKind.allCases
            .filter(enabledEvents.contains)
            .map { APCLocalizedPresentation.eventTitle($0, locale: locale) }
        guard !eventTitles.isEmpty else {
            return APCLocalization.text(.configNoEventsDetail, locale: locale)
        }
        return "\(APCLocalization.text(.configResponseEvents, locale: locale)): "
            + eventTitles.joined(separator: " · ")
    }
}

struct BehaviorSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.controlCenterShellMode) private var shellMode
    @SceneStorage("apc.configuration.selected-subpage")
    private var selectedSectionRawValue = BehaviorSettingsSection.appearance.rawValue
    @State private var displayWidthDraft =
        OverlayPlacement.defaultDisplayWidthPt
    @State private var displayWidthEditing = false
    @State private var appearanceAdvancedExpanded = false
    @State private var messagesAdvancedExpanded = false

    init(initialSection: BehaviorSettingsSection = .appearance) {
        _selectedSectionRawValue = SceneStorage(
            wrappedValue: initialSection.rawValue,
            "apc.configuration.selected-subpage"
        )
    }

    private var selectedSection: BehaviorSettingsSection {
        BehaviorSettingsSection(rawValue: selectedSectionRawValue) ?? .appearance
    }

    private var sectionSelection: Binding<BehaviorSettingsSection> {
        Binding(
            get: { selectedSection },
            set: { selectedSectionRawValue = $0.rawValue }
        )
    }

    private var eventGridColumns: [GridItem] {
        if shellMode == .singleContent {
            [GridItem(.flexible(), spacing: 12)]
        } else {
            [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
            ]
        }
    }

    var body: some View {
        settingsColumn
            .accessibilityIdentifier("configuration.root")
    }

    private var settingsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductPageHeader(
                identity: ProductComponentIdentity(scope: "configuration"),
                title: NavigationSection.configuration.localizedTitle,
                summary: APCLocalization.text(
                    selectedSection == .appearance
                        ? .configSubtitleAppearance
                        : .configSubtitleMessages
                )
            )
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Picker(APCLocalization.text(.configPagePicker), selection: sectionSelection) {
                ForEach(BehaviorSettingsSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .accessibilityLabel(APCLocalization.text(.configPagePicker))
            .accessibilityIdentifier("configuration.subpage-picker")

            LayoutPreservingHorizontalSeparatorGap()

            settingsPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var settingsPane: some View {
        switch selectedSection {
        case .appearance:
            appearanceSettingsPane
        case .messages:
            messageSettingsPane
        }
    }

    private var appearanceSettingsPane: some View {
        Form {
            Section {
                SettingToggle(
                    title: APCLocalization.text(.configShowPet),
                    detail: APCLocalization.text(.configShowPetDetail),
                    value: store.behavior.enabled,
                    accessibilityIdentifier: "configuration.appearance.enabled"
                ) { value in
                    updateBehavior(\.enabled, value: value)
                }

                SettingToggle(
                    title: APCLocalization.text(.configStatusBubble),
                    detail: APCLocalization.text(.configStatusBubbleDetail),
                    value: store.behavior.statusBubble,
                    accessibilityIdentifier: "configuration.appearance.status-bubble"
                ) { value in
                    updateBehavior(\.statusBubble, value: value)
                }

                interfaceLanguageSetting
                appearanceThemeSetting
                petDisplayWidthSetting
                bubbleFontScaleSetting
            } header: {
                Text(APCLocalization.text(.configDisplayAppearance))
            }

            Section {
                AdvancedDetailsDisclosure(
                    identity: ProductComponentIdentity(
                        scope: "configuration",
                        instance: "appearance"
                    ),
                    title: APCLocalization.text(.configAdvancedAppearance),
                    summary: APCLocalization.text(.configAdvancedAppearanceDetail),
                    isExpanded: $appearanceAdvancedExpanded
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingToggle(
                            title: APCLocalization.text(.configAutoHide),
                            detail: APCLocalization.text(.configAutoHideDetail),
                            value: store.behavior.autoHide,
                            accessibilityIdentifier: "configuration.appearance.auto-hide"
                        ) { value in
                            updateBehavior(\.autoHide, value: value)
                        }

                        SettingToggle(
                            title: APCLocalization.text(.configContextMenu),
                            detail: APCLocalization.text(.configContextMenuDetail),
                            value: store.behavior.clickMenu,
                            accessibilityIdentifier: "configuration.appearance.context-menu"
                        ) { value in
                            updateBehavior(\.clickMenu, value: value)
                        }

                        Text(APCLocalization.text(.configSizeFooter))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        }
        .formStyle(.grouped)
        .accessibilityIdentifier("configuration.page.appearance")
    }

    private var messageSettingsPane: some View {
        Form {
            Section {
                AttentionPresetPicker(
                    identity: ProductComponentIdentity(
                        scope: "configuration",
                        instance: "messages"
                    ),
                    title: APCLocalization.text(.configAttentionPreset),
                    selection: store.behavior.attentionPreset,
                    options: BehaviorSettingsCatalog.attentionPresetOptions(
                        selection: store.behavior.attentionPreset
                    )
                ) {
                    store.setAttentionPreset($0)
                }
            }

            Section {
                sessionGroupingSetting
                sessionGroupDisplaySetting
            }

            Section {
                AdvancedDetailsDisclosure(
                    identity: ProductComponentIdentity(
                        scope: "configuration",
                        instance: "messages"
                    ),
                    title: APCLocalization.text(.configAdvancedMessages),
                    summary: APCLocalization.text(.configAdvancedMessagesDetail),
                    isExpanded: $messagesAdvancedExpanded
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(APCLocalization.text(.configResponseSources))
                            .font(.headline)

                        ForEach(BehaviorSettingsCatalog.sources) { source in
                            SourceToggle(source: source)
                        }

                        Divider()

                        Text(APCLocalization.text(.configResponseEvents))
                            .font(.headline)

                        LazyVGrid(
                            columns: eventGridColumns,
                            spacing: 10
                        ) {
                            ForEach(BehaviorSettingsCatalog.events) { event in
                                EventToggle(event: event)
                            }
                        }
                        .padding(.vertical, 2)

                        Text(APCLocalization.text(.configEventReactionMapping))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(
                                "configuration.messages.event-reaction-mapping"
                            )

                        Divider()

                        sessionTimeoutSetting

                        Text(APCLocalization.text(.configPersistenceNote))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(
                                "configuration.messages.persistence-note"
                            )
                    }
                }
            }

        }
        .formStyle(.grouped)
        .accessibilityIdentifier("configuration.page.messages")
    }

    private var appearanceThemeSetting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(APCLocalization.text(.configThemePicker), selection: behaviorBinding(\.appearanceTheme)) {
                ForEach(BehaviorSettingsCatalog.appearanceThemes) { theme in
                    Text(BehaviorSettingsCatalog.title(for: theme)).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(APCLocalization.text(.configThemeAccessibility))
            .accessibilityValue(BehaviorSettingsCatalog.title(for: store.behavior.appearanceTheme))
            .help(APCLocalization.text(.configThemeDetail))
            .accessibilityHint(APCLocalization.text(.configThemeDetail))
            .accessibilityIdentifier("configuration.appearance.theme")
        }
        .padding(.vertical, 4)
    }

    private var interfaceLanguageSetting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                APCLocalization.text(.configLanguagePicker),
                selection: behaviorBinding(\.interfaceLanguage)
            ) {
                ForEach(BehaviorSettingsCatalog.interfaceLanguages) { language in
                    Text(BehaviorSettingsCatalog.title(for: language))
                        .tag(language)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(APCLocalization.text(.configLanguageAccessibility))
            .accessibilityValue(
                BehaviorSettingsCatalog.title(for: store.behavior.interfaceLanguage)
            )
            .help(APCLocalization.text(.configLanguageDetail))
            .accessibilityHint(APCLocalization.text(.configLanguageDetail))
            .accessibilityIdentifier("configuration.appearance.language")

            Text(APCLocalization.text(.configLanguageDetail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var petDisplayWidthSetting: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(APCLocalization.text(.configDisplaySize))
                    .font(.headline)
                Spacer()
                Text(APCLocalization.format(
                    .configDisplayWidthValueFormat,
                    Int(displayWidthDraft.rounded())
                ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { displayWidthDraft },
                    set: { value in
                        let rounded = value.rounded()
                        displayWidthDraft = rounded
                        store.previewOverlayDisplayWidthPt(
                            CGFloat(rounded)
                        )
                    }
                ),
                in: OverlayPlacement.minimumDisplayWidthPt
                    ... OverlayPlacement.maximumDisplayWidthPt,
                step: 1,
                onEditingChanged: { editing in
                    displayWidthEditing = editing
                    if !editing {
                        store.commitOverlayDisplayWidthPt(
                            CGFloat(displayWidthDraft)
                        )
                    }
                }
            )
            .accessibilityLabel(APCLocalization.text(
                .configDisplayWidthAccessibility
            ))
            .accessibilityValue(APCLocalization.format(
                .configDisplayWidthValueFormat,
                Int(displayWidthDraft.rounded())
            ))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 1.0 : -1.0
                adjustDisplayWidth(by: delta)
            }
            .onMoveCommand { direction in
                let step = NSEvent.modifierFlags.contains(.option) ? 10.0 : 1.0
                switch direction {
                case .left, .down:
                    adjustDisplayWidth(by: -step)
                case .right, .up:
                    adjustDisplayWidth(by: step)
                default:
                    break
                }
            }
            .accessibilityIdentifier("configuration.appearance.pet-size")

            HStack(alignment: .firstTextBaseline) {
                Text(APCLocalization.text(.configSizeGuidance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(APCLocalization.text(.configDisplayWidthReset)) {
                    displayWidthDraft =
                        OverlayPlacement.defaultDisplayWidthPt
                    store.resetOverlayDisplayWidthPt()
                }
                .buttonStyle(.link)
                .accessibilityIdentifier(
                    "configuration.appearance.pet-size-reset"
                )
            }

            if let displayClarityGuidance {
                Label(
                    displayClarityGuidance.text,
                    systemImage: displayClarityGuidance.exceedsLimit
                        ? "info.circle.fill"
                        : "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(
                    displayClarityGuidance.exceedsLimit
                        ? Color.orange
                        : Color.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(
                    "configuration.appearance.pet-size-clarity"
                )
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            displayWidthDraft = Double(store.overlayDisplayWidthPt)
        }
        .onChange(of: store.overlayDisplayWidthPt) { _, value in
            guard !displayWidthEditing else { return }
            displayWidthDraft = Double(value)
        }
        .onDisappear {
            store.commitOverlayDisplayWidthPt(
                CGFloat(displayWidthDraft)
            )
        }
    }

    private var displayClarityGuidance: (
        text: String,
        exceedsLimit: Bool
    )? {
        guard let quality = store.activePet?.quality else { return nil }
        let clarityLimitPt = quality.renderSize.width / 2
        let exceedsLimit = displayWidthDraft > Double(clarityLimitPt)
        return (
            APCLocalization.format(
                exceedsLimit
                    ? .configDisplayClarityWarningFormat
                    : .configDisplayClarityLimitFormat,
                APCLocalizedPresentation.qualityTitle(quality),
                clarityLimitPt
            ),
            exceedsLimit
        )
    }

    private func adjustDisplayWidth(by delta: Double) {
        let next = min(
            OverlayPlacement.maximumDisplayWidthPt,
            max(
                OverlayPlacement.minimumDisplayWidthPt,
                displayWidthDraft + delta
            )
        )
        displayWidthDraft = next
        store.previewOverlayDisplayWidthPt(CGFloat(next))
    }

    private var bubbleFontScaleSetting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(APCLocalization.text(.configBubbleFontScale))
                .font(.headline)

            Picker(
                APCLocalization.text(.configBubbleFontScale),
                selection: behaviorBinding(\.bubbleFontScale)
            ) {
                ForEach(BehaviorSettingsCatalog.bubbleFontScales) { scale in
                    Text(APCLocalizedPresentation.bubbleFontScaleTitle(scale)).tag(scale)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(APCLocalization.text(.configBubbleFontScale))
            .accessibilityValue(
                APCLocalizedPresentation.bubbleFontScaleTitle(store.behavior.bubbleFontScale)
            )
            .help(APCLocalization.text(.configBubbleFontScaleDetail))
            .accessibilityHint(APCLocalization.text(.configBubbleFontScaleDetail))
            .accessibilityIdentifier("configuration.appearance.bubble-font-scale")

            Text(APCLocalization.text(.configBubbleFontScaleDetail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var sessionTimeoutSetting: some View {
        Stepper(
            value: behaviorBinding(\.sessionMessageTimeoutMinutes),
            in: 1 ... 1_440
        ) {
            HStack {
                Text(APCLocalization.text(.configTimeout))
                    .font(.headline)
                Spacer()
                Text(APCLocalization.format(
                    .commonMinutesFormat,
                    store.behavior.sessionMessageTimeoutMinutes
                ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(APCLocalization.text(.configTimeout))
        .accessibilityValue(APCLocalization.format(
            .commonMinutesFormat,
            store.behavior.sessionMessageTimeoutMinutes
        ))
        .help(APCLocalization.text(.configTimeoutDetail))
        .accessibilityHint(APCLocalization.text(.configTimeoutDetail))
        .accessibilityIdentifier("configuration.messages.timeout")
        .padding(.vertical, 4)
    }

    private var sessionGroupingSetting: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(
                APCLocalization.text(.configGroupSessionsByAgent),
                isOn: behaviorBinding(\.groupSessionsByAgent)
            )
            .font(.headline)
            .accessibilityIdentifier("configuration.messages.group-by-agent")

            Text(APCLocalization.text(.configGroupSessionsByAgentDetail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var sessionGroupDisplaySetting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(APCLocalization.text(.configGroupDisplay), selection: behaviorBinding(\.sessionGroupDisplay)) {
                ForEach(BehaviorSettingsCatalog.groupDisplays) { display in
                    Text(APCLocalizedPresentation.sessionGroupTitle(display)).tag(display)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(APCLocalization.text(.configGroupDisplay))
            .accessibilityValue(
                APCLocalizedPresentation.sessionGroupTitle(store.behavior.sessionGroupDisplay)
            )
            .help(APCLocalization.text(.configGroupDisplayDetail))
            .accessibilityHint(APCLocalization.text(.configGroupDisplayDetail))
            .accessibilityIdentifier("configuration.messages.group-display")
        }
        .padding(.vertical, 4)
    }

    private func behaviorBinding<Value>(
        _ keyPath: WritableKeyPath<BehaviorSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.behavior[keyPath: keyPath] },
            set: { updateBehavior(keyPath, value: $0) }
        )
    }

    private func updateBehavior<Value>(
        _ keyPath: WritableKeyPath<BehaviorSettings, Value>,
        value: Value
    ) {
        var next = store.behavior
        next[keyPath: keyPath] = value
        store.updateBehavior(next)
    }
}

struct SettingToggle: View {
    var title: String
    var detail: String
    var value: Bool
    var accessibilityIdentifier: String
    var onChange: (Bool) -> Void

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { value },
                set: { onChange($0) }
            )
        ) {
            Text(title)
                .font(.headline)
        }
        .toggleStyle(.switch)
        .tint(APCDesign.accent)
        .help(detail)
        .accessibilityLabel(title)
        .accessibilityValue(UIControlSemantics.toggleValue(isOn: value))
        .accessibilityHint(detail)
        .accessibilityIdentifier(accessibilityIdentifier)
        .padding(.vertical, 4)
    }
}

struct SourceToggle: View {
    @EnvironmentObject private var store: AppStore
    var source: AgentSource

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { isEnabled },
                set: { value in
                    var next = store.behavior
                    next.sources[source] = value
                    store.updateBehavior(next)
                }
            )
        ) {
            HStack(spacing: 10) {
                AgentIconView(source: source, size: 30)
                Text(source.title)
                    .font(.headline)
            }
        }
        .toggleStyle(.switch)
        .tint(APCDesign.accent)
        .help(sourceDetail)
        .accessibilityLabel(UIControlSemantics.sourceLabel(source))
        .accessibilityValue(APCLocalization.format(
            .connectionsMetadataFormat,
            UIControlSemantics.toggleValue(isOn: isEnabled),
            sourceDetail
        ))
        .accessibilityHint(sourceDetail)
        .accessibilityIdentifier("configuration.messages.source.\(source.rawValue)")
        .padding(.vertical, 4)
    }

    private var isEnabled: Bool {
        store.behavior.sources[source, default: true]
    }

    private var sourceDetail: String {
        ConfigurationSourcePresentation.detail(
            source: source,
            status: store.connections.first(where: { $0.source == source }),
            operationState: store.connectionOperationState
        )
    }
}

enum ConfigurationSourcePresentation {
    static func detail(
        source: AgentSource,
        status: AgentConnectionStatus?,
        operationState: AgentConnectionOperationState,
        localeIdentifier: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let connection = AgentConnectionProductPresentation(
            source: source,
            status: status,
            operationState: operationState
        )
        return AgentConnectionsPresentation.healthTitle(
            for: connection,
            locale: localeIdentifier
        )
    }
}

struct EventToggle: View {
    @EnvironmentObject private var store: AppStore
    var event: AgentEventKind

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { isEnabled },
                set: { value in
                    var next = store.behavior
                    next.events[event] = value
                    store.updateBehavior(next)
                }
            )
        ) {
            Text(APCLocalizedPresentation.eventTitle(event))
                .font(.headline)
        }
        .toggleStyle(.switch)
        .tint(APCDesign.accent)
        .accessibilityLabel(UIControlSemantics.eventLabel(event))
        .accessibilityValue(UIControlSemantics.toggleValue(isOn: isEnabled))
        .accessibilityIdentifier("configuration.messages.event.\(event.rawValue)")
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var isEnabled: Bool {
        store.behavior.events[event, default: true]
    }
}
