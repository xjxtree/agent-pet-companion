import Foundation
import AgentPetCompanionCore
import UserNotifications

final class MakerNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable {
    static let shared = MakerNotificationCoordinator()

    @MainActor private var route: ((String) -> Void)?

    @MainActor
    func configure(route: @escaping (String) -> Void) {
        self.route = route
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(jobID: String, state: GenerationSessionState, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["generation_job_id": jobID]
        let request = UNNotificationRequest(
            identifier: "maker.\(jobID).\(state.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let jobID = response.notification.request.content.userInfo["generation_job_id"] as? String
        completionHandler()
        Task { @MainActor [weak self] in
            if let jobID, !jobID.isEmpty {
                self?.route?(jobID)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
