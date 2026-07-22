import AgentPetCompanionCore
import Foundation

enum APCLocalizationKey: String, CaseIterable, Sendable {
    case appActionOpenControlCenter = "app.action.open_control_center"
    case appActionQuit = "app.action.quit"
    case appActionTogglePet = "app.action.toggle_pet"
    case appActionFocusPetSessions = "app.action.focus_pet_sessions"
    case appActionFocusPetResize = "app.action.focus_pet_resize"
    case navigationLibrary = "nav.library"
    case navigationAIPetMaker = "nav.ai_pet_maker"
    case navigationPetConfiguration = "nav.pet_configuration"
    case navigationConnections = "nav.connections"
    case navigationDiagnostics = "nav.diagnostics"
    case libraryLoadingTitle = "library.loading.title"
    case libraryLoadingDetail = "library.loading.detail"
    case libraryEmptyTitle = "library.empty.title"
    case libraryEmptyDetail = "library.empty.detail"
    case libraryEmptyAction = "library.empty.action"
    case libraryImportAction = "library.import.action"
    case libraryImportInProgress = "library.import.in_progress"
    case libraryImportTitle = "library.import.title"
    case libraryImportMessage = "library.import.message"
    case libraryFormatAppOwned = "library.format.app_owned"
    case libraryValidationInvalid = "library.validation.invalid"
    case libraryValidationVerifiedTitle = "library.validation.verified_title"
    case libraryValidationVerified = "library.validation.verified"
    case libraryValidationUnverifiedTitle = "library.validation.unverified_title"
    case libraryValidationUnverified = "library.validation.unverified"
    case librarySpecificationVerifiedStates = "library.specification.verified_states"
    case librarySpecificationVerifiedFps = "library.specification.verified_fps"
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
    case overlayStatusReview = "overlay.status.review"
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
    case overlayActionReview = "overlay.action.review"
    case commonCancel = "common.cancel"
    case commonRetry = "common.retry"
    case commonClear = "common.clear"
    case commonChoose = "common.choose"
    case commonNotReported = "common.not_reported"
    case commonRecommended = "common.recommended"
    case commonMinutesFormat = "common.minutes.format"
    case commonImagesFormat = "common.images.format"
    case commonValueOfTotalFormat = "common.value_of_total.format"
    case appActionCheckConnections = "app.action.check_connections"
    case appActionShowPet = "app.action.show_pet"
    case appActionHidePet = "app.action.hide_pet"
    case appActionMore = "app.action.more"
    case appActionAbout = "app.action.about"
    case appMenuCurrentPet = "app.menu.current_pet"
    case appMenuRecentAgent = "app.menu.recent_agent"
    case appMenuPetCore = "app.menu.petcore"
    case appStateNoPetEnabled = "app.state.no_pet_enabled"
    case appStateNoPet = "app.state.no_pet"
    case appStateNoRecentActivity = "app.state.no_recent_activity"
    case appStatePetCoreChecking = "app.state.petcore_checking"
    case appStatePetCoreRunning = "app.state.petcore_running"
    case appStatePetCoreFailed = "app.state.petcore_failed"
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
    case eventStart = "event.start"
    case eventTool = "event.tool"
    case eventWaiting = "event.waiting"
    case eventReview = "event.review"
    case eventDone = "event.done"
    case eventFailed = "event.failed"
    case styleRealistic = "style.realistic"
    case styleSemiRealistic = "style.semi_realistic"
    case styleModern = "style.modern"
    case stylePixel = "style.pixel"
    case styleAnime = "style.anime"
    case styleUnspecified = "style.unspecified"
    case qualityStandard = "quality.standard"
    case qualityHigh = "quality.high"
    case qualityUltra = "quality.ultra"
    case qualityOriginal = "quality.original"
    case qualitySizeFormat = "quality.size.format"
    case qualityRecommendedSizeFormat = "quality.recommended_size.format"
    case appearanceSystem = "appearance.system"
    case appearanceLight = "appearance.light"
    case appearanceDark = "appearance.dark"
    case sessionGroupStacked = "session_group.stacked"
    case sessionGroupExpanded = "session_group.expanded"
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
    case studioActionStart = "studio.action.start"
    case studioActionNew = "studio.action.new"
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
    case studioStyleHeading = "studio.brief.style_heading"
    case studioQualityHeading = "studio.brief.quality_heading"
    case studioQualityContractFormat = "studio.brief.quality_contract_format"
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
    case studioSessionCreate = "studio.session.create"
    case studioWelcomeTitle = "studio.session.welcome_title"
    case studioWelcomeDetail = "studio.session.welcome_detail"
    case studioOutputContractTitle = "studio.session.output_contract_title"
    case studioOutputContractDetail = "studio.session.output_contract_detail"
    case studioOutputPrivacy = "studio.session.output_privacy"
    case studioPreparing = "studio.session.preparing"
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
    case studioBaselineAnimationValue = "studio.baseline.animation_value"
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
    case configShowPet = "config.show_pet"
    case configShowPetDetail = "config.show_pet.detail"
    case configDisplayAppearance = "config.display_appearance"
    case configStatusBubble = "config.status_bubble"
    case configStatusBubbleDetail = "config.status_bubble.detail"
    case configAutoHide = "config.auto_hide"
    case configAutoHideDetail = "config.auto_hide.detail"
    case configContextMenu = "config.context_menu"
    case configContextMenuDetail = "config.context_menu.detail"
    case configMousePassthrough = "config.mouse_passthrough"
    case configMousePassthroughDetail = "config.mouse_passthrough.detail"
    case configDisplaySize = "config.display_size"
    case configSizeGuidance = "config.size_guidance"
    case configPetInteraction = "config.pet_interaction"
    case configSizeFooter = "config.size_footer"
    case configLivePreview = "config.live_preview"
    case configResponseSources = "config.response_sources"
    case configSourcesFooter = "config.sources_footer"
    case configResponseEvents = "config.response_events"
    case configPersistenceNote = "config.persistence_note"
    case configSessionDisplay = "config.session_display"
    case configMessagePreview = "config.message_preview"
    case configThemePicker = "config.theme_picker"
    case configThemeAccessibility = "config.theme_accessibility"
    case configThemeDetail = "config.theme_detail"
    case configFPSPicker = "config.fps_picker"
    case configFPSAccessibility = "config.fps_accessibility"
    case configFPSStandardDetail = "config.fps.standard_detail"
    case configFPSSmoothDetail = "config.fps.smooth_detail"
    case configBubbleTransparency = "config.bubble_transparency"
    case configGlassMore = "config.glass_more"
    case configTransparentMore = "config.transparent_more"
    case configTransparencyDetail = "config.transparency_detail"
    case configTimeout = "config.timeout"
    case configTimeoutDetail = "config.timeout_detail"
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
    case configSizeOnlyOnPet = "config.preview.size_only_on_pet"
    case configBubbleAutoShow = "config.preview.bubble_auto_show"
    case configBubbleWorking = "config.preview.bubble_working"
    case configResizeAccessibility = "config.preview.resize_accessibility"
    case configResizeHint = "config.preview.resize_hint"
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
    case configEventToolDetail = "config.event.tool_detail"
    case configEventWaitingDetail = "config.event.waiting_detail"
    case configEventReviewDetail = "config.event.review_detail"
    case configEventDoneDetail = "config.event.done_detail"
    case configEventFailedDetail = "config.event.failed_detail"
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
    case connectionsRecheck = "connections.action.recheck"
    case connectionsRecheckHint = "connections.hint.recheck"
    case connectionsTestChannel = "connections.action.test_channel"
    case connectionsTestHint = "connections.hint.test"
    case connectionsTestDetailFormat = "connections.test.detail_format"
    case connectionsCheckAccessibilityFormat = "connections.check.accessibility_format"
    case connectionsCheckNameAgentCLI = "connections.check.name.agent_cli"
    case connectionsCheckNameEventCLI = "connections.check.name.event_cli"
    case connectionsCheckNameProjectDirectory = "connections.check.name.project_directory"
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
    case connectionsCheckDescriptionProjectDirectory = "connections.check.description.project_directory"
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
    case connectionsVerificationTitle = "connections.verification.title"
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
    case connectionsDefaultHome = "connections.environment.default_home"
    case connectionsDirectoryDetail = "connections.environment.directory_detail"
    case connectionsChooseDirectory = "connections.environment.choose_directory"
    case connectionsResetDirectory = "connections.environment.reset_directory"
    case connectionsDirectoryPanelTitle = "connections.environment.directory_panel.title"
    case connectionsDirectoryPanelPrompt = "connections.environment.directory_panel.prompt"
    case connectionsDirectoryPanelMessage = "connections.environment.directory_panel.message"
    case connectionsProjectDirectory = "connections.environment.project_directory"
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
    case overlayMoreSessionsTitle = "overlay.sessions.more_title"
    case overlayMoreSessionsDetailFormat = "overlay.sessions.more_detail_format"
    case overlayHelpOpenAndDismiss = "overlay.help.open_and_dismiss"
    case overlayHelpDismiss = "overlay.help.dismiss"
    case overlayHelpOpen = "overlay.help.open"
    case overlayHelpUnavailable = "overlay.help.unavailable"
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
    case overlayResizeHelp = "overlay.resize.help"
    case overlaySessionAccessibilityFormat = "overlay.session.accessibility_format"
    case libraryPageSubtitle = "library.page.subtitle"
    case librarySearchPlaceholder = "library.search.placeholder"
    case libraryMakeAction = "library.make.action"
    case libraryAllCountFormat = "library.all_count.format"
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
    case libraryFieldFPS = "library.field.fps"
    case libraryFieldValidation = "library.field.validation"
    case libraryEditInstruction = "library.edit.instruction"
    case libraryEditInstructionAccessibility = "library.edit.instruction_accessibility"
    case libraryEditActiveWarning = "library.edit.active_warning"
    case libraryEditStart = "library.edit.start"
    // Arguments: display name, localized source title, stable manifest pet ID.
    case libraryCardAccessibilityFormat = "library.card.accessibility_format"
    case libraryActivateAccessibility = "library.activate.accessibility"
    case libraryInspectorTitle = "library.inspector.title"
    case libraryPetActive = "library.pet.active"
    case libraryEnablePet = "library.pet.enable"
    case libraryCurrentInfo = "library.current_info"
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
    case libraryFPSSummary = "library.fps.summary"
    case librarySourceBundledTitle = "library.source.bundled_title"
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
    case commonFPSFormat = "common.fps.format"
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

/// A non-global locale override for deterministic visual fixtures and tests.
///
/// Production views continue to follow `Locale.preferredLanguages`. A renderer
/// may scope one complete SwiftUI layout transaction with `withLocale`, which
/// lets the same implicit localization calls exercise English and Chinese in a
/// single process without mutating defaults or the user's language settings.
enum APCLocalizationFixtureScope {
    @TaskLocal static var localeIdentifier: String?

