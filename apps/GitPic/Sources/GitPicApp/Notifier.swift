import Foundation
import UserNotifications
import GitPicCore

/// Posts upload outcomes as system notifications.
///
/// This is the app's only result surface. The status-item icon still shows that an
/// upload is *in flight*, but what happened is said here — which means a denied
/// permission costs the user every outcome message. That trade was made
/// deliberately; `authorize()` logs the denial so the log remains a way to find out.
///
/// **Launching matters.** `requestAuthorization` only works in a bundle that came up
/// through Launch Services. Measured three ways on an ad-hoc signed bundle:
///
/// | how it was started | result |
/// | --- | --- |
/// | `Contents/MacOS/GitPic` directly | `requestAuthorization` never returns, no prompt |
/// | `open GitPic.app` | prompt shown, `granted=true`, banners delivered |
///
/// So ad-hoc signing is **not** an obstacle — `/Applications/GitPic.app` is ad-hoc
/// signed too — but running the executable by hand is. Verify with
/// `open dist-app/GitPic.app`, never by invoking the binary, or a working build
/// looks like a broken one.
///
/// **No `UNUserNotificationCenterDelegate`, deliberately.** `willPresent` is only
/// consulted while the app is foreground, and an `.accessory` app never is; measured,
/// banners are delivered without the delegate ever being called. Adding one back
/// (to handle notification clicks, say) means dealing with the fact that the protocol
/// is not `@MainActor` in the macOS 26 SDK: a `@MainActor` conformer fails to build
/// under Swift 6 because `UNUserNotificationCenter` and `UNNotification` are not
/// `Sendable`, and the fix is `nonisolated` methods rather than `@unchecked Sendable`.
@MainActor
enum Notifier {

    /// Ask once, at launch, and record the answer.
    static func authorize() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            Diagnostics.log("notifications: granted=\(granted)")
            if !granted {
                // The one failure that leaves no other trace: with permission
                // refused, every upload outcome goes nowhere the user will look.
                Diagnostics.log("  outcomes will not be shown — enable GitPic in"
                                + " System Settings ▸ Notifications")
            }
        } catch {
            Diagnostics.log("notifications: requestAuthorization failed: \(error)")
        }
    }

    static func post(_ notice: UploadNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        // nil trigger: deliver now.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                           content: content, trigger: nil)
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Diagnostics.log("notification not delivered: \(error)")
            }
        }
    }
}
