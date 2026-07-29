import Flutter
import UIKit
#if CRISP_WEBRTC
import CrispWebRTC
#else
import Crisp
#endif

/// [FlutterCrispChatPlugin] manages the integration of Crisp Chat SDK with Flutter,
/// handling all method channel callbacks and implementing UIApplicationDelegate methods.
public class FlutterCrispChatPlugin: NSObject, FlutterPlugin, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private var channel: FlutterMethodChannel?
    private var crispConfig: CrispConfig?
    private weak var previousNotificationDelegate: UNUserNotificationCenterDelegate?

    /// Dedicated window used to present the Crisp chat.
    ///
    /// Using a separate UIWindow means Flutter's own window is never covered,
    /// so FlutterViewController never pauses its rendering engine — eliminating
    /// the black screen that occurs when a fullScreen modal dismisses over
    /// FlutterViewController. The window also intercepts all touch events while
    /// visible, preventing tap-through to the Flutter UI underneath.
    private var chatWindow: UIWindow?

    /// Registers the plugin with the Flutter engine.
    /// This sets up the method channel and adds the plugin as a delegate for method calls.
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_crisp_chat", binaryMessenger: registrar.messenger())
        let instance = FlutterCrispChatPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)

        let notificationCenter = UNUserNotificationCenter.current()
        instance.previousNotificationDelegate = notificationCenter.delegate
        notificationCenter.delegate = instance

        // Register for remote notifications as required by Crisp SDK
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Handles method calls from Flutter to native iOS.
    /// The calls are routed to appropriate Crisp SDK methods based on the method name.
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "openCrispChat":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "No arguments passed.", details: nil))
                return
            }

            guard let crispConfig = CrispConfig.fromJson(args) else {
                result(
                    FlutterError(
                        code: "INVALID_ARGUMENTS",
                        message: "Crisp website ID not found.",
                        details: nil
                    )
                )
                return
            }
            let websiteID = crispConfig.websiteID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !websiteID.isEmpty else {
                result(
                    FlutterError(
                        code: "INVALID_ARGUMENTS",
                        message: "Crisp website ID not found.",
                        details: nil
                    )
                )
                return
            }

            applyCrispConfig(crispConfig, websiteID: websiteID)

            if openChat(modalPresentationStyle: crispConfig.modalPresentationStyle) {
                result(nil)
            } else {
                result(
                    FlutterError(
                        code: "NO_ACTIVE_SCENE",
                        message: "No active iOS scene is available to present Crisp chat.",
                        details: nil
                    )
                )
            }

        case "configureCrispSession":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "No arguments passed.", details: nil))
                return
            }

            guard let crispConfig = CrispConfig.fromJson(args) else {
                result(
                    FlutterError(
                        code: "INVALID_ARGUMENTS",
                        message: "Crisp website ID not found.",
                        details: nil
                    )
                )
                return
            }
            let websiteID = crispConfig.websiteID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !websiteID.isEmpty else {
                result(
                    FlutterError(
                        code: "INVALID_ARGUMENTS",
                        message: "Crisp website ID not found.",
                        details: nil
                    )
                )
                return
            }

            applyCrispConfig(crispConfig, websiteID: websiteID)
            result(nil)

        case "resetCrispChatSession":
            // Per Crisp's own docs: clear the token BEFORE resetting, or the
            // reset only unbinds this app locally while the remote session
            // (and its Session Continuity token) stays alive server-side -
            // https://crisp-im.github.io/crisp-sdk-ios/documentation/crisp/crispsdk/settokenid(tokenid:)
            CrispSDK.setTokenID(tokenID: nil)
            CrispSDK.session.reset()
            result(nil)

        case "setSessionString":
            guard let args = call.arguments as? [String: Any],
                  let key = args["key"] as? String,
                  let value = args["value"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Expected key of type String and value of type String.", details: nil))
                return
            }
            CrispSDK.session.setString(value, forKey: key)
            result(nil)

        case "setSessionInt":
            guard let args = call.arguments as? [String: Any],
                  let key = args["key"] as? String,
                  let value = args["value"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Expected key of type String and value of type Int.", details: nil))
                return
            }
            CrispSDK.session.setInt(value, forKey: key)
            result(nil)

        case "getSessionIdentifier":
            if let sessionId = CrispSDK.session.identifier {
                result(sessionId)
            } else {
                result(FlutterError(code: "NO_SESSION", message: "No active session found", details: nil))
            }

        case "setSessionSegments":
            guard let args = call.arguments as? [String: Any],
                  let segments = args["segments"] as? [String],
                  let overwrite = args["overwrite"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Expected segments of type String and overwrite of type Bool.", details: nil))
                return
            }

            let previousSegments = CrispSDK.session.segments
            CrispSDK.session.segments = overwrite ? segments : (previousSegments ?? []) + segments
            result(nil)

        case "pushSessionEvent":
            guard let args = call.arguments as? [String: Any],
                  let name = args["name"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Expected at least 'name' of type String.", details: nil))
                return
            }

            var eventColor: SessionEventColor = .blue

            if let colorString = args["color"] as? String {
                switch colorString.lowercased() {
                case "black": eventColor = .black
                case "blue": eventColor = .blue
                case "brown": eventColor = .brown
                case "green": eventColor = .green
                case "grey": eventColor = .grey
                case "orange": eventColor = .orange
                case "pink": eventColor = .pink
                case "purple": eventColor = .purple
                case "red": eventColor = .red
                case "yellow": eventColor = .yellow
                default:
                    print("Invalid color string: \(colorString). Using default: .blue")
                    eventColor = .blue
                }
            }

            let event = SessionEvent(name: name, color: eventColor)
            CrispSDK.session.pushEvents([event])
            result(nil)

        case "openChatboxFromNotification":
            result(false)

        case "openHelpdesk":
            guard let args = call.arguments as? [String: Any],
                  let websiteId = args["websiteId"] as? String,
                  !websiteId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing or empty 'websiteId'.", details: nil))
                return
            }
            CrispSDK.configure(websiteID: websiteId.trimmingCharacters(in: .whitespacesAndNewlines))
            CrispSDK.searchHelpdesk()
            if openChat() {
                result(nil)
            } else {
                result(FlutterError(code: "NO_ACTIVE_SCENE", message: "No active iOS scene is available to present Crisp chat.", details: nil))
            }

        case "openHelpdeskArticle":
            guard let args = call.arguments as? [String: Any],
                  let websiteId = args["websiteId"] as? String,
                  !websiteId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let locale = args["locale"] as? String,
                  let slug = args["slug"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing required arguments: 'websiteId', 'locale', 'slug'.", details: nil))
                return
            }
            let title = args["title"] as? String
            let category = args["category"] as? String
            CrispSDK.configure(websiteID: websiteId.trimmingCharacters(in: .whitespacesAndNewlines))
            CrispSDK.openHelpdeskArticle(locale: locale, slug: slug, title: title, category: category)
            if openChat() {
                result(nil)
            } else {
                result(FlutterError(code: "NO_ACTIVE_SCENE", message: "No active iOS scene is available to present Crisp chat.", details: nil))
            }

        case "isVideoCallsSupported":
            #if CRISP_WEBRTC
            result(true)
            #else
            result(false)
            #endif

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Configures the Crisp SDK (website ID, push notification prompt, token ID,
    /// session segment, and user fields) without presenting any UI.
    ///
    /// Shared by `openCrispChat` and `configureCrispSession` so a session can be
    /// registered (and push notifications enabled) either with or without the
    /// chat window being shown.
    private static let lastWebsiteIDDefaultsKey = "CrispChatLastWebsiteID"
    private static let lastTokenIDDefaultsKey = "CrispChatLastTokenID"
    private static let lastDeviceTokenDefaultsKey = "CrispChatLastDeviceToken"

    private func applyCrispConfig(_ crispConfig: CrispConfig, websiteID: String) {
        NSLog("[CrispPlugin] applyCrispConfig called: websiteID=\(websiteID), tokenId=\(crispConfig.tokenId ?? "nil")")
        UserDefaults.standard.set(websiteID, forKey: Self.lastWebsiteIDDefaultsKey)
        CrispSDK.configure(websiteID: websiteID)
        CrispSDK.setShouldPromptForNotificationPermission(crispConfig.enableNotifications)

        if let tokenId = crispConfig.tokenId {
            UserDefaults.standard.set(tokenId, forKey: Self.lastTokenIDDefaultsKey)
            CrispSDK.setTokenID(tokenID: tokenId)
        }

        // configure()/setTokenID() above can (re)create the Crisp session -
        // e.g. resetCrispChatSession() on login wipes it - and the device
        // token is only ever handed to the SDK from the one-shot OS callback
        // below, which doesn't fire again just because the session reset.
        // Re-apply whatever token we already have on file so a session reset
        // doesn't leave the new session with no token bound to it at all.
        if let lastDeviceTokenData = UserDefaults.standard.data(forKey: Self.lastDeviceTokenDefaultsKey) {
            NSLog("[CrispPlugin] Re-applying persisted device token after (re)configure, length=\(lastDeviceTokenData.count)")
            CrispSDK.setDeviceToken(lastDeviceTokenData)
        }
        if let segment = crispConfig.sessionSegment {
            CrispSDK.session.segment = segment
        }

        CrispSDK.user.email = crispConfig.user?.email
        CrispSDK.user.signature = crispConfig.user?.signature
        CrispSDK.user.nickname = crispConfig.user?.nickName
        CrispSDK.user.phone = crispConfig.user?.phone
        if let avatarURLString = crispConfig.user?.avatar, let avatarURL = URL(string: avatarURLString) {
            CrispSDK.user.avatar = avatarURL
        } else {
            CrispSDK.user.avatar = nil
        }

        CrispSDK.user.company = crispConfig.user?.company?.toCrispCompany()
    }

    /// Opens the Crisp chat in a dedicated UIWindow.
    ///
    /// The chat window sits above Flutter's window at `.alert` level.
    /// Flutter's window is never covered, so its rendering engine never pauses —
    /// no black screen on dismiss. The chat window intercepts all touches while
    /// visible — no tap-through to Flutter.
    private func openChat(modalPresentationStyle: UIModalPresentationStyle = .fullScreen) -> Bool {
        guard chatWindow == nil else { return true }
        guard let windowScene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return false }

        let chatVC = ChatViewController()
        chatVC.modalPresentationStyle = modalPresentationStyle

        let hostVC = CrispChatHostViewController(chatViewController: chatVC) { [weak self] in
            self?.chatWindow?.isHidden = true
            self?.chatWindow = nil
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = hostVC
        window.windowLevel = .alert
        window.makeKeyAndVisible()
        chatWindow = window
        return true
    }

    /// Retries `openChat()` a bounded number of times (every 200ms, up to 10
    /// attempts / ~2s) until a `.foregroundActive` scene exists.
    ///
    /// During a cold launch triggered by tapping a notification, the app's
    /// scene may still be transitioning and not yet `.foregroundActive` at the
    /// instant `didReceive` fires — `openChat()` would then silently fail with
    /// no retry. Gives up quietly (same as today) once attempts run out.
    private func openChatRetryingUntilSceneReady(
        modalPresentationStyle: UIModalPresentationStyle = .fullScreen,
        attemptsRemaining: Int = 10
    ) {
        if openChat(modalPresentationStyle: modalPresentationStyle) {
            return
        }
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.openChatRetryingUntilSceneReady(
                modalPresentationStyle: modalPresentationStyle,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    /// Handles registration of device token for push notifications.
    ///
    /// This fires on its own OS timeline, uncoordinated with when Dart calls
    /// configureCrispSession()/openCrispChat() (applyCrispConfig above). If the
    /// device token arrives *after* applyCrispConfig already ran - more likely
    /// on a fresh install, where this is the first-ever APNs handshake for this
    /// device/app pair and can take noticeably longer - CrispSDK.configure()/
    /// setTokenID() already completed without a device token to associate,
    /// and nothing else re-syncs the two. Re-applying the last-known
    /// websiteID/tokenID here closes that race: whichever of the two async
    /// events (config vs. token) lands second always completes the pairing.
    public func application(_ application: UIApplication,
                            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NSLog("[CrispPlugin] Device token registered, length=\(deviceToken.count)")
        UserDefaults.standard.set(deviceToken, forKey: Self.lastDeviceTokenDefaultsKey)

        if let lastWebsiteID = UserDefaults.standard.string(forKey: Self.lastWebsiteIDDefaultsKey),
           !lastWebsiteID.isEmpty {
            let lastTokenID = UserDefaults.standard.string(forKey: Self.lastTokenIDDefaultsKey)
            NSLog("[CrispPlugin] Re-applying last-known config before device token: websiteID=\(lastWebsiteID), tokenID=\(lastTokenID ?? "nil")")
            CrispSDK.configure(websiteID: lastWebsiteID)
            if let lastTokenID = lastTokenID, !lastTokenID.isEmpty {
                CrispSDK.setTokenID(tokenID: lastTokenID)
            }
        } else {
            NSLog("[CrispPlugin] Device token arrived but no lastWebsiteID persisted yet - applyCrispConfig hasn't run in this process")
        }

        CrispSDK.setDeviceToken(deviceToken)
    }

    /// Handles incoming notifications and checks if they are Crisp notifications.
    /// If they are, they are processed by the Crisp SDK.
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        NSLog("[CrispPlugin] willPresent notification called, userInfo=\(notification.request.content.userInfo)")
        if CrispSDK.isCrispPushNotification(notification) {
            NSLog("[CrispPlugin] Crisp notification detected in willPresent")
            CrispSDK.handlePushNotification(notification)
            if #available(iOS 14.0, *) {
                completionHandler([.banner, .sound])
            } else {
                completionHandler([.alert, .sound])
            }
        } else {
            NSLog("[CrispPlugin] Non-Crisp notification in willPresent")
            if let previousNotificationDelegate = previousNotificationDelegate,
               previousNotificationDelegate !== self,
               previousNotificationDelegate.responds(to: #selector(userNotificationCenter(_:willPresent:withCompletionHandler:))) {
                previousNotificationDelegate.userNotificationCenter?(
                    center,
                    willPresent: notification,
                    withCompletionHandler: completionHandler
                )
            } else {
                completionHandler([])
            }
        }
    }

    /// Handles user interactions with notifications.
    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        NSLog("[CrispPlugin] didReceive notification response called")
        let notification = response.notification
        if CrispSDK.isCrispPushNotification(notification) {
            NSLog("[CrispPlugin] Crisp notification tapped - opening chat")
            CrispSDK.handlePushNotification(notification)

            // If the app was killed and relaunched by this tap, Dart's
            // configureCrispSession()/openCrispChat() may not have run yet in
            // this process, leaving CrispSDK unconfigured. Fall back to the
            // last-known website ID persisted in applyCrispConfig(_:websiteID:)
            // so openChat() below doesn't present a chat view with no website
            // ID configured. This never touches tokenId/user/session data, so
            // it can't resurrect a previous user's conversation.
            if let lastWebsiteID = UserDefaults.standard.string(forKey: Self.lastWebsiteIDDefaultsKey),
               !lastWebsiteID.isEmpty {
                CrispSDK.configure(websiteID: lastWebsiteID)
            }

            DispatchQueue.main.async { [weak self] in
                self?.openChatRetryingUntilSceneReady()
            }
        } else {
            NSLog("[CrispPlugin] Non-Crisp notification tapped")
            if let previousNotificationDelegate = previousNotificationDelegate,
               previousNotificationDelegate !== self,
               previousNotificationDelegate.responds(to: #selector(userNotificationCenter(_:didReceive:withCompletionHandler:))) {
                previousNotificationDelegate.userNotificationCenter?(
                    center,
                    didReceive: response,
                    withCompletionHandler: completionHandler
                )
                return
            }
        }
        completionHandler()
    }
}

