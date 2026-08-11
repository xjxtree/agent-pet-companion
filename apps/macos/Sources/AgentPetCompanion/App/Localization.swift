import AgentPetCompanionCore
import Foundation
import SwiftUI

enum APCLocalizationKey: String, CaseIterable, Sendable {
    case appActionOpenControlCenter = "app.action.open_control_center"
    case appActionQuit = "app.action.quit"
    case appActionTogglePet = "app.action.toggle_pet"
    case appActionFocusPetSessions = "app.action.focus_pet_sessions"
    case navigationLibrary = "nav.library"
    case navigationAIPetMaker = "nav.ai_pet_maker"
    case navigationPetConfiguration = "nav.pet_configuration"
    case navigationConnections = "nav.connections"
    case navigationDiagnostics = "nav.diagnostics"
    case onboardingTitle = "onboarding.title"
    case onboardingProgressFormat = "onboarding.progress.format"
    case onboardingClose = "onboarding.close"
    case onboardingSkip = "onboarding.skip"
    case onboardingChooseTitle = "onboarding.choose.title"
    case onboardingChooseDetail = "onboarding.choose.detail"
    case onboardingChooseConfirm = "onboarding.choose.confirm"
    case onboardingPetsUnavailableTitle = "onboarding.pets_unavailable.title"
    case onboardingPetsUnavailableDetail = "onboarding.pets_unavailable.detail"
    case onboardingPetsRestore = "onboarding.pets_unavailable.restore"
    case onboardingPetsRestoring = "onboarding.pets_unavailable.restoring"
    case onboardingPetsRestoreFailed = "onboarding.pets_unavailable.restore_failed"
    case onboardingConnectTitle = "onboarding.connect.title"
    case onboardingConnectDetail = "onboarding.connect.detail"
    case onboardingConnectChecking = "onboarding.connect.checking"
    case onboardingConnectContinue = "onboarding.connect.continue"
    case onboardingNoAgentsTitle = "onboarding.no_agents.title"
    case onboardingNoAgentsDetail = "onboarding.no_agents.detail"
    case onboardingDemoTitle = "onboarding.demo.title"
    case onboardingDemoDetail = "onboarding.demo.detail"
    case onboardingDemoLocalLabel = "onboarding.demo.local_label"
    case onboardingDemoThinking = "onboarding.demo.thinking"
    case onboardingDemoThinkingDetail = "onboarding.demo.thinking_detail"
    case onboardingDemoWorking = "onboarding.demo.working"
    case onboardingDemoWorkingDetail = "onboarding.demo.working_detail"
    case onboardingDemoNeedsAttention = "onboarding.demo.needs_attention"
    case onboardingDemoNeedsAttentionDetail = "onboarding.demo.needs_attention_detail"
    case onboardingDemoDone = "onboarding.demo.done"
    case onboardingDemoDoneDetail = "onboarding.demo.done_detail"
    case onboardingDemoReplay = "onboarding.demo.replay"
    case onboardingDemoInvitation = "onboarding.demo.invitation"
    case onboardingFinish = "onboarding.finish"
    case onboardingServiceUnavailableTitle = "onboarding.service_unavailable.title"
    case onboardingServiceUnavailableDetail = "onboarding.service_unavailable.detail"
    case onboardingFailureService = "onboarding.failure.service"
    case onboardingFailurePetActivation = "onboarding.failure.pet_activation"
    case onboardingFailureRevisionConflict = "onboarding.failure.revision_conflict"
    case onboardingFailureRequest = "onboarding.failure.request"
    case onboardingRepairConfirmationDetail = "onboarding.repair_confirmation.detail"
    case libraryLoadingTitle = "library.loading.title"
    case libraryLoadingDetail = "library.loading.detail"
    case libraryEmptyTitle = "library.empty.title"
    case libraryEmptyDetail = "library.empty.detail"
    case libraryEmptyAction = "library.empty.action"
    case libraryImportAction = "library.import.action"
    case libraryImportInProgress = "library.import.in_progress"
    case libraryImportTitle = "library.import.title"
    case libraryImportMessage = "library.import.message"
    case libraryImportProgressTitle = "library.import.progress_title"
    case libraryImportProgressFileFormat = "library.import.progress_file_format"
    case libraryImportProgressDetailFormat = "library.import.progress_detail_format"
    case libraryImportProgressRefreshing = "library.import.progress_refreshing"
    case libraryImportProgressKeepOpen = "library.import.progress_keep_open"
    case libraryImportSuccessTitle = "library.import.success_title"
    case libraryImportSuccessCountFormat = "library.import.success_count_format"
    case libraryFormatAppOwned = "library.format.app_owned"
    case libraryValidationInvalid = "library.validation.invalid"
    case libraryValidationVerifiedTitle = "library.validation.verified_title"
    case libraryValidationVerified = "library.validation.verified"
    case libraryValidationUnverifiedTitle = "library.validation.unverified_title"
    case libraryValidationUnverified = "library.validation.unverified"
    case assetRecoveryTitle = "asset_recovery.title"
    case assetRecoveryDetail = "asset_recovery.detail"
    case assetRecoveryRepair = "asset_recovery.repair"
    case assetRecoveryRepairing = "asset_recovery.repairing"
    case assetRecoveryFailed = "asset_recovery.failed"
    case assetRecoveryDiagnostics = "asset_recovery.diagnostics"
    case librarySpecificationVerifiedStates = "library.specification.verified_states"
    case librarySpecificationUnavailable = "library.specification.unavailable"
    case libraryStateNotActive = "library.state.not_active"
    case libraryStateIdle = "library.state.idle"
    case controlEnabled = "control.enabled"
    case controlDisabled = "control.disabled"
    case controlSelected = "control.selected"
    case controlUnselected = "control.unselected"
    case controlSourceLabel = "control.source.label"
    case controlEventLabel = "control.event.label"
    case controlStyleLabel = "control.style.label"
    case controlQualityLabel = "control.quality.label"
    case errorPetpackImportFailed = "error.petpack.import_failed"
    case overlayIdleDetail = "overlay.idle.detail"
    case overlayStatusRunning = "overlay.status.running"
    case overlayStatusTool = "overlay.status.tool"
    case overlayStatusNeedsInput = "overlay.status.needs_input"
    case overlayStatusReady = "overlay.status.ready"
    case overlayStatusDone = "overlay.status.done"
    case overlayStatusBlocked = "overlay.status.blocked"
    case overlayActivityThinking = "overlay.activity.thinking"
    case overlayActivityPlan = "overlay.activity.plan"
    case overlayActivityCommand = "overlay.activity.command"
    case overlayActivityFile = "overlay.activity.file"
    case overlayActivityFileChange = "overlay.activity.file_change"
    case overlayActivityTool = "overlay.activity.tool"
    case overlayActivitySubagent = "overlay.activity.subagent"
    case overlayActivitySearch = "overlay.activity.search"
    case overlayActivityNetwork = "overlay.activity.network"
    case overlayActivityImage = "overlay.activity.image"
    case overlayActivityCompaction = "overlay.activity.compaction"
    case overlayDetailRunning = "overlay.detail.running"
    case overlayDetailNeedsInput = "overlay.detail.needs_input"
    case overlayDetailReady = "overlay.detail.ready"
    case overlayDetailCompleted = "overlay.detail.completed"
    case overlayDetailBlocked = "overlay.detail.blocked"
    case overlayActionOpen = "overlay.action.open"
    case overlayActionHandle = "overlay.action.handle"
    case commonCancel = "common.cancel"
    case commonClose = "common.close"
    case commonRetry = "common.retry"
    case commonClear = "common.clear"
    case commonChoose = "common.choose"
    case commonNotReported = "common.not_reported"
    case commonExpanded = "common.expanded"
    case commonCollapsed = "common.collapsed"
    case commonExpandDisclosureHint = "common.disclosure.expand_hint"
    case commonCollapseDisclosureHint = "common.disclosure.collapse_hint"
    case commonRecommended = "common.recommended"
    case commonMinutesFormat = "common.minutes.format"
    case commonImagesFormat = "common.images.format"
    case commonValueOfTotalFormat = "common.value_of_total.format"
    case appActionCheckConnections = "app.action.check_connections"
    case appActionShowPet = "app.action.show_pet"
    case appActionHidePet = "app.action.hide_pet"
    case appActionMore = "app.action.more"
    case appActionAbout = "app.action.about"
    case appUpdateCheckAction = "app.update.action.check"
    case appUpdateCheckingAction = "app.update.action.checking"
    case appUpdateViewAction = "app.update.action.view"
    case appUpdateDownloadAction = "app.update.action.download"
    case appUpdateRetryDownloadAction = "app.update.action.retry_download"
    case appUpdateOpenReleasePageAction = "app.update.action.open_release_page"
    case appUpdateReleaseNotesAction = "app.update.action.release_notes"
    case appUpdateLater = "app.update.action.later"
    case appUpdateOpenDownloads = "app.update.action.open_downloads"
    case appUpdateRedownloadAction = "app.update.action.redownload"
    case appUpdateRevealNewApp = "app.update.action.reveal_new_app"
    case appUpdateOpenApplications = "app.update.action.open_applications"
    case appUpdateShowInstallGuide = "app.update.action.show_install_guide"
    case appUpdateCheckTitle = "app.update.check.title"
    case appUpdateCheckingTitle = "app.update.checking.title"
    case appUpdateCheckingDetail = "app.update.checking.detail"
    case appUpdateAvailableTitleFormat = "app.update.available.title_format"
    case appUpdateAvailableCompactFormat = "app.update.available.compact_format"
    case appUpdateAvailableDetail = "app.update.available.detail"
    case appUpdateDataReassurance = "app.update.data_reassurance"
    case appUpdateAssetDetailFormat = "app.update.asset.detail_format"
    case appUpdateVerifiedRelease = "app.update.release.verified"
    case appUpdateArchitectureAppleSilicon = "app.update.architecture.apple_silicon"
    case appUpdateArchitectureIntel = "app.update.architecture.intel"
    case appUpdateCurrentTitle = "app.update.current.title"
    case appUpdateCurrentDetailFormat = "app.update.current.detail_format"
    case appUpdateFailureTitle = "app.update.failure.title"
    case appUpdateDownloadFailureTitle = "app.update.failure.download_title"
    case appUpdateFailureNetworkDetail = "app.update.failure.network_detail"
    case appUpdateFailureVerificationDetail = "app.update.failure.verification_detail"
    case appUpdateFailureOpenDetail = "app.update.failure.open_detail"
    case appUpdateInstallRequired = "app.update.install.required"
    case appUpdateInstallTitle = "app.update.install.title"
    case appUpdatePackageInvalidTitle = "app.update.install.invalid.title"
    case appUpdatePackageInvalidSubtitle = "app.update.install.invalid.subtitle"
    case appUpdateRestartFailedTitle = "app.update.install.restart_failed.title"
    case appUpdateRestartFailedSubtitle = "app.update.install.restart_failed.subtitle"
    case appUpdateInstallVersionFormat = "app.update.install.version_format"
    case appUpdateInstallSubtitle = "app.update.install.subtitle"
    case appUpdateInstallStepDownloadTitle = "app.update.install.step.download.title"
    case appUpdateInstallStepDownloadDetail = "app.update.install.step.download.detail"
    case appUpdateInstallStepReplaceTitle = "app.update.install.step.replace.title"
    case appUpdateInstallStepReplaceDetail = "app.update.install.step.replace.detail"
    case appUpdateInstallStepOpenTitle = "app.update.install.step.open.title"
    case appUpdateInstallStepOpenDetail = "app.update.install.step.open.detail"
    case appUpdateInstallStepAccessibilityFormat =
        "app.update.install.step.accessibility_format"
    case appUpdateConvergenceTitle = "app.update.convergence.title"
    case appUpdateConvergenceDetail = "app.update.convergence.detail"
    case appUpdateConvergenceWaitingTitle = "app.update.convergence.waiting.title"
    case appUpdateConvergenceWaitingDetail = "app.update.convergence.waiting.detail"
    case appUpdateConvergenceCompleteTitleFormat =
        "app.update.convergence.complete.title_format"
    case appUpdateConvergenceCompleteDetail = "app.update.convergence.complete.detail"
    case appUpdateConvergenceAttentionTitle = "app.update.convergence.attention.title"
    case appUpdateConvergenceAttentionDetail = "app.update.convergence.attention.detail"
    case appUpdateConvergenceBundledPetsTitle =
        "app.update.convergence.attention.bundled_pets.title"
    case appUpdateConvergenceBundledPetsDetail =
        "app.update.convergence.attention.bundled_pets.detail"
    case appUpdateConvergenceConnectorsTitleFormat =
        "app.update.convergence.attention.connectors.title_format"
    case appUpdateConvergenceConnectorConflictDetailFormat =
        "app.update.convergence.attention.connectors.conflict_detail_format"
    case appUpdateConvergenceConnectorHostDetailFormat =
        "app.update.convergence.attention.connectors.host_detail_format"
    case appUpdateConvergenceConnectorVerificationDetailFormat =
        "app.update.convergence.attention.connectors.verification_detail_format"
    case appUpdateConvergenceConnectorFailedDetailFormat =
        "app.update.convergence.attention.connectors.failed_detail_format"
    case appUpdateConvergenceConnectorMixedDetailFormat =
        "app.update.convergence.attention.connectors.mixed_detail_format"
    case appUpdateConvergenceServiceTitle =
        "app.update.convergence.attention.service.title"
    case appUpdateConvergenceServiceDetail =
        "app.update.convergence.attention.service.detail"
    case appUpdateConvergenceCheckAgainAction =
        "app.update.convergence.action.check_again"
    case appUpdateConvergenceOpenConnectionsAction =
        "app.update.convergence.action.open_connections"
    case appUpdateConvergenceOpenDiagnosticsAction =
        "app.update.convergence.action.open_diagnostics"
    case appUpdateConvergenceMakerBlocked = "app.update.convergence.maker_blocked"
    case appMenuCurrentPet = "app.menu.current_pet"
    case appMenuRecentAgent = "app.menu.recent_agent"
    case appStateNoPetEnabled = "app.state.no_pet_enabled"
    case appStateNoPet = "app.state.no_pet"
    case appStateNoRecentActivity = "app.state.no_recent_activity"
    case appHelpShowPet = "app.help.show_pet"
    case appHelpHidePet = "app.help.hide_pet"
    case appHelpMore = "app.help.more"
    case appHelpServiceStatus = "app.help.service_status"
    case contentServiceStatusLabel = "content.service_status.label"
    case petCoreFailureTitle = "petcore.failure.title"
    case petCoreFailureRetryingTitle = "petcore.failure.retrying_title"
    case petCoreFailureRetryingAccessibility = "petcore.failure.retrying_accessibility"
    case petCoreFailureRetryAction = "petcore.failure.retry_action"
    case aboutTagline = "about.tagline"
    case aboutProject = "about.link.project"
    case aboutPrivacy = "about.link.privacy"
    case aboutLicense = "about.link.license"
    case aboutVersionFormat = "about.version.format"
    case productLifecycleIdle = "product.lifecycle.idle"
    case productLifecycleThinking = "product.lifecycle.thinking"
    case productLifecycleTool = "product.lifecycle.tool"
    case productLifecycleWaiting = "product.lifecycle.waiting"
    case productLifecycleDone = "product.lifecycle.done"
    case productLifecycleFailed = "product.lifecycle.failed"
    case productInteractionAcknowledge = "product.interaction.acknowledge"
    case productInteractionDragLeft = "product.interaction.drag_left"
    case productInteractionDragRight = "product.interaction.drag_right"
    case productEventStart = "product.event.start"
    case productEventThinking = "product.event.thinking"
    case productEventPlan = "product.event.plan"
    case productEventTool = "product.event.tool"
    case productEventWaiting = "product.event.waiting"
    case productEventDone = "product.event.done"
    case productEventFailed = "product.event.failed"
    case productNavigationExactSession = "product.navigation.exact_session"
    case productNavigationAgentHostFormat = "product.navigation.agent_host_format"
    case productNavigationUnavailable = "product.navigation.unavailable"
    case productSessionSurfaceApp = "product.session_surface.app"
    case productSessionSurfaceCLI = "product.session_surface.cli"
    case productAttentionOnlyWhenNeeded = "product.attention.only_when_needed"
    case productAttentionStandard = "product.attention.standard"
    case productAttentionAllActivity = "product.attention.all_activity"
    case productAttentionCustom = "product.attention.custom"
    case productConnectionNotChecked = "product.connection.not_checked"
    case productConnectionChecking = "product.connection.checking"
    case productConnectionConnected = "product.connection.connected"
    case productConnectionNeedsRepair = "product.connection.needs_repair"
    case productConnectionUnavailable = "product.connection.unavailable"
    case productActionUsePet = "product.action.use_pet"
    case productActionContinueEditing = "product.action.continue_editing"
    case productActionConnect = "product.action.connect"
    case productActionVerify = "product.action.verify"
    case styleRealistic = "style.realistic"
    case styleSemiRealistic = "style.semi_realistic"
    case styleModern = "style.modern"
    case stylePixel = "style.pixel"
    case styleAnime = "style.anime"
    case styleUnspecified = "style.unspecified"
    case qualityLow = "quality.low"
    case qualityStandard = "quality.standard"
    case qualityHigh = "quality.high"
    case qualityLowDetailFormat = "quality.low_detail.format"
    case qualityStandardDetailFormat = "quality.standard_detail.format"
    case qualityHighDetailFormat = "quality.high_detail.format"
    case appearanceSystem = "appearance.system"
    case appearanceLight = "appearance.light"
    case appearanceDark = "appearance.dark"
    case interfaceLanguageSystem = "interface_language.system"
    case interfaceLanguageEnglish = "interface_language.english"
    case interfaceLanguageSimplifiedChinese = "interface_language.simplified_chinese"
    case sessionGroupStacked = "session_group.stacked"
    case sessionGroupExpanded = "session_group.expanded"
    case bubbleFontScaleStandard = "bubble_font_scale.standard"
    case bubbleFontScaleLarge = "bubble_font_scale.large"
    case checkStatusOK = "check_status.ok"
    case checkStatusNeedsFix = "check_status.needs_fix"
    case checkStatusMissing = "check_status.missing"
    case checkStatusUnverified = "check_status.unverified"
    case checkStatusUnsupported = "check_status.unsupported"
    case checkStatusNotRequired = "check_status.not_required"
    case connectionModeLight = "connection_mode.light"
    case connectionModeRuntime = "connection_mode.runtime"
    case verificationStatusVerified = "verification_status.verified"
    case verificationStatusActionRequired = "verification_status.action_required"
    case verificationStatusUnverified = "verification_status.unverified"
    case verificationStatusNotRequired = "verification_status.not_required"
    case generationCreateIdle = "generation.create.idle"
    case generationCreateStarting = "generation.create.starting"
    case generationCreateRunning = "generation.create.running"
    case generationCreateWaiting = "generation.create.waiting"
    case generationCreateCancelling = "generation.create.cancelling"
    case generationCreateSucceeded = "generation.create.succeeded"
    case generationCreateFailed = "generation.create.failed"
    case generationCreateCancelled = "generation.create.cancelled"
    case generationModifyIdle = "generation.modify.idle"
    case generationModifyStarting = "generation.modify.starting"
    case generationModifyRunning = "generation.modify.running"
    case generationModifyWaiting = "generation.modify.waiting"
    case generationModifyCancelling = "generation.modify.cancelling"
    case generationModifySucceeded = "generation.modify.succeeded"
    case generationModifyFailed = "generation.modify.failed"
    case generationModifyCancelled = "generation.modify.cancelled"
    case studioActionCancelling = "studio.action.cancelling"
    case studioActionCancelTask = "studio.action.cancel_task"
    case studioActionResume = "studio.action.resume"
    case studioActionRestart = "studio.action.restart"
    case studioActionStart = "studio.action.start"
    case studioActionNew = "studio.action.new"
    case studioPortableSkillAction = "studio.portable_skill.action"
    case studioPortableSkillTitle = "studio.portable_skill.title"
    case studioPortableSkillSubtitle = "studio.portable_skill.subtitle"
    case studioPortableSkillAboutTitle = "studio.portable_skill.about.title"
    case studioPortableSkillAboutDetail = "studio.portable_skill.about.detail"
    case studioPortableSkillCompatibilityTitle = "studio.portable_skill.compatibility.title"
    case studioPortableSkillCompatibilityDetail = "studio.portable_skill.compatibility.detail"
    case studioPortableSkillInstallationTitle = "studio.portable_skill.installation.title"
    case studioPortableSkillLocationLabel = "studio.portable_skill.location"
    case studioPortableSkillBundledVersionLabel = "studio.portable_skill.version.bundled"
    case studioPortableSkillInstalledVersionLabel = "studio.portable_skill.version.installed"
    case studioPortableSkillNotInstalled = "studio.portable_skill.version.not_installed"
    case studioPortableSkillChecking = "studio.portable_skill.checking"
    case studioPortableSkillCheckingDetail = "studio.portable_skill.checking.detail"
    case studioPortableSkillManagedTitle = "studio.portable_skill.managed.title"
    case studioPortableSkillManagedDetail = "studio.portable_skill.managed.detail"
    case studioPortableSkillStateMissing = "studio.portable_skill.state.missing"
    case studioPortableSkillStateMissingDetail = "studio.portable_skill.state.missing.detail"
    case studioPortableSkillStateCurrent = "studio.portable_skill.state.current"
    case studioPortableSkillStateCurrentDetail = "studio.portable_skill.state.current.detail"
    case studioPortableSkillStateUpdateAvailable = "studio.portable_skill.state.update_available"
    case studioPortableSkillStateUpdateAvailableDetail = "studio.portable_skill.state.update_available.detail"
    case studioPortableSkillStateNeedsReinstall = "studio.portable_skill.state.needs_reinstall"
    case studioPortableSkillStateNeedsReinstallDetail = "studio.portable_skill.state.needs_reinstall.detail"
    case studioPortableSkillStateUnmanagedCurrent = "studio.portable_skill.state.unmanaged_current"
    case studioPortableSkillStateUnmanagedCurrentDetail = "studio.portable_skill.state.unmanaged_current.detail"
    case studioPortableSkillStateConflict = "studio.portable_skill.state.conflict"
    case studioPortableSkillStateConflictDetail = "studio.portable_skill.state.conflict.detail"
    case studioPortableSkillActionInstall = "studio.portable_skill.action.install"
    case studioPortableSkillActionManage = "studio.portable_skill.action.manage"
    case studioPortableSkillActionUpdate = "studio.portable_skill.action.update"
    case studioPortableSkillActionReinstall = "studio.portable_skill.action.reinstall"
    case studioPortableSkillActionUninstall = "studio.portable_skill.action.uninstall"
    case studioPortableSkillActionOpenFolder = "studio.portable_skill.action.open_folder"
    case studioPortableSkillActionRefresh = "studio.portable_skill.action.refresh"
    case studioPortableSkillErrorTitle = "studio.portable_skill.error.title"
    case studioPortableSkillErrorLoad = "studio.portable_skill.error.load"
    case studioPortableSkillErrorInstall = "studio.portable_skill.error.install"
    case studioPortableSkillErrorUninstall = "studio.portable_skill.error.uninstall"
    case studioPortableSkillUninstallConfirmTitle = "studio.portable_skill.uninstall_confirm.title"
    case studioPortableSkillUninstallConfirmDetail = "studio.portable_skill.uninstall_confirm.detail"
    case studioPageTitle = "studio.page.title"
    case studioPageModifyFormat = "studio.page.modify_format"
    case studioPageModifySession = "studio.page.modify_session"
    case studioSubtitleIdle = "studio.subtitle.idle"
    case studioSubtitleSucceeded = "studio.subtitle.succeeded"
    case studioSubtitleFailed = "studio.subtitle.failed"
    case studioSubtitleCancelled = "studio.subtitle.cancelled"
    case studioNewPet = "studio.brief.new_pet"
    case studioSubmitted = "studio.brief.submitted"
    case studioDescriptionHeading = "studio.brief.description_heading"
    case studioDescriptionLabel = "studio.brief.description_label"
    case studioDescriptionExample = "studio.brief.description_example"
    case studioDescriptionRequired = "studio.brief.description_required"
    case studioDescriptionTemplatesTitle = "studio.brief.description_templates_title"
    case studioDescriptionTemplateAppearanceTitle = "studio.brief.template.appearance.title"
    case studioDescriptionTemplateAppearancePrompt = "studio.brief.template.appearance.prompt"
    case studioDescriptionTemplateActionTitle = "studio.brief.template.action.title"
    case studioDescriptionTemplateActionPrompt = "studio.brief.template.action.prompt"
    case studioDescriptionTemplatePaletteTitle = "studio.brief.template.palette.title"
    case studioDescriptionTemplatePalettePrompt = "studio.brief.template.palette.prompt"
    case studioDescriptionCountFormat = "studio.brief.description_count_format"
    case studioStyleHeading = "studio.brief.style_heading"
    case studioQualityHeading = "studio.brief.quality_heading"
    case studioQualityContractFormat = "studio.brief.quality_contract_format"
    case studioHighQualityUnsupported = "studio.brief.high_quality_unsupported"
    case studioAuthoredTimingSummaryFormat = "studio.authored_timing_summary.format"
    case studioReferencesHeading = "studio.brief.references_heading"
    case studioReferencesPrivacy = "studio.brief.references_privacy"
    case studioReferencesDropEmpty = "studio.brief.references_drop_empty"
    case studioReferencesDropCountFormat = "studio.brief.references_drop_count_format"
    case studioReferenceItemFormat = "studio.brief.reference_item_format"
    case studioReferencesRemove = "studio.brief.references_remove"
    case studioReferencesContract = "studio.brief.references_contract"
    case studioReferencesPanelTitle = "studio.brief.references_panel_title"
    case studioReferencesPanelMessage = "studio.brief.references_panel_message"
    case studioReferencesIssueTooMany = "studio.brief.references_issue.too_many"
    case studioReferencesIssueUnsupported = "studio.brief.references_issue.unsupported"
    case studioReferencesIssueUnavailable = "studio.brief.references_issue.unavailable"
    case studioReferencesIssueTooLarge = "studio.brief.references_issue.too_large"
    case studioReferencesIssueTotalTooLarge = "studio.brief.references_issue.total_too_large"
    case studioReferencesIssueTooManyPixels = "studio.brief.references_issue.too_many_pixels"
    case studioReferencesIssueInvalidContent = "studio.brief.references_issue.invalid_content"
    case studioReferencesIssueReselectionRequiredFormat = "studio.brief.references_issue.reselection_required_format"
    case studioCodexCheckingTitle = "studio.codex.checking_title"
    case studioCodexCheckingDetail = "studio.codex.checking_detail"
    case studioCodexMissingTitle = "studio.codex.missing_title"
    case studioCodexMissingDetail = "studio.codex.missing_detail"
    case studioCodexUnavailableTitle = "studio.codex.unavailable_title"
    case studioCodexUnavailableDetail = "studio.codex.unavailable_detail"
    case studioCodexConversationTitle = "studio.codex.conversation_title"
    case studioCodexConversationAgent = "studio.codex.conversation_agent"
    case studioCodexConversationWaiting = "studio.codex.conversation_waiting"
    case studioCodexConversationEmpty = "studio.codex.conversation_empty"
    case studioCodexConversationLatest = "studio.codex.conversation_latest"
    case studioHistoryTitle = "studio.history.title"
    case studioWorkspacePageSubtitle = "studio.workspace.page_subtitle"
    case studioWorkspaceHistoryCountFormat = "studio.workspace.history_count_format"
    case studioWorkspaceRecent = "studio.workspace.recent"
    case studioWorkspaceActiveTaskBlocksNew = "studio.workspace.active_task_blocks_new"
    case studioWorkspaceDraftSubtitle = "studio.workspace.draft_subtitle"
    case studioWorkspaceDiscardDraft = "studio.workspace.discard_draft"
    case studioWorkspaceLoadOlder = "studio.workspace.load_older"
    case studioWorkspaceNewMessages = "studio.workspace.new_messages"
    case studioWorkspaceUserName = "studio.workspace.user_name"
    case studioWorkspaceAgentName = "studio.workspace.agent_name"
    case studioWorkspaceNeedsDecision = "studio.workspace.needs_decision"
    case studioWorkspaceReplyHint = "studio.workspace.reply_hint"
    case studioWorkspaceResumeHint = "studio.workspace.resume_hint"
    case studioWorkspaceReplyPlaceholder = "studio.workspace.reply_placeholder"
    case studioWorkspaceResumePlaceholder = "studio.workspace.resume_placeholder"
    case studioWorkspaceSend = "studio.workspace.send"
    case studioWorkspaceContinue = "studio.workspace.continue"
    case studioWorkspaceCancelCleanup = "studio.workspace.cancel_cleanup"
    case studioWorkspaceRunningHint = "studio.workspace.running_hint"
    case studioWorkspaceCanceledHint = "studio.workspace.canceled_hint"
    case studioWorkspaceNonResumableFailureHint = "studio.workspace.non_resumable_failure_hint"
    case studioWorkspaceStatusCancelCleanup = "studio.workspace.status.cancel_cleanup"
    case studioWorkspaceStatusRecoverable = "studio.workspace.status.recoverable"
    case studioWorkspaceStatusPaused = "studio.workspace.status.paused"
    case studioWorkspaceStatusFailedRecoverable = "studio.workspace.status.failed_recoverable"
    case studioNotificationWaitingTitle = "studio.notification.waiting.title"
    case studioNotificationWaitingBody = "studio.notification.waiting.body"
    case studioNotificationPausedTitle = "studio.notification.paused.title"
    case studioNotificationPausedBody = "studio.notification.paused.body"
    case studioNotificationRecoverableTitle = "studio.notification.recoverable.title"
    case studioNotificationRecoverableBody = "studio.notification.recoverable.body"
    case studioNotificationCompletedTitle = "studio.notification.completed.title"
    case studioNotificationCompletedBody = "studio.notification.completed.body"
    case studioNotificationFailedTitle = "studio.notification.failed.title"
    case studioNotificationFailedBody = "studio.notification.failed.body"
    case studioHistorySummaryFormat = "studio.history.summary_format"
    case studioHistoryOpen = "studio.history.open"
    case studioHistoryEmpty = "studio.history.empty"
    case studioHistoryLoading = "studio.history.loading"
    case studioHistoryLoadFailed = "studio.history.load_failed"
    case studioHistoryFilterLabel = "studio.history.filter.label"
    case studioHistoryFilterAll = "studio.history.filter.all"
    case studioHistoryFilterSucceeded = "studio.history.filter.succeeded"
    case studioHistoryFilterFailed = "studio.history.filter.failed"
    case studioHistoryFilterCancelled = "studio.history.filter.cancelled"
    case studioHistoryFilterEmpty = "studio.history.filter.empty"
    case studioHistoryDetailTitle = "studio.history.detail_title"
    case studioHistoryTaskID = "studio.history.task_id"
    case studioHistoryBrief = "studio.history.brief"
    case studioHistoryCreated = "studio.history.created"
    case studioHistoryUpdated = "studio.history.updated"
    case studioHistoryResult = "studio.history.result"
    case studioHistoryProgress = "studio.history.progress"
    case studioHistoryLatestCodex = "studio.history.latest_codex"
    case studioHistoryNoCodex = "studio.history.no_codex"
    case studioHistoryTranscriptHint = "studio.history.transcript_hint"
    case studioHistoryOpenChatGPT = "studio.history.open_chatgpt"
    case studioHistorySessionAvailable = "studio.history.session.available"
    case studioHistorySessionArchived = "studio.history.session.archived"
    case studioHistorySessionMissing = "studio.history.session.missing"
    case studioHistorySessionUnavailable = "studio.history.session.unavailable"
    case studioHistorySessionNotCreated = "studio.history.session.not_created"
    case studioHistorySessionOpened = "studio.history.session.opened"
    case studioHistorySessionOpenFailed = "studio.history.session.open_failed"
    case studioHistoryTruncated = "studio.history.truncated"
    case studioHistoryMessageCountFormat = "studio.history.message_count_format"
    case studioHistoryStyleTagFormat = "studio.history.style_tag_format"
    case studioHistoryQualityTagFormat = "studio.history.quality_tag_format"
    case studioHistoryRetryBadge = "studio.history.retry_badge"
    case studioHistoryRetryUnavailable = "studio.history.retry_unavailable"
    case studioHistoryRetryStartingCreate = "studio.history.retry_starting.create"
    case studioHistoryRetryStartingModify = "studio.history.retry_starting.modify"
    case studioHistoryActions = "studio.history.actions"
    case studioHistoryCopyBrief = "studio.history.copy_brief"
    case studioHistoryCopyBriefSuccess = "studio.history.copy_brief_success"
    case studioHistoryCopyBriefUnavailable = "studio.history.copy_brief_unavailable"
    case studioHistoryCopyBriefReferencesNoticeFormat = "studio.history.copy_brief_references_notice_format"
    case studioHistoryResultPetTitle = "studio.history.result_pet_title"
    case studioHistoryResultPetMissing = "studio.history.result_pet_missing"
    case studioHistoryViewPet = "studio.history.view_pet"
    case studioHistoryEnablePet = "studio.history.enable_pet"
    case studioHistoryEnablingPet = "studio.history.enabling_pet"
    case studioHistoryDeleteAction = "studio.history.delete.action"
    case studioHistoryDeleteConfirmTitle = "studio.history.delete.confirm_title"
    case studioHistoryDeleteConfirmDetail = "studio.history.delete.confirm_detail"
    case studioHistoryDeleteConfirmAction = "studio.history.delete.confirm_action"
    case studioHistoryDeleteSuccess = "studio.history.delete.success"
    case studioHistoryDeleteRefreshWarning = "studio.history.delete.refresh_warning"
    case studioHistoryDeleteFailedFormat = "studio.history.delete.failed_format"
    case studioHistoryDeleteInvalidResponse = "studio.history.delete.invalid_response"
    case studioHistoryContextMenu = "studio.history.context_menu"
    case studioSessionCreate = "studio.session.create"
    case studioWelcomeTitle = "studio.session.welcome_title"
    case studioWelcomeDetail = "studio.session.welcome_detail"
    case studioOutputContractTitle = "studio.session.output_contract_title"
    case studioOutputContractDetail = "studio.session.output_contract_detail"
    case studioOutputPrivacy = "studio.session.output_privacy"
    case studioPreparing = "studio.session.preparing"
    case studioStartBlockingTitle = "studio.session.start_blocking_title"
    case studioStartBottomHint = "studio.session.start_bottom_hint"
    case studioCancelConfirmTitle = "studio.session.cancel_confirm.title"
    case studioCancelConfirmDetail = "studio.session.cancel_confirm.detail"
    case studioCancelConfirmAction = "studio.session.cancel_confirm.action"
    case studioRestartConfirmTitle = "studio.session.restart_confirm.title"
    case studioRestartConfirmDetail = "studio.session.restart_confirm.detail"
    case studioRestartConfirmAction = "studio.session.restart_confirm.action"
    case studioRuntimeCurrentAction = "studio.runtime.current_action"
    case studioRuntimeCheckpointFormat = "studio.runtime.checkpoint_format"
    case studioRuntimeElapsedFormat = "studio.runtime.elapsed_format"
    case studioRuntimeHeartbeatPending = "studio.runtime.heartbeat_pending"
    case studioRuntimeHeartbeatHealthyFormat = "studio.runtime.heartbeat_healthy_format"
    case studioRuntimeHeartbeatWaitingFormat = "studio.runtime.heartbeat_waiting_format"
    case studioRuntimeHeartbeatStaleFormat = "studio.runtime.heartbeat_stale_format"
    case studioRuntimeLastUpdateFormat = "studio.runtime.last_update_format"
    case studioResumeUnavailable = "studio.session.resume_unavailable"
    case studioResumeStarting = "studio.session.resume_starting"
    case studioResumeAccepted = "studio.session.resume_accepted"
    case studioResumeFailedFormat = "studio.session.resume_failed_format"
    case studioLegacyCheckpointFailure = "studio.session.legacy_checkpoint_failure"
    case studioFailedTitle = "studio.session.failed_title"
    case studioFailedDetail = "studio.session.failed_detail"
    case studioCancelledTitle = "studio.session.cancelled_title"
    case studioCancelledDetail = "studio.session.cancelled_detail"
    case studioSucceededTitle = "studio.session.succeeded_title"
    case studioIncompleteHistoryTitle = "studio.session.incomplete_history_title"
    case studioIncompleteHistoryDetail = "studio.session.incomplete_history_detail"
    case studioViewLibrary = "studio.session.view_library"
    case studioCancellingDetail = "studio.session.cancelling_detail"
    case studioReplySend = "studio.reply.send"
    case studioReplyWaiting = "studio.reply.waiting"
    case studioReplySucceeded = "studio.reply.succeeded"
    case studioReplyRunning = "studio.reply.running"
    case studioReplyCancelling = "studio.reply.cancelling"
    case studioReplyFailed = "studio.reply.failed"
    case studioReplyCancelled = "studio.reply.cancelled"
    case studioReplyIdle = "studio.reply.idle"
    case studioSuccessRevisionFormat = "studio.success.revision_format"
    case studioSuccessGeneric = "studio.success.generic"
    case studioSuccessPetID = "studio.success.pet_id"
    case studioSuccessRevision = "studio.success.revision"
    case studioSuccessValidation = "studio.success.validation"
    case studioPreviewRepairTitle = "studio.preview_repair.title"
    case studioPreviewRepairDetail = "studio.preview_repair.detail"
    case studioPreviewMissingDetail = "studio.preview_repair.missing_detail"
    case studioSuccessValidationFormat = "studio.success.validation_format"
    case studioStepBaseline = "studio.step.baseline"
    case studioStepBrief = "studio.step.brief"
    case studioStepRevision = "studio.step.revision"
    case studioStepValidation = "studio.step.validation"
    case studioStepGeneration = "studio.step.generation"
    case studioStepLibrary = "studio.step.library"
    case studioStageComplete = "studio.stage.complete"
    case studioStageCurrent = "studio.stage.current"
    case studioStageUpcoming = "studio.stage.upcoming"
    case studioStageFailed = "studio.stage.failed"
    case studioStageUnrecorded = "studio.stage.unrecorded"
    case studioSubmittedBrief = "studio.submitted.title"
    case studioFieldDescription = "studio.field.description"
    case studioFieldStyle = "studio.field.style"
    case studioFieldQuality = "studio.field.quality"
    case studioFieldReferences = "studio.field.references"
    case studioSubmittedPending = "studio.submitted.pending"
    case studioMessageYou = "studio.message.you"
    case studioMessageCreateRequestedFormat = "studio.message.create_requested_format"
    case studioMessageRetryCreateFormat = "studio.message.retry_create_format"
    case studioMessageRetryModify = "studio.message.retry_modify"
    case studioMessageStartCreateFailed = "studio.message.start_create_failed"
    case studioMessageStartModifyFailed = "studio.message.start_modify_failed"
    case studioBaselineTitle = "studio.baseline.title"
    case studioBaselineVerified = "studio.baseline.verified"
    case studioBaselinePetID = "studio.baseline.pet_id"
    case studioBaselineTargetState = "studio.baseline.target_state"
    case studioBaselineQuality = "studio.baseline.quality"
    case studioBaselineAnimation = "studio.baseline.animation"
    case studioBaselineRestoring = "studio.baseline.restoring"
    case studioBaselineRestoringDetail = "studio.baseline.restoring_detail"
    case studioBaselineUnavailableTitle = "studio.baseline.unavailable_title"
    case studioBaselineUnavailableDetail = "studio.baseline.unavailable_detail"
    case studioBaselineSafety = "studio.baseline.safety"
    case studioBaselineKeepContract = "studio.baseline.keep_contract"
    case configSectionAppearance = "config.section.appearance"
    case configSectionMessages = "config.section.messages"
    case configSubtitleAppearance = "config.subtitle.appearance"
    case configSubtitleMessages = "config.subtitle.messages"
    case configPagePicker = "config.page_picker"
    case configAttentionPreset = "config.attention_preset"
    case configAttentionPresetCustomDetail = "config.attention_preset.custom_detail"
    case configAdvancedAppearance = "config.advanced.appearance"
    case configAdvancedAppearanceDetail = "config.advanced.appearance.detail"
    case configAdvancedMessages = "config.advanced.messages"
    case configAdvancedMessagesDetail = "config.advanced.messages.detail"
    case configShowPet = "config.show_pet"
    case configShowPetDetail = "config.show_pet.detail"
    case configDisplayAppearance = "config.display_appearance"
    case configStatusBubble = "config.status_bubble"
    case configStatusBubbleDetail = "config.status_bubble.detail"
    case configAutoHide = "config.auto_hide"
    case configAutoHideDetail = "config.auto_hide.detail"
    case configContextMenu = "config.context_menu"
    case configContextMenuDetail = "config.context_menu.detail"
    case configDisplaySize = "config.display_size"
    case configSizeGuidance = "config.size_guidance"
    case configDisplayWidthValueFormat = "config.display_width.value_format"
    case configDisplayWidthAccessibility = "config.display_width.accessibility"
    case configDisplayWidthReset = "config.display_width.reset"
    case configDisplayClarityLimitFormat = "config.display_clarity.limit_format"
    case configDisplayClarityWarningFormat = "config.display_clarity.warning_format"
    case configPetInteraction = "config.pet_interaction"
    case configSizeFooter = "config.size_footer"
    case configLivePreview = "config.live_preview"
    case configResponseSources = "config.response_sources"
    case configSourcesFooter = "config.sources_footer"
    case configResponseEvents = "config.response_events"
    case configPersistenceNote = "config.persistence_note"
    case configSessionDisplay = "config.session_display"
    case configMessagePreview = "config.message_preview"
    case configLanguagePicker = "config.language_picker"
    case configLanguageAccessibility = "config.language_accessibility"
    case configLanguageDetail = "config.language_detail"
    case configThemePicker = "config.theme_picker"
    case configThemeAccessibility = "config.theme_accessibility"
    case configThemeDetail = "config.theme_detail"
    case configBubbleFontScale = "config.bubble_font_scale"
    case configBubbleFontScaleDetail = "config.bubble_font_scale.detail"
    case configTimeout = "config.timeout"
    case configTimeoutDetail = "config.timeout_detail"
    case configGroupSessionsByAgent = "config.group_sessions_by_agent"
    case configGroupSessionsByAgentDetail = "config.group_sessions_by_agent.detail"
    case configGroupDisplay = "config.group_display"
    case configGroupDisplayDetail = "config.group_display.detail"
    case configSubnavigationAccessibility = "config.subnavigation.accessibility"
    case configSourcePending = "config.source.pending"
    case configSourceFullCheck = "config.source.full_check"
    case configSourcePartiallyUnverified = "config.source.partially_unverified"
    case configSourceLimited = "config.source.limited"
    case configSourceHealthy = "config.source.healthy"
    case configSourceMissing = "config.source.missing"
    case configSourceNeedsRepair = "config.source.needs_repair"
    case configPetHidden = "config.preview.pet_hidden"
    case configDesktopPreviewAccessibility = "config.preview.desktop_accessibility"
    case configBubbleAutoShow = "config.preview.bubble_auto_show"
    case configBubbleWorking = "config.preview.bubble_working"
    case configNoPetPreview = "config.preview.no_pet"
    case configCurrentPetFormat = "config.current_pet.format"
    case configLiveMessagePreview = "config.preview.live_messages"
    case configPreviewSources = "config.preview.sources"
    case configPreviewEvents = "config.preview.events"
    case configNoSources = "config.preview.no_sources"
    case configNoSourcesDetail = "config.preview.no_sources_detail"
    case configNoEvents = "config.preview.no_events"
    case configNoEventsDetail = "config.preview.no_events_detail"
    case configTimeoutPreviewFormat = "config.preview.timeout_format"
    case configPersistencePreview = "config.preview.persistence"
    case configEventStartDetail = "config.event.start_detail"
    case configEventThinkingDetail = "config.event.thinking_detail"
    case configEventPlanDetail = "config.event.plan_detail"
    case configEventToolDetail = "config.event.tool_detail"
    case configEventWaitingDetail = "config.event.waiting_detail"
    case configEventDoneDetail = "config.event.done_detail"
    case configEventFailedDetail = "config.event.failed_detail"
    case configEventReactionMapping = "config.event.reaction_mapping"
    case connectionsPaneDetail = "connections.pane.detail"
    case connectionsPaneEnvironment = "connections.pane.environment"
    case connectionsHealthPending = "connections.health.pending"
    case connectionsHealthAttentionFormat = "connections.health.attention_format"
    case connectionsHealthActionRequired = "connections.health.action_required"
    case connectionsHealthLight = "connections.health.light"
    case connectionsHealthUnverified = "connections.health.unverified"
    case connectionsHealthLimited = "connections.health.limited"
    case connectionsHealthHealthy = "connections.health.healthy"
    case connectionsItemLocated = "connections.item.located"
    case connectionsMetadataFormat = "connections.metadata.format"
    case connectionsConfirmRepairAll = "connections.confirm.repair_all"
    case connectionsRepairCountFormat = "connections.confirm.repair_count_format"
    case connectionsConfirmUninstallAll = "connections.confirm.uninstall_all"
    case connectionsUninstallCountFormat = "connections.confirm.uninstall_count_format"
    case connectionsNoRepairAll = "connections.confirm.no_repair_all"
    case connectionsNoUninstallAll = "connections.confirm.no_uninstall_all"
    case connectionsManagedChangeFormat = "connections.confirm.managed_change_format"
    case connectionsActionInstallUpdate = "connections.action.install_update"
    case connectionsActionRemove = "connections.action.remove"
    case connectionsMoreLocationsFormat = "connections.confirm.more_locations_format"
    case connectionsSafetySummary = "connections.confirm.safety_summary"
    case connectionsListTitle = "connections.list.title"
    case connectionsListAccessibility = "connections.list.accessibility"
    case connectionsSourcePicker = "connections.source_picker"
    case connectionsPagePicker = "connections.page_picker"
    case connectionsConfirmRepairFormat = "connections.confirm.repair_format"
    case connectionsWriteRepair = "connections.action.write_repair"
    case connectionsConfirmUninstallFormat = "connections.confirm.uninstall_format"
    case connectionsUninstall = "connections.action.uninstall"
    case connectionsPageTitle = "connections.page.title"
    case connectionsPageSubtitle = "connections.page.subtitle"
    case connectionsSummaryChecking = "connections.summary.checking"
    case connectionsSummaryLight = "connections.summary.light"
    case connectionsSummaryNotChecked = "connections.summary.not_checked"
    case connectionsSummaryConnected = "connections.summary.connected"
    case connectionsSummaryNeedsRepair = "connections.summary.needs_repair"
    case connectionsSummaryUnavailable = "connections.summary.unavailable"
    case connectionsStatusAgentMissing = "connections.status.agent_missing"
    case connectionsStatusUpdateRequired = "connections.status.update_required"
    case connectionsStatusHookAuthorization = "connections.status.hook_authorization"
    case connectionsStatusPermissionRequired = "connections.status.permission_required"
    case connectionsStatusRestartRequired = "connections.status.restart_required"
    case connectionsStatusLocalIssue = "connections.status.local_issue"
    case connectionsStatusActionRequired = "connections.status.action_required"
    case connectionsSummaryAgentMissingFormat = "connections.summary.agent_missing_format"
    case connectionsSummaryUpdateRequiredFormat = "connections.summary.update_required_format"
    case connectionsSummaryHookAuthorization = "connections.summary.hook_authorization"
    case connectionsSummaryPermissionRequiredFormat = "connections.summary.permission_required_format"
    case connectionsSummaryRestartRequiredFormat = "connections.summary.restart_required_format"
    case connectionsSummaryLocalIssue = "connections.summary.local_issue"
    case connectionsSummaryActionRequired = "connections.summary.action_required"
    case connectionsGuidanceInstallFormat = "connections.guidance.install_format"
    case connectionsGuidanceUpdateFormat = "connections.guidance.update_format"
    case connectionsGuidanceSettings = "connections.guidance.settings"
    case connectionsGuidanceRestartFormat = "connections.guidance.restart_format"
    case connectionsGuidanceFullRestartFormat = "connections.guidance.full_restart_format"
    case connectionsGuidanceHookAuthorization = "connections.guidance.hook_authorization"
    case connectionsGuidanceLocalService = "connections.guidance.local_service"
    case connectionsGuidanceActionRequired = "connections.guidance.action_required"
    case connectionsGuidanceRepair = "connections.guidance.repair"
    case connectionsGuidanceService = "connections.guidance.service"
    case connectionsPrimaryAccessibilityFormat = "connections.primary.accessibility_format"
    case connectionsPrimaryConnectHint = "connections.primary.connect_hint"
    case connectionsPrimaryRepairHint = "connections.primary.repair_hint"
    case connectionsPrimaryVerifyHint = "connections.primary.verify_hint"
    case connectionsPrimaryAttentionVerifyHint = "connections.primary.attention_verify_hint"
    case connectionsPrimaryRetryHint = "connections.primary.retry_hint"
    case connectionsTroubleshoot = "connections.action.troubleshoot"
    case connectionsTroubleshootHint = "connections.hint.troubleshoot"
    case connectionsTechnicalTitle = "connections.technical.title"
    case connectionsTechnicalSummary = "connections.technical.summary"
    case connectionsValidationBoundary = "connections.validation.boundary"
    case connectionsLocalChannelTitle = "connections.local_channel.title"
    case connectionsLocalChannelDetail = "connections.local_channel.detail"
    case connectionsManagedArtifactsTitle = "connections.managed_artifacts.title"
    case connectionsManagedArtifactsCountFormat = "connections.managed_artifacts.count_format"
    case connectionsManagedComponentsTitle = "connections.managed_components.title"
    case connectionsManagedComponentsSummary = "connections.managed_components.summary"
    case connectionsComponentKindConnector = "connections.component.kind.connector"
    case connectionsComponentKindPlugin = "connections.component.kind.plugin"
    case connectionsComponentKindExtension = "connections.component.kind.extension"
    case connectionsComponentKindPackage = "connections.component.kind.package"
    case connectionsComponentKindSkill = "connections.component.kind.skill"
    case connectionsComponentKindHook = "connections.component.kind.hook"
    case connectionsComponentKindUnknown = "connections.component.kind.unknown"
    case connectionsComponentVersionMismatch = "connections.component.version_mismatch"
    case connectionsComponentVersionMismatchDetailFormat = "connections.component.version_mismatch_detail_format"
    case connectionsComponentRequiredVersionFormat = "connections.component.required_version_format"
    case connectionsManagedActionsTitle = "connections.managed_actions.title"
    case connectionsManagedActionsDetail = "connections.managed_actions.detail"
    case connectionsCheckAll = "connections.action.check_all"
    case connectionsBusyHint = "connections.hint.busy"
    case connectionsCheckAllHint = "connections.hint.check_all"
    case connectionsRepairAll = "connections.action.repair_all"
    case connectionsUninstallAll = "connections.action.uninstall_all"
    case connectionsBulkActions = "connections.action.bulk"
    case connectionsNoSnapshot = "connections.snapshot.none"
    case connectionsOperationInProgress = "connections.operation.in_progress"
    case connectionsOperationSerial = "connections.operation.serial"
    case connectionsOperationFailed = "connections.operation.failed"
    case connectionsOperationDismiss = "connections.operation.dismiss"
    case connectionsOperationCheck = "connections.operation.check"
    case connectionsOperationTest = "connections.operation.test"
    case connectionsOperationRepair = "connections.operation.repair"
    case connectionsOperationUninstall = "connections.operation.uninstall"
    case connectionsOperationTitleFormat = "connections.operation.title_format"
    case connectionsSuccessCheck = "connections.success.check"
    case connectionsSuccessTest = "connections.success.test"
    case connectionsSuccessRepair = "connections.success.repair"
    case connectionsSuccessUninstall = "connections.success.uninstall"
    case connectionsFailureTransport = "connections.failure.transport"
    case connectionsFailureRejected = "connections.failure.rejected"
    case connectionsFailurePartial = "connections.failure.partial"
    case connectionsFailureInvalidResponse = "connections.failure.invalid_response"
    case connectionsFailureInvalidRequest = "connections.failure.invalid_request"
    case connectionsFailureUnknown = "connections.failure.unknown"
    case connectionsChecksTitle = "connections.checks.title"
    case connectionsChecksEmpty = "connections.checks.empty"
    case connectionsManagedTitle = "connections.managed.title"
    case connectionsManagedDetail = "connections.managed.detail"
    case connectionsRepair = "connections.action.repair"
    case connectionsInstallRepair = "connections.action.install_repair"
    case connectionsSetUpAgain = "connections.action.setup_again"
    case connectionsRepairAccessibilityFormat = "connections.action.repair_accessibility_format"
    case connectionsUninstallAccessibilityFormat = "connections.action.uninstall_accessibility_format"
    case connectionsUninstallHint = "connections.hint.uninstall"
    case connectionsSnapshotDescriptionFormat = "connections.snapshot.description_format"
    case connectionsCheckSourceFormat = "connections.action.check_source_format"
    case connectionsRepairUnavailable = "connections.confirm.repair_unavailable"
    case connectionsRepairFilesIntro = "connections.confirm.repair_files_intro"
    case connectionsRepairSafety = "connections.confirm.repair_safety"
    case connectionsUninstallUnavailable = "connections.confirm.uninstall_unavailable"
    case connectionsUninstallFilesIntro = "connections.confirm.uninstall_files_intro"
    case connectionsPathsUnreported = "connections.confirm.paths_unreported"
    case connectionsRepairHintPreview = "connections.hint.repair_preview"
    case connectionsRepairHintNone = "connections.hint.repair_none"
    case connectionsRepairHintManual = "connections.hint.repair_manual"
    case connectionsRepairAgainHint = "connections.hint.repair_again"
    case connectionsRecheck = "connections.action.recheck"
    case connectionsRecheckHint = "connections.hint.recheck"
    case connectionsTestChannel = "connections.action.test_channel"
    case connectionsTestHint = "connections.hint.test"
    case connectionsTestDetailFormat = "connections.test.detail_format"
    case connectionsCheckAccessibilityFormat = "connections.check.accessibility_format"
    case connectionsCheckNameAgentCLI = "connections.check.name.agent_cli"
    case connectionsCheckNameEventCLI = "connections.check.name.event_cli"
    case connectionsCheckNameAgentVersion = "connections.check.name.agent_version"
    case connectionsCheckNameManagedConnector = "connections.check.name.managed_connector"
    case connectionsCheckNameClaudeHooksPolicy = "connections.check.name.claude_hooks_policy"
    case connectionsCheckNameHostRuntime = "connections.check.name.host_runtime"
    case connectionsCheckNameHostVerification = "connections.check.name.host_verification"
    case connectionsCheckNameEventDelivery = "connections.check.name.event_delivery"
    case connectionsCheckNameChannelTest = "connections.check.name.channel_test"
    case connectionsCheckNameAppServer = "connections.check.name.app_server"
    case connectionsCheckNameHostServer = "connections.check.name.host_server"
    case connectionsCheckNameGeneric = "connections.check.name.generic"
    case connectionsCheckDescriptionAgentCLI = "connections.check.description.agent_cli"
    case connectionsCheckDescriptionEventCLI = "connections.check.description.event_cli"
    case connectionsCheckDescriptionAgentVersion = "connections.check.description.agent_version"
    case connectionsCheckDescriptionManagedConnector = "connections.check.description.managed_connector"
    case connectionsCheckDescriptionClaudeHooksPolicy = "connections.check.description.claude_hooks_policy"
    case connectionsCheckDescriptionHostRuntime = "connections.check.description.host_runtime"
    case connectionsCheckDescriptionHostVerification = "connections.check.description.host_verification"
    case connectionsCheckDescriptionEventDelivery = "connections.check.description.event_delivery"
    case connectionsCheckDescriptionChannelTest = "connections.check.description.channel_test"
    case connectionsCheckDescriptionAppServer = "connections.check.description.app_server"
    case connectionsCheckDescriptionHostServer = "connections.check.description.host_server"
    case connectionsCheckDescriptionGeneric = "connections.check.description.generic"
    case connectionsCheckDetailFormat = "connections.check.detail_format"
    case connectionsEvidenceVersionSupportedFormat =
        "connections.check.evidence.version_supported_format"
    case connectionsEvidenceVersionUpdateFormat =
        "connections.check.evidence.version_update_format"
    case connectionsEvidenceVersionUnverifiedFormat =
        "connections.check.evidence.version_unverified_format"
    case connectionsEvidenceVersionMissingFormat =
        "connections.check.evidence.version_missing_format"
    case connectionsEvidenceCodexTrustFormat =
        "connections.check.evidence.codex_trust_format"
    case connectionsVersionSupportCodex =
        "connections.check.version_support.codex"
    case connectionsVersionSupportClaude =
        "connections.check.version_support.claude"
    case connectionsVersionSupportPi =
        "connections.check.version_support.pi"
    case connectionsVersionSupportOpencode =
        "connections.check.version_support.opencode"
    case connectionsVerificationTitle = "connections.verification.title"
    case connectionsVerificationNotRunTitle = "connections.verification.not_run_title"
    case connectionsVerificationNotRunDetail = "connections.verification.not_run_detail"
    case connectionsVerificationVerifiedTitle = "connections.verification.verified_title"
    case connectionsVerificationActionTitle = "connections.verification.action_title"
    case connectionsVerificationPendingTitle = "connections.verification.pending_title"
    case connectionsVerificationNotRequiredTitle = "connections.verification.not_required_title"
    case connectionsVerificationVerifiedDetail = "connections.verification.verified_detail"
    case connectionsVerificationActionDetail = "connections.verification.action_detail"
    case connectionsVerificationPendingDetail = "connections.verification.pending_detail"
    case connectionsVerificationNotRequiredDetail = "connections.verification.not_required_detail"
    case connectionsVerificationInstructionFormat = "connections.verification.instruction_format"
    case connectionsMetadataCWD = "connections.metadata.cwd"
    case connectionsMetadataLastReceipt = "connections.metadata.last_receipt"
    case connectionsMetadataVerifiedAt = "connections.metadata.verified_at"
    case connectionsCapabilitiesTitle = "connections.capabilities.title"
    case connectionsCapabilitiesAudited = "connections.capabilities.audited"
    case connectionsCapabilitiesSubscribed = "connections.capabilities.subscribed"
    case connectionsCapabilitiesMapped = "connections.capabilities.mapped"
    case connectionsCapabilitiesPrivacy = "connections.capabilities.privacy"
    case connectionsCapabilitiesUnavailable = "connections.capabilities.unavailable"
    case connectionsCapabilitiesAccessibilityFormat = "connections.capabilities.accessibility_format"
    case connectionsCapabilitiesUnreported = "connections.capabilities.unreported"
    case connectionsCapabilitiesVersionUnreported = "connections.capabilities.version_unreported"
    case connectionsCapabilitiesSummaryFormat = "connections.capabilities.summary_format"
    case connectionsCapabilitiesListFormat = "connections.capabilities.list_format"
    case connectionsEnvironmentTitle = "connections.environment.title"
    case connectionsInstanceID = "connections.environment.instance_id"
    case connectionsRuntimeIdentity = "connections.environment.runtime_identity"
    case connectionsRuntimeFooter = "connections.environment.runtime_footer"
    case connectionsInstallLocationsEmpty = "connections.environment.install_locations_empty"
    case connectionsInstallLocationsFormat = "connections.environment.install_locations_format"
    case connectionsInstallLocationTitle = "connections.environment.install_location_title"
    case connectionsPrivacyDetail = "connections.environment.privacy_detail"
    case connectionsPrivacyTitle = "connections.environment.privacy_title"
    case connectionsExporting = "connections.environment.exporting"
    case connectionsExportDiagnostics = "connections.environment.export_diagnostics"
    case connectionsExportHint = "connections.environment.export_hint"
    case connectionsPrivacySupport = "connections.environment.privacy_support"
    case connectionsInspectorValueFormat = "connections.environment.value_format"
    case diagnosticsExportingMessage = "diagnostics.export.exporting_message"
    case diagnosticsExportSucceededMessage = "diagnostics.export.succeeded_message"
    case diagnosticsExportFailedMessage = "diagnostics.export.failed_message"
    case serviceToolbarChecking = "service.toolbar.checking"
    case serviceToolbarRecovering = "service.toolbar.recovering"
    case serviceToolbarHealthy = "service.toolbar.healthy"
    case serviceToolbarOffline = "service.toolbar.offline"
    case serviceToolbarRuntimeMismatch = "service.toolbar.runtime_mismatch"
    case serviceToolbarFailure = "service.toolbar.failure"
    case serviceStatusChecking = "service.status.checking"
    case serviceStatusRecovering = "service.status.recovering"
    case serviceStatusHealthy = "service.status.healthy"
    case serviceStatusOffline = "service.status.offline"
    case serviceStatusRuntimeMismatch = "service.status.runtime_mismatch"
    case serviceStatusFailure = "service.status.failure"
    case serviceStatusUnavailable = "service.status.unavailable"
    case serviceStatusOnline = "service.status.online"
    case serviceStatusDisabled = "service.status.disabled"
    case serviceStatusHidden = "service.status.hidden"
    case serviceRowLocalRPC = "service.row.local_rpc"
    case serviceRowEventChannel = "service.row.event_channel"
    case serviceRowDesktopPet = "service.row.desktop_pet"
    case servicePetCoreCheckingDetail = "service.petcore.checking_detail"
    case servicePetCoreRecoveringDetail = "service.petcore.recovering_detail"
    case servicePetCoreRunning = "service.petcore.running"
    case servicePetCoreRunningVersionFormat = "service.petcore.running_version_format"
    case servicePetCoreOfflineDetail = "service.petcore.offline_detail"
    case servicePetCoreRuntimeMismatchDetail = "service.petcore.runtime_mismatch_detail"
    case servicePetCoreFailedDetail = "service.petcore.failed_detail"
    case serviceRPCCheckingDetail = "service.rpc.checking_detail"
    case serviceRPCRecoveringDetail = "service.rpc.recovering_detail"
    case serviceRPCProtocolUnknown = "service.rpc.protocol_unknown"
    case serviceRPCSchemaUnreported = "service.rpc.schema_unreported"
    case serviceRPCUnavailable = "service.rpc.unavailable"
    case serviceRPCOfflineDetail = "service.rpc.offline_detail"
    case serviceRPCRuntimeMismatchDetail = "service.rpc.runtime_mismatch_detail"
    case serviceEventCheckingDetail = "service.event.checking_detail"
    case serviceEventRecoveringDetail = "service.event.recovering_detail"
    case serviceEventRecentFormat = "service.event.recent_format"
    case serviceEventWaiting = "service.event.waiting"
    case serviceEventOfflineDetail = "service.event.offline_detail"
    case serviceEventRuntimeMismatchDetail = "service.event.runtime_mismatch_detail"
    case serviceDesktopDisabled = "service.desktop.disabled"
    case serviceDesktopHidden = "service.desktop.hidden"
    case serviceDesktopRunningFormat = "service.desktop.running_format"
    case diagnosticsPageTitle = "diagnostics.page.title"
    case diagnosticsRefresh = "diagnostics.action.refresh"
    case diagnosticsRefreshing = "diagnostics.action.refreshing"
    case diagnosticsRecover = "diagnostics.action.recover"
    case diagnosticsRecovering = "diagnostics.action.recovering"
    case diagnosticsServiceStatus = "diagnostics.section.service_status"
    case diagnosticsSummaryHealthy = "diagnostics.summary.healthy"
    case diagnosticsSummaryChecking = "diagnostics.summary.checking"
    case diagnosticsSummaryRecovering = "diagnostics.summary.recovering"
    case diagnosticsSummaryOffline = "diagnostics.summary.offline"
    case diagnosticsSummaryRuntimeMismatch = "diagnostics.summary.runtime_mismatch"
    case diagnosticsSummaryFailure = "diagnostics.summary.failure"
    case diagnosticsTechnicalTitle = "diagnostics.technical.title"
    case diagnosticsTechnicalSummary = "diagnostics.technical.summary"
    case diagnosticsLogDownload = "diagnostics.section.log_download"
    case diagnosticsPackageTitle = "diagnostics.package.title"
    case diagnosticsPackageDetail = "diagnostics.package.detail"
    case diagnosticsMetadataScope = "diagnostics.metadata.scope"
    case diagnosticsMetadataBounded14Days = "diagnostics.metadata.bounded_14_days"
    case diagnosticsMetadataPrivacy = "diagnostics.metadata.privacy"
    case diagnosticsMetadataRedacted = "diagnostics.metadata.redacted"
    case diagnosticsMetadataFormat = "diagnostics.metadata.format"
    case diagnosticsExporting = "diagnostics.action.exporting"
    case diagnosticsExport = "diagnostics.action.export"
    case diagnosticsPrivacy = "diagnostics.privacy"
    case diagnosticsRowAccessibilityFormat = "diagnostics.row.accessibility_format"
    case overlaySessionTitleFormat = "overlay.session.title_format"
    case overlaySessionAliasTitleFormat = "overlay.session.alias_title_format"
    case overlayMoreSessionsTitle = "overlay.sessions.more_title"
    case overlayMoreSessionsDetailFormat = "overlay.sessions.more_detail_format"
    case overlayMoreSessionsControlCenterFormat =
        "overlay.sessions.more_control_center_format"
    case overlayHelpOpenAndDismiss = "overlay.help.open_and_dismiss"
    case overlayHelpDismiss = "overlay.help.dismiss"
    case overlayHelpOpen = "overlay.help.open"
    case overlayHelpUnavailable = "overlay.help.unavailable"
    case overlaySessionNavigationUnavailable =
        "overlay.session.navigation_unavailable"
    case overlaySessionNavigationFailed = "overlay.session.navigation_failed"
    case overlaySessionNavigationDegraded =
        "overlay.session.navigation_degraded"
    case overlayCollapseSessionsFormat = "overlay.sessions.collapse_format"
    case overlayExpandSessionsFormat = "overlay.sessions.expand_format"
    case overlayCloseBubbleAccessibility = "overlay.bubble.close_accessibility"
    case overlayCloseBubbleHint = "overlay.bubble.close_hint"
    case overlayDismissSession = "overlay.session.dismiss"
    case overlayPetAccessibility = "overlay.pet.accessibility"
    case overlayPetAccessibilityHelp = "overlay.pet.accessibility_help"
    case overlayOpenQuickMenu = "overlay.pet.open_quick_menu"
    case overlayCollapseBubble = "overlay.bubble.collapse"
    case overlayExpandBubble = "overlay.bubble.expand"
    case overlayNoPet = "overlay.pet.no_pet"
    case overlayBubbleCountFormat = "overlay.bubble.count_format"
    case overlaySessionAccessibilityFormat = "overlay.session.accessibility_format"
    case libraryPageSubtitle = "library.page.subtitle"
    case librarySearchPlaceholder = "library.search.placeholder"
    case libraryMakeAction = "library.make.action"
    case libraryAllCountFormat = "library.all_count.format"
    case libraryFilteredCountFormat = "library.filtered_count.format"
    case libraryDeleteCurrentTitle = "library.delete.current_title"
    case libraryDeleteTitle = "library.delete.title"
    case libraryDeleteActionFormat = "library.delete.action_format"
    case libraryDeleteMessageFormat = "library.delete.message_format"
    case libraryNoticeDismiss = "library.notice.dismiss"
    case libraryNoticeRetryImport = "library.notice.retry_import"
    case libraryEditTitleFormat = "library.edit.title_format"
    case libraryEditDetail = "library.edit.detail"
    case libraryEditBaseline = "library.edit.baseline"
    case libraryFieldStableID = "library.field.stable_id"
    case libraryFieldRevisionID = "library.field.revision_id"
    case libraryFieldImmutableRevisions = "library.field.immutable_revisions"
    case libraryFieldRevisionPolicy = "library.field.revision_policy"
    case libraryFieldStates = "library.field.states"
    case libraryFieldTiming = "library.field.timing"
    case libraryFieldDuration = "library.field.duration"
    case libraryFieldFrameCounts = "library.field.frame_counts"
    case libraryFieldRenderSize = "library.field.render_size"
    case libraryFieldProvenance = "library.field.provenance"
    case libraryFieldValidation = "library.field.validation"
    case libraryEditInstruction = "library.edit.instruction"
    case libraryEditInstructionAccessibility = "library.edit.instruction_accessibility"
    case libraryEditActiveWarning = "library.edit.active_warning"
    case libraryEditStart = "library.edit.start"
    // Arguments: display name, localized style title, localized source title.
    case libraryCardAccessibilityFormat = "library.card.accessibility_format"
    case libraryCardVariantFormat = "library.card.variant_format"
    case libraryActivateAccessibility = "library.activate.accessibility"
    case libraryInspectorTitle = "library.inspector.title"
    case libraryPetActive = "library.pet.active"
    case libraryPetEnabling = "library.pet.enabling"
    case libraryEnablePet = "library.pet.enable"
    case libraryCurrentInfo = "library.current_info"
    case libraryTechnicalInformationSummary = "library.technical_information.summary"
    case libraryFieldCurrentState = "library.field.current_state"
    case libraryFieldSource = "library.field.source"
    case libraryFieldPackageVersion = "library.field.package_version"
    case libraryFieldQuality = "library.field.quality"
    case libraryValidationDetailAccessibilityFormat = "library.validation_detail.accessibility_format"
    case libraryBundledNote = "library.bundled.note"
    case libraryObjectActions = "library.object_actions"
    case libraryCustomizeCopy = "library.action.customize_copy"
    case libraryModifyAction = "library.action.modify"
    case libraryHistoryAction = "library.action.history"
    case libraryExportAction = "library.action.export"
    case libraryDeleteAction = "library.action.delete"
    case libraryMissingPreview = "library.missing_preview"
    case libraryAnimationActionPicker = "library.animation.action_picker"
    case libraryAnimationAgentGroup = "library.animation.agent_group"
    case libraryAnimationInteractionGroup = "library.animation.interaction_group"
    case libraryAnimationIdleShort = "library.animation.short.idle"
    case libraryAnimationThinkingShort = "library.animation.short.thinking"
    case libraryAnimationToolShort = "library.animation.short.tool"
    case libraryAnimationWaitingShort = "library.animation.short.waiting"
    case libraryAnimationDoneShort = "library.animation.short.done"
    case libraryAnimationFailedShort = "library.animation.short.failed"
    // Arguments: pet display name, localized action title.
    case libraryAnimationAccessibilityFormat = "library.animation.accessibility_format"
    case libraryCopyBriefSourceFormat = "library.copy.brief_source_format"
    case libraryCopyBriefIDFormat = "library.copy.brief_id_format"
    case libraryCopyBriefContract = "library.copy.brief_contract"
    case libraryCopyBundledOnly = "library.copy.bundled_only"
    case libraryCopyActiveTask = "library.copy.active_task"
    case libraryCopyPreparedFormat = "library.copy.prepared_format"
    case libraryImportPartialTitle = "library.import.partial_title"
    case libraryImportFailureTitle = "library.import.failure_title"
    case libraryImportPartialCountFormat = "library.import.partial_count_format"
    case libraryImportNone = "library.import.none"
    case libraryImportValidPetpack = "library.import.valid_petpack"
    case libraryImportFailedFileFormat = "library.import.failed_file_format"
    case libraryImportServiceFailedFileFormat = "library.import.service_failed_file_format"
    case libraryHistoryCheckingTitle = "library.history.checking_title"
    case libraryHistoryAvailableTitle = "library.history.available_title"
    case libraryHistoryUnavailableTitle = "library.history.unavailable_title"
    case libraryHistoryFailedTitle = "library.history.failed_title"
    case libraryHistoryCheckingDetail = "library.history.checking_detail"
    case libraryHistoryAvailableDetailFormat = "library.history.available_detail_format"
    case libraryHistoryUnavailableDetail = "library.history.unavailable_detail"
    case libraryHistoryFailedDetail = "library.history.failed_detail"
    case libraryHistoryOperationCreate = "library.history.operation_create"
    case libraryHistoryOperationModify = "library.history.operation_modify"
    case libraryHistoryOperationUnknown = "library.history.operation_unknown"
    case libraryHistoryStatusPending = "library.history.status_pending"
    case libraryHistoryStatusRunning = "library.history.status_running"
    case libraryHistoryStatusWaiting = "library.history.status_waiting"
    case libraryHistoryStatusCompleted = "library.history.status_completed"
    case libraryHistoryStatusFailed = "library.history.status_failed"
    case libraryHistoryStatusCancelled = "library.history.status_cancelled"
    case libraryHistoryStatusUnknown = "library.history.status_unknown"
    case libraryHistorySummaryFormat = "library.history.summary_format"
    case libraryHistorySheetTitleFormat = "library.history.sheet_title_format"
    case libraryHistoryReadOnlyDetail = "library.history.read_only_detail"
    case libraryHistoryRevisionsTitle = "library.history.revisions_title"
    case libraryHistoryJobsTitle = "library.history.jobs_title"
    case libraryHistoryCurrentRevision = "library.history.current_revision"
    case libraryHistoryOlderRevision = "library.history.older_revision"
    case libraryHistoryValidated = "library.history.validated"
    case libraryHistoryNotSelectable = "library.history.not_selectable"
    case libraryHistoryNoOwnedRevisions = "library.history.no_owned_revisions"
    case libraryHistoryNoRecords = "library.history.no_records"
    case libraryHistoryRecordCountFormat = "library.history.record_count_format"
    case libraryHistoryTruncated = "library.history.truncated"
    case libraryHistoryClose = "library.history.close"
    case libraryHistoryUseBaseline = "library.history.use_baseline"
    case libraryHistoryConfirmBaseline = "library.history.confirm_baseline"
    case libraryHistoryImmutableNotice = "library.history.immutable_notice"
    case libraryRevisionUnavailable = "library.revision.unavailable"
    case libraryRevisionZeroExternal = "library.revision.zero_external"
    case libraryRevisionCountIncomplete = "library.revision.count_incomplete"
    case libraryRevisionCountFormat = "library.revision.count_format"
    case libraryRevisionBundledPolicy = "library.revision.bundled_policy"
    case libraryRevisionNewPolicy = "library.revision.new_policy"
    case libraryAuthoredTimingSummaryFormat = "library.authored_timing_summary.format"
    case libraryDurationStateFormat = "library.duration.state_format"
    case libraryFrameCountStateFormat = "library.frame_count.state_format"
    case librarySourceBundledTitle = "library.source.bundled_title"
    case librarySourceAllTitle = "library.source.all_title"
    case librarySourceFilterLabel = "library.source.filter_label"
    case librarySourceBundledDetail = "library.source.bundled_detail"
    case librarySourceVerifiedTitle = "library.source.verified_title"
    case librarySourceGeneratedTitle = "library.source.generated_title"
    case librarySourcePreviewTitle = "library.source.preview_title"
    case librarySourceExternalTitle = "library.source.external_title"
    case librarySourceVerifiedDetail = "library.source.verified_detail"
    case librarySourceVerifiedClaimedFormat = "library.source.verified_claimed_format"
    case librarySourcePreviewDetail = "library.source.preview_detail"
    case librarySourcePreviewClaimedFormat = "library.source.preview_claimed_format"
    case librarySourceBriefDetail = "library.source.brief_detail"
    case librarySourceBriefClaimedFormat = "library.source.brief_claimed_format"
    case librarySourceJobDetail = "library.source.job_detail"
    case librarySourceJobClaimedFormat = "library.source.job_claimed_format"
    case librarySourceExternalDetail = "library.source.external_detail"
    case librarySourceExternalClaimedFormat = "library.source.external_claimed_format"
    case appName = "app.name"
    case sidebarBrand = "sidebar.brand"
    case aboutCopyright = "about.copyright"
    case commonPercentFormat = "common.percent.format"
    case commonCharacterCountFormat = "common.character_count.format"
    case connectionsAgentLabel = "connections.agent_label"
    case technicalPetCore = "technical.petcore"
    case technicalRPC = "technical.rpc"
    case technicalSchema = "technical.schema"
    case technicalAppBuild = "technical.app_build"
    case technicalBuildID = "technical.build_id"
    case technicalZIP = "technical.zip"
    case aboutDevelopment = "about.development"
    case aboutLocalBuild = "about.local_build"
}

