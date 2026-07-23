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
    static let events: [AgentEventKind] = [.start, .tool, .waiting, .review, .done, .failed]
    static let appearanceThemes: [AppearanceTheme] = [.system, .light, .dark]
    static let fpsProfiles: [FpsProfile] = [.standard, .smooth]
    static let groupDisplays: [SessionGroupDisplay] = [.stacked, .expanded]

    static func title(for theme: AppearanceTheme) -> String {
        APCLocalizedPresentation.appearanceTitle(theme)
    }

    static func supportedFPSProfiles(for pet: PetSummary?) -> [FpsProfile] {
        pet?.supportedFPSProfiles ?? [.standard]
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

enum BehaviorSettingsLayout {
    static let wideBreakpoint: CGFloat = 800
    static let previewWidth: CGFloat = 292

    static func usesWideLayout(
        contentWidth: CGFloat,
        shellMode: ControlCenterShellMode
    ) -> Bool {
        shellMode.keepsInspectorPresented && contentWidth >= wideBreakpoint
    }
}

struct BehaviorSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.controlCenterShellMode) private var shellMode
    @SceneStorage("apc.configuration.selected-subpage")
    private var selectedSectionRawValue = BehaviorSettingsSection.appearance.rawValue
    @State private var bubbleTransparencyBeforeEditing: Double?
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
        GeometryReader { geometry in
            if BehaviorSettingsLayout.usesWideLayout(
                contentWidth: geometry.size.width,
                shellMode: shellMode
            ) {
                wideLayout
            } else {
                compactLayout
            }
        }
        .accessibilityIdentifier("configuration.root")
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            settingsColumn(showsInlinePreview: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            previewPane
                .frame(width: BehaviorSettingsLayout.previewWidth)
        }
        .accessibilityIdentifier("configuration.layout.wide")
    }

    private var compactLayout: some View {
        settingsColumn(showsInlinePreview: true)
            .accessibilityIdentifier("configuration.layout.compact")
    }

    private func settingsColumn(showsInlinePreview: Bool) -> some View {
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

            Divider()

            settingsPane(showsInlinePreview: showsInlinePreview)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func settingsPane(showsInlinePreview: Bool) -> some View {
        switch selectedSection {
        case .appearance:
            appearanceSettingsPane(showsInlinePreview: showsInlinePreview)
        case .messages:
            messageSettingsPane(showsInlinePreview: showsInlinePreview)
        }
    }

    private func appearanceSettingsPane(showsInlinePreview: Bool) -> some View {
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

                appearanceThemeSetting
                fpsSetting
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
                        bubbleTransparencySetting

                        Divider()

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

                        SettingToggle(
                            title: APCLocalization.text(.configMousePassthrough),
                            detail: APCLocalization.text(.configMousePassthroughDetail),
                            value: store.behavior.mousePassthrough,
                            accessibilityIdentifier: "configuration.appearance.mouse-passthrough"
                        ) { value in
                            updateBehavior(\.mousePassthrough, value: value)
                        }

                        Text(APCLocalization.text(.configSizeFooter))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if showsInlinePreview {
                Section {
                    appearancePreview
                        .frame(maxWidth: .infinity)
                } header: {
                    Text(APCLocalization.text(.configLivePreview))
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("configuration.page.appearance")
    }

    private func messageSettingsPane(showsInlinePreview: Bool) -> some View {
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

                        Divider()

                        sessionTimeoutSetting
                        sessionGroupDisplaySetting

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

            if showsInlinePreview {
                Section {
                    messagePreview
                        .frame(maxWidth: .infinity)
                } header: {
                    Text(APCLocalization.text(.configMessagePreview))
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("configuration.page.messages")
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(APCLocalization.text(
                selectedSection == .appearance ? .configLivePreview : .configMessagePreview
            ))
                .font(.headline)

            Divider()

            ScrollView {
                Group {
                    switch selectedSection {
                    case .appearance:
                        appearancePreview
                    case .messages:
                        messagePreview
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .accessibilityIdentifier("configuration.preview-pane")
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

    private var fpsSetting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(APCLocalization.text(.configFPSPicker), selection: fpsProfileBinding) {
                ForEach(supportedFPSProfiles) { profile in
                    Text(APCLocalizedPresentation.playbackProfileTitle(profile))
                        .tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(APCLocalization.text(.configFPSAccessibility))
            .accessibilityValue(
                APCLocalizedPresentation.playbackProfileTitle(
                    store.effectiveFPSProfile
                )
            )
            .accessibilityIdentifier("configuration.appearance.fps")

            Text(APCLocalization.text(
                supportedFPSProfiles.contains(.smooth)
                    ? store.effectiveFPSProfile == .standard
                        ? .configFPSStandardDetail
                        : .configFPSSmoothDetail
                    : .configFPSStandardDetail
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var bubbleTransparencySetting: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(APCLocalization.text(.configBubbleTransparency))
                    .font(.headline)
                Spacer()
                Text(APCLocalization.format(
                    .commonPercentFormat,
                    Int((store.behavior.bubbleTransparency * 100).rounded())
                ))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { store.behavior.bubbleTransparency },
                    set: { value in
                        if bubbleTransparencyBeforeEditing == nil {
                            bubbleTransparencyBeforeEditing = store.behavior.bubbleTransparency
                        }
                        store.previewBubbleTransparency(value)
                    }
                ),
                in: 0 ... 1,
                step: 0.05,
                onEditingChanged: { editing in
                    if editing {
                        bubbleTransparencyBeforeEditing = bubbleTransparencyBeforeEditing
                            ?? store.behavior.bubbleTransparency
                    } else if let previousValue = bubbleTransparencyBeforeEditing {
                        store.commitBubbleTransparency(from: previousValue)
                        bubbleTransparencyBeforeEditing = nil
                    }
                }
            )
            .accessibilityLabel(APCLocalization.text(.configBubbleTransparency))
            .accessibilityValue(APCLocalization.format(
                .commonPercentFormat,
                Int((store.behavior.bubbleTransparency * 100).rounded())
            ))
            .help(APCLocalization.text(.configTransparencyDetail))
            .accessibilityHint(APCLocalization.text(.configTransparencyDetail))
            .accessibilityIdentifier("configuration.appearance.bubble-transparency")

            HStack {
                Text(APCLocalization.text(.configGlassMore))
                Spacer()
                Text(APCLocalization.text(.configTransparentMore))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

        }
        .padding(.vertical, 4)
        .onDisappear {
            if let previousValue = bubbleTransparencyBeforeEditing {
                store.commitBubbleTransparency(from: previousValue)
                bubbleTransparencyBeforeEditing = nil
            }
        }
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

    private var appearancePreview: some View {
        BehaviorAppearancePreview(
            behavior: store.behavior,
            pet: store.activePet,
            assetWarning: store.activePet.flatMap {
                store.petAssetWarningIndex[$0.id]
            }
        )
    }

    private var messagePreview: some View {
        BehaviorMessagePreview(behavior: store.behavior)
    }

    private var supportedFPSProfiles: [FpsProfile] {
        BehaviorSettingsCatalog.supportedFPSProfiles(for: store.activePet)
    }

    private var fpsProfileBinding: Binding<FpsProfile> {
        Binding(
            get: { store.effectiveFPSProfile },
            set: { profile in
                guard supportedFPSProfiles.contains(profile) else { return }
                updateBehavior(\.fpsProfile, value: profile)
            }
        )
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
        return APCLocalizedPresentation.connectionHealthTitle(
            connection.health,
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

private struct BehaviorAppearancePreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let behavior: BehaviorSettings
    let pet: PetSummary?
    let assetWarning: PetAssetWarning?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                syntheticDesktop

                VStack(spacing: 14) {
                    if behavior.enabled, behavior.statusBubble {
                        previewBubble
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }

                    Spacer(minLength: 12)

                    if behavior.enabled {
                        ConfigurationPetPreviewImage(
                            pet: pet,
                            assetWarning: assetWarning
                        )
                    } else {
                        Label(APCLocalization.text(.configPetHidden), systemImage: "eye.slash")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: 360)
            .aspectRatio(0.68, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(APCLocalization.text(.configDesktopPreviewAccessibility))
            .accessibilityIdentifier("configuration.preview.desktop")

        }
        .apcAppearanceTheme(behavior.appearanceTheme)
    }

    private var syntheticDesktop: some View {
        ZStack {
            LinearGradient(
                colors: desktopColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.18))
                .frame(width: 220, height: 220)
                .blur(radius: 12)
                .offset(x: -90, y: -150)

            RoundedRectangle(cornerRadius: 70, style: .continuous)
                .fill(Color.pink.opacity(colorScheme == .dark ? 0.11 : 0.18))
                .frame(width: 260, height: 150)
                .rotationEffect(.degrees(-18))
                .blur(radius: 7)
                .offset(x: 60, y: 40)
        }
        .accessibilityHidden(true)
    }

    private var desktopColors: [Color] {
        switch behavior.appearanceTheme {
        case .light:
            [
                Color(red: 0.77, green: 0.86, blue: 0.98),
                Color(red: 0.96, green: 0.73, blue: 0.72),
                Color(red: 0.53, green: 0.66, blue: 0.88)
            ]
        case .dark:
            [
                Color(red: 0.10, green: 0.16, blue: 0.34),
                Color(red: 0.35, green: 0.19, blue: 0.40),
                Color(red: 0.04, green: 0.11, blue: 0.25)
            ]
        case .system:
            colorScheme == .dark
                ? [
                    Color(red: 0.09, green: 0.18, blue: 0.38),
                    Color(red: 0.40, green: 0.25, blue: 0.48),
                    Color(red: 0.05, green: 0.13, blue: 0.29)
                ]
                : [
                    Color(red: 0.68, green: 0.80, blue: 0.97),
                    Color(red: 0.94, green: 0.64, blue: 0.70),
                    Color(red: 0.40, green: 0.57, blue: 0.84)
                ]
        }
    }

    private var previewBubble: some View {
        HStack(alignment: .top, spacing: 9) {
            AgentIconView(source: .codex, size: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Codex")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(APCLocalizedPresentation.eventTitle(.tool))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(APCDesign.accent)
                }
                Text(APCLocalization.text(
                    behavior.autoHide ? .configBubbleAutoShow : .configBubbleWorking
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(11)
        .frame(maxWidth: 230)
        .apcTransparentBubbleGlass(
            cornerRadius: 14,
            transparency: behavior.bubbleTransparency
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("configuration.preview.status-bubble")
    }

}

private struct ConfigurationPetPreviewImage: View {
    let pet: PetSummary?
    let assetWarning: PetAssetWarning?
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: "pawprint.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(24)
                }
            }
            .frame(width: 118, height: 134)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 5)

            Text(pet?.name ?? APCLocalization.text(.configNoPetPreview))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
        }
        .task(id: previewIdentity) {
            guard let pet, let url = PetAssetLocator.coverURL(for: pet) else {
                image = nil
                return
            }
            image = PetLibraryPreviewPolicy.loadIfValidated(
                assetWarning: assetWarning
            ) {
                NSImage(contentsOf: url)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(APCLocalization.format(
            .configCurrentPetFormat,
            pet?.name ?? APCLocalization.text(.appStateNoPet)
        ))
    }

    private var previewIdentity: String {
        [
            pet?.id ?? "none",
            pet?.revisionID ?? "legacy",
            assetWarning?.fingerprint ?? "validated",
        ].joined(separator: ":")
    }
}

private struct BehaviorMessagePreview: View {
    let behavior: BehaviorSettings

    private var enabledSources: [AgentSource] {
        BehaviorSettingsCatalog.sources.filter { behavior.sources[$0, default: true] }
    }

    private var enabledEvents: [AgentEventKind] {
        BehaviorSettingsCatalog.events.filter { behavior.events[$0, default: true] }
    }

    private var visibleEvents: [AgentEventKind] {
        let limit = behavior.sessionGroupDisplay == .stacked ? 1 : 3
        return Array(enabledEvents.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if enabledSources.isEmpty {
                ContentUnavailableView(
                    APCLocalization.text(.configNoSources),
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text(APCLocalization.text(.configNoSourcesDetail))
                )
                .frame(minHeight: 150)
            } else if visibleEvents.isEmpty {
                ContentUnavailableView(
                    APCLocalization.text(.configNoEvents),
                    systemImage: "bell.slash",
                    description: Text(APCLocalization.text(.configNoEventsDetail))
                )
                .frame(minHeight: 150)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { index, event in
                        MessagePreviewRow(
                            source: enabledSources[index % enabledSources.count],
                            event: event
                        )
                    }
                }
            }

        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("configuration.preview.messages")
    }

}

private struct MessagePreviewRow: View {
    let source: AgentSource
    let event: AgentEventKind

    var body: some View {
        HStack(spacing: 9) {
            AgentIconView(source: source, size: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(eventDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(APCLocalizedPresentation.eventTitle(event))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(eventColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(eventColor.opacity(0.12), in: Capsule())
        }
        .padding(9)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private var eventDetail: String {
        switch event {
        case .start: APCLocalization.text(.configEventStartDetail)
        case .tool: APCLocalization.text(.configEventToolDetail)
        case .waiting: APCLocalization.text(.configEventWaitingDetail)
        case .review: APCLocalization.text(.configEventReviewDetail)
        case .done: APCLocalization.text(.configEventDoneDetail)
        case .failed: APCLocalization.text(.configEventFailedDetail)
        }
    }

    private var eventColor: Color {
        switch event {
        case .review, .done: APCDesign.success
        case .waiting: APCDesign.warning
        case .failed: APCDesign.destructive
        case .start, .tool: APCDesign.accent
        }
    }
}