/// A transparent host view controller that is the root of the chat UIWindow.
///
/// Presents ChatViewController as soon as it appears, then hides the entire
/// chat window when ChatViewController is dismissed — without touching
/// Flutter's view hierarchy or rendering engine.
private class CrispChatHostViewController: UIViewController {
    private let chatViewController: ChatViewController
    private let onDismissed: () -> Void
    private var hasPresentedChat = false
    private var pendingDismissalCheck: DispatchWorkItem?

    init(chatViewController: ChatViewController, onDismissed: @escaping () -> Void) {
        self.chatViewController = chatViewController
        self.onDismissed = onDismissed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasPresentedChat else { return }
        hasPresentedChat = true
        attachSentinelAndPresent(chatViewController)
    }

    private func attachSentinelAndPresent(_ viewController: UIViewController) {
        configurePopoverPresentationIfNeeded(for: viewController)
        let sentinel = CrispDismissalSentinel { [weak self] in
            self?.scheduleDismissalCheck()
        }
        sentinel.attach(to: viewController.view)
        present(viewController, animated: true)
    }

    /// Configures `popoverPresentationController` when presenting on iPad.
    /// On iPhone, UIKit adapts `.popover` to a full-screen sheet automatically.
    private func configurePopoverPresentationIfNeeded(for viewController: UIViewController) {
        guard viewController.modalPresentationStyle == .popover,
              let popover = viewController.popoverPresentationController else {
            return
        }
        popover.sourceView = view
        let bounds = view.bounds
        popover.sourceRect = CGRect(
            x: bounds.midX,
            y: bounds.midY,
            width: 1,
            height: 1
        )
        popover.permittedArrowDirections = []
    }