private final class APCLocalizationPreference: @unchecked Sendable {
    private let lock = NSLock()
    private var language: InterfaceLanguage = .system

    func read() -> InterfaceLanguage {
        lock.lock()
        defer { lock.unlock() }
        return language
    }

    func write(_ next: InterfaceLanguage) {
        lock.lock()
        language = next
        lock.unlock()
    }
}

/// Caches each `<locale>.lproj/Localizable.strings` table after its first read.
///
/// The tables are immutable bundle resources, so one parse per locale candidate
/// is authoritative for the process lifetime. Without this cache every single
/// `APCLocalization.text` call re-read a 64 KB property list, re-parsed ~900
/// entries, and bridged the whole `NSDictionary` to Swift just to look up one
/// key, which put a multi-millisecond disk-and-parse cost inside SwiftUI body
/// evaluation. A missing or unparsable file caches as "absent" so a broken
/// candidate does not retry the read on every lookup either.
private final class APCLocalizationStringsCache: @unchecked Sendable {
    static let shared = APCLocalizationStringsCache()

    private let lock = NSLock()
    private var tables: [String: [String: String]?] = [:]

    /// Returns the parsed table for `locale`, loading it once on first use.
    /// `nil` means the locale has no usable `Localizable.strings` resource.
    func table(for locale: String) -> [String: String]? {
        lock.lock()
        if let cached = tables[locale] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let loaded = Self.load(locale: locale)

        lock.lock()
        tables[locale] = loaded
        lock.unlock()
        return loaded
    }