    static func withLocale<Result>(
        _ identifier: String,
        operation: () throws -> Result
    ) rethrows -> Result {
        let supported = APCLocalization.resolvedInterfaceLocaleIdentifier(
            preferredLanguages: [identifier]
        )
        return try $localeIdentifier.withValue(supported, operation: operation)
    }

    static func withLocale<Result>(
        _ identifier: String,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        let supported = APCLocalization.resolvedInterfaceLocaleIdentifier(
            preferredLanguages: [identifier]
        )
        return try await $localeIdentifier.withValue(supported, operation: operation)
    }
}

enum APCLocalization {
    static let requiredV1Keys = APCLocalizationKey.allCases
    static var interfaceLocaleIdentifier: String {
        if let fixtureLocaleIdentifier = APCLocalizationFixtureScope.localeIdentifier {
            return fixtureLocaleIdentifier
        }
        return resolvedInterfaceLocaleIdentifier(preferredLanguages: Locale.preferredLanguages)
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
            let url = APCResourceBundle.resourceURL(
                "\(locale).lproj/Localizable.strings"
            )
            guard let data = try? Data(contentsOf: url),
                  let values = try? PropertyListSerialization.propertyList(
                      from: data,
                      options: [],
                      format: nil
                  ) as? [String: String],
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
    static func eventTitle(
        _ event: AgentEventKind,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let key: APCLocalizationKey = switch event {
        case .start: .eventStart
        case .tool: .eventTool
        case .waiting: .eventWaiting
        case .review: .eventReview
        case .done: .eventDone
        case .failed: .eventFailed
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
        case .standard: .qualityStandard
        case .high: .qualityHigh
        case .ultra: .qualityUltra
        case .original: .qualityOriginal
        }
        return APCLocalization.text(key, locale: locale)
    }

    static func qualityDetail(
        _ quality: QualityLevel,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        let size = quality.renderSize
        return APCLocalization.format(
            quality == .high ? .qualityRecommendedSizeFormat : .qualitySizeFormat,
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

    static func sessionGroupTitle(
        _ display: SessionGroupDisplay,
        locale: String = APCLocalization.interfaceLocaleIdentifier
    ) -> String {
        APCLocalization.text(
            display == .stacked ? .sessionGroupStacked : .sessionGroupExpanded,
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
            case .cancelling: .generationModifyCancelling
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
            case .cancelling: .generationCreateCancelling
            case .succeeded: .generationCreateSucceeded
            case .failed: .generationCreateFailed
            case .cancelled: .generationCreateCancelled
            }
        }
        return APCLocalization.text(key, locale: locale)
    }
}