    /// Called whenever a sentinel detects that its host view left the window hierarchy.
    ///
    /// Defers the actual decision to the next main-queue cycle. This gives the Crisp SDK
    /// a chance to synchronously re-present another VC (e.g. a camera picker after a
    /// camera-permission grant) before we decide whether the dismissal was user-initiated.
    ///
    /// - If Crisp re-presented something: attach a new sentinel to track that VC.
    /// - If nothing was re-presented: treat as a real user dismissal and tear down the window.
    private func scheduleDismissalCheck() {
        pendingDismissalCheck?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if let newVC = self.presentedViewController {
                // Crisp SDK re-presented a VC (e.g. camera picker). Track its dismissal.
                let newSentinel = CrispDismissalSentinel { [weak self] in
                    self?.scheduleDismissalCheck()
                }
                newSentinel.attach(to: newVC.view)
            } else {
                self.onDismissed()
            }
        }
        pendingDismissalCheck = workItem
        DispatchQueue.main.async(execute: workItem)
    }
}

/// Invisible zero-size view embedded in a view controller's view hierarchy.
///
/// UIKit removes the view from its window after any dismissal animation completes,
/// regardless of modalPresentationStyle. `didMoveToWindow` with `window == nil` is
/// therefore a reliable cross-style dismissal signal.
private class CrispDismissalSentinel: UIView {
    private let onDismissed: () -> Void
    private var hasBeenInWindow = false
    private var hasFired = false

    init(onDismissed: @escaping () -> Void) {
        self.onDismissed = onDismissed
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(to view: UIView) {
        view.addSubview(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            hasBeenInWindow = true
        } else if hasBeenInWindow && !hasFired {
            hasFired = true
            onDismissed()
        }
    }
}