    private static func load(locale: String) -> [String: String]? {
        let url = APCResourceBundle.resourceURL("\(locale).lproj/Localizable.strings")
        guard let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: String]
        else {
            return nil
        }
        return values
    }
}

enum APCLocalization {
    static let requiredV1Keys = APCLocalizationKey.allCases
    private static let preference = APCLocalizationPreference()

    static var interfaceLanguage: InterfaceLanguage {
        preference.read()
    }

    static var interfaceLocaleIdentifier: String {
        resolvedInterfaceLocaleIdentifier(
            interfaceLanguage: interfaceLanguage,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    static func applyInterfaceLanguage(_ language: InterfaceLanguage) {
        preference.write(language)
    }

    static func resolvedInterfaceLocaleIdentifier(
        interfaceLanguage: InterfaceLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        switch interfaceLanguage {
        case .system:
            resolvedInterfaceLocaleIdentifier(preferredLanguages: preferredLanguages)
        case .english:
            "en"
        case .simplifiedChinese:
            "zh-Hans"
        }
    }

    static func resolvedInterfaceLocaleIdentifier(
        preferredLanguages: [String]
    ) -> String {
        for identifier in preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if normalized == "zh"
                || normalized.hasPrefix("zh-hans")
                || normalized.hasPrefix("zh-cn")
                || normalized.hasPrefix("zh-sg") {
                return "zh-Hans"
            }
            if normalized == "en" || normalized.hasPrefix("en-") {
                return "en"
            }
        }
        return "en"
    }

    static func text(_ key: APCLocalizationKey) -> String {
        text(key, locale: interfaceLocaleIdentifier)
    }

    static func text(_ key: APCLocalizationKey, locale identifier: String) -> String {
        let locale = supportedLocaleIdentifier(for: identifier)
        return localizedValue(for: key, locale: locale)
            ?? catalogValue(for: key, locale: locale)
            ?? key.rawValue
    }

    static func format(_ key: APCLocalizationKey, _ arguments: CVarArg...) -> String {
        formatted(key, locale: interfaceLocaleIdentifier, arguments: arguments)
    }

    static func format(
        _ key: APCLocalizationKey,
        locale identifier: String,
        _ arguments: CVarArg...
    ) -> String {
        formatted(key, locale: identifier, arguments: arguments)
    }

    private static func formatted(
        _ key: APCLocalizationKey,
        locale identifier: String,
        arguments: [CVarArg]
    ) -> String {
        let locale = supportedLocaleIdentifier(for: identifier)
        return String(
            format: text(key, locale: locale),
            locale: Locale(identifier: locale),
            arguments: arguments
        )
    }

    static func localizedValue(
        for key: APCLocalizationKey,
        locale identifier: String
    ) -> String? {
        for locale in localeCandidates(for: identifier) {
            guard let values = APCLocalizationStringsCache.shared.table(for: locale),
                  let value = values[key.rawValue],
                  value != key.rawValue else {
                continue
            }
            return value
        }
        return nil
    }

    static func catalogValue(
        for key: APCLocalizationKey,
        locale identifier: String
    ) -> String? {
        let locale = supportedLocaleIdentifier(for: identifier)
        return catalog?.strings[key.rawValue]?.localizations[locale]?.stringUnit.value
    }

    private static func localeCandidates(for identifier: String) -> [String] {
        switch supportedLocaleIdentifier(for: identifier) {
        case "zh-Hans":
            ["zh-hans", "zh-Hans", "zh_CN", "zh"]
        case "en":
            ["en", "Base"]
        default:
            ["en", "Base"]
        }
    }

    private static func supportedLocaleIdentifier(for identifier: String) -> String {
        resolvedInterfaceLocaleIdentifier(preferredLanguages: [identifier])
    }

    private static let catalog: StringCatalog? = {
        let url = APCResourceBundle.resourceURL("Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? JSONDecoder().decode(StringCatalog.self, from: data)
    }()

    private struct StringCatalog: Decodable, Sendable {
        var strings: [String: Entry]

        struct Entry: Decodable, Sendable {
            var localizations: [String: Localization]
        }

        struct Localization: Decodable, Sendable {
            var stringUnit: StringUnit
        }

        struct StringUnit: Decodable, Sendable {
            var value: String
        }
    }
}

private struct APCInterfaceLanguageModifier: ViewModifier {
    @ObservedObject var store: AppStore

    func body(content: Content) -> some View {
        content
            .environment(
                \.locale,
                Locale(identifier: store.interfaceLocaleIdentifier)
            )
            .id(store.behavior.interfaceLanguage)
    }
}

extension View {
    func apcInterfaceLanguage(_ store: AppStore) -> some View {
        modifier(APCInterfaceLanguageModifier(store: store))
    }
}

enum UIControlSemantics {
    static func sourceLabel(_ source: AgentSource) -> String {
        APCLocalization.format(.controlSourceLabel, source.title)
    }

    static func eventLabel(_ event: AgentEventKind) -> String {
        APCLocalization.format(.controlEventLabel, APCLocalizedPresentation.eventTitle(event))
    }

    static func styleLabel(_ style: StylePreset) -> String {
        APCLocalization.format(.controlStyleLabel, APCLocalizedPresentation.styleTitle(style))
    }

    static func qualityLabel(_ quality: QualityLevel) -> String {
        APCLocalization.format(.controlQualityLabel, APCLocalizedPresentation.qualityTitle(quality))
    }

    static func toggleValue(isOn: Bool) -> String {
        APCLocalization.text(isOn ? .controlEnabled : .controlDisabled)
    }

    static func selectionValue(isSelected: Bool) -> String {
        APCLocalization.text(isSelected ? .controlSelected : .controlUnselected)
    }
}

enum APCLocalizedPresentation {
    static func animationActionTitle(
        _ action: PetAnimationAction,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        switch action {
        case .idle:
            lifecycleTitle(.idle, locale: locale)
        case .thinking:
            lifecycleTitle(.thinking, locale: locale)
        case .tool:
            lifecycleTitle(.tool, locale: locale)
        case .waiting:
            lifecycleTitle(.waiting, locale: locale)
        case .done:
            lifecycleTitle(.done, locale: locale)
        case .failed:
            lifecycleTitle(.failed, locale: locale)
        case .acknowledge:
            APCLocalization.text(.productInteractionAcknowledge, locale: locale)
        case .dragLeft:
            APCLocalization.text(.productInteractionDragLeft, locale: locale)
        case .dragRight:
            APCLocalization.text(.productInteractionDragRight, locale: locale)
        }
    }

    static func lifecycleTitle(
        _ state: ProductLifecycleState,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch state {
        case .idle: .productLifecycleIdle
        case .thinking: .productLifecycleThinking
        case .tool: .productLifecycleTool
        case .waiting: .productLifecycleWaiting
        case .done: .productLifecycleDone
        case .failed: .productLifecycleFailed
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func navigationActionTitle(
        _ capability: NavigationCapability,
        source: AgentSource,
        navigation: AgentSessionNavigation? = nil,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        switch capability {
        case .exactSession:
            APCLocalization.text(.productNavigationExactSession, locale: locale)
        case .agentHost:
            APCLocalization.format(
                .productNavigationAgentHostFormat,
                locale: locale,
                navigationHostTitle(source: source, navigation: navigation) ?? source.title
            )
        case .unavailable:
            nil
        }
    }

    static func sessionSurfaceTitle(
        _ kind: OverlaySessionSurfaceKind,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(
            kind == .app ? .productSessionSurfaceApp : .productSessionSurfaceCLI,
            locale: locale
        )
    }

    private static func navigationHostTitle(
        source: AgentSource,
        navigation: AgentSessionNavigation?
    ) -> String? {
        guard let navigation else { return nil }
        return switch (source, navigation.surface) {
        case (.codex, "chatgpt_app"):
            "ChatGPT"
        case (.claudeCode, "claude_app"):
            "Claude"
        case (.opencode, "opencode_app"):
            "OpenCode"
        case (_, "cli_terminal"):
            switch navigation.terminalApp {
            case "warp": "Warp"
            case "terminal": "Terminal"
            case "iterm2": "iTerm2"
            case "ghostty": "Ghostty"
            default: nil
            }
        default:
            nil
        }
    }

    static func navigationUnavailableTitle(
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(.productNavigationUnavailable, locale: locale)
    }

    static func attentionPresetTitle(
        _ preset: AttentionPreset,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch preset {
        case .onlyWhenNeeded: .productAttentionOnlyWhenNeeded
        case .standard: .productAttentionStandard
        case .allActivity: .productAttentionAllActivity
        case .custom: .productAttentionCustom
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func connectionHealthTitle(
        _ health: AgentConnectionHealthState,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch health {
        case .notChecked: .productConnectionNotChecked
        case .checking: .productConnectionChecking
        case .connected: .productConnectionConnected
        case .needsRepair: .productConnectionNeedsRepair
        case .unavailable: .productConnectionUnavailable
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func primaryActionTitle(
        _ action: PetLibraryPrimaryAction,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        let key: APCLocalizationKey? = switch action {
        case .usePet: .productActionUsePet
        case .createPet: .libraryEmptyAction
        case .importPet: .libraryImportAction
        case .unavailable: nil
        }
        return key.map { APCLocalization.text($0, locale: locale) }
    }

    static func primaryActionTitle(
        _ action: PetMakerPrimaryAction,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        let key: APCLocalizationKey? = switch action {
        case .createPet: .studioActionStart
        case .sendReply: .studioReplySend
        case .cancel: .studioActionCancelTask
        case .retry: .commonRetry
        case .reselectReferences: .studioReferencesPanelTitle
        case .usePet: .productActionUsePet
        case .continueEditing: .productActionContinueEditing
        case .unavailable: nil
        }
        return key.map { APCLocalization.text($0, locale: locale) }
    }

    static func primaryActionTitle(
        _ action: AgentConnectionPrimaryAction,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        let key: APCLocalizationKey? = switch action {
        case .connect: .productActionConnect
        case .repair: .connectionsInstallRepair
        case .verify: .productActionVerify
        case .retry: .commonRetry
        case .unavailable: nil
        }
        return key.map { APCLocalization.text($0, locale: locale) }
    }

    static func primaryActionTitle(
        _ action: ServiceDiagnosticsPrimaryAction,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String? {
        let key: APCLocalizationKey? = switch action {
        case .refresh: .diagnosticsRefresh
        case .recover: .diagnosticsRecover
        case .retry: .commonRetry
        case .unavailable: nil
        }
        return key.map { APCLocalization.text($0, locale: locale) }
    }

    static func eventTitle(
        _ event: AgentEventKind,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch event {
        case .start: .productEventStart
        case .thinking: .productEventThinking
        case .plan: .productEventPlan
        case .tool: .productEventTool
        case .waiting: .productEventWaiting
        case .done: .productEventDone
        case .failed: .productEventFailed
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func overlayEventTitle(
        _ event: AgentOverlaySummaryKind,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch event {
        case .start: .productEventStart
        case .thinking: .productEventThinking
        case .plan: .productEventPlan
        case .command: .overlayActivityCommand
        case .file: .overlayActivityFile
        case .fileChange: .overlayActivityFileChange
        case .tool: .productEventTool
        case .subagent: .overlayActivitySubagent
        case .search: .overlayActivitySearch
        case .network: .overlayActivityNetwork
        case .image: .overlayActivityImage
        case .compaction: .overlayActivityCompaction
        case .needsInput: .productEventWaiting
        case .done: .productEventDone
        case .failed: .productEventFailed
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func styleTitle(
        _ style: StylePreset,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch style {
        case .realistic: .styleRealistic
        case .semiRealistic: .styleSemiRealistic
        case .modern: .styleModern
        case .pixel: .stylePixel
        case .anime: .styleAnime
        case .unspecified: .styleUnspecified
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func qualityTitle(
        _ quality: QualityLevel,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch quality {
        case .low: .qualityLow
        case .standard: .qualityStandard
        case .high: .qualityHigh
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func qualityDetail(
        _ quality: QualityLevel,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let size = quality.renderSize
        let key: APCLocalizationKey = switch quality {
        case .low: .qualityLowDetailFormat
        case .standard: .qualityStandardDetailFormat
        case .high: .qualityHighDetailFormat
        }
        return APCLocalization.format(
            key,
            locale: locale,
            size.width,
            size.height
        )
    }

    static func appearanceTitle(
        _ theme: AppearanceTheme,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch theme {
        case .system: .appearanceSystem
        case .light: .appearanceLight
        case .dark: .appearanceDark
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func interfaceLanguageTitle(
        _ language: InterfaceLanguage,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch language {
        case .system: .interfaceLanguageSystem
        case .english: .interfaceLanguageEnglish
        case .simplifiedChinese: .interfaceLanguageSimplifiedChinese
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func sessionGroupTitle(
        _ display: SessionGroupDisplay,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(
            display == .stacked ? .sessionGroupStacked : .sessionGroupExpanded,
            locale: locale
        )
    }

    static func bubbleFontScaleTitle(
        _ scale: BubbleFontScale,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(
            scale == .standard ? .bubbleFontScaleStandard : .bubbleFontScaleLarge,
            locale: locale
        )
    }

    static func checkStatusTitle(
        _ status: CheckStatus,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch status {
        case .ok: .checkStatusOK
        case .needsFix: .checkStatusNeedsFix
        case .missing: .checkStatusMissing
        case .unverified: .checkStatusUnverified
        case .unsupported: .checkStatusUnsupported
        case .notRequired: .checkStatusNotRequired
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func connectionCheckModeTitle(
        _ mode: ConnectionCheckMode,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(
            mode == .light ? .connectionModeLight : .connectionModeRuntime,
            locale: locale
        )
    }

    static func verificationStatusTitle(
        _ status: AgentVerificationStatus,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch status {
        case .verified: .verificationStatusVerified
        case .actionRequired: .verificationStatusActionRequired
        case .unverified: .verificationStatusUnverified
        case .notRequired: .verificationStatusNotRequired
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func generationStateTitle(
        _ state: GenerationSessionState,
        operation: GenerationOperation,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = if operation == .modify {
            switch state {
            case .idle: .generationModifyIdle
            case .starting: .generationModifyStarting
            case .running: .generationModifyRunning
            case .waitingForInput: .generationModifyWaiting
            case .paused, .recoverableFailed: .generationModifyFailed
            case .cancelling: .generationModifyCancelling
            case .cancelCleanup: .generationModifyCancelling
            case .succeeded: .generationModifySucceeded
            case .failed: .generationModifyFailed
            case .cancelled: .generationModifyCancelled
            }
        } else {
            switch state {
            case .idle: .generationCreateIdle
            case .starting: .generationCreateStarting
            case .running: .generationCreateRunning
            case .waitingForInput: .generationCreateWaiting
            case .paused, .recoverableFailed: .generationCreateFailed
            case .cancelling: .generationCreateCancelling
            case .cancelCleanup: .generationCreateCancelling
            case .succeeded: .generationCreateSucceeded
            case .failed: .generationCreateFailed
            case .cancelled: .generationCreateCancelled
            }
        }
        return APCLocalization.text(key, locale: locale)
    }
}
