import CoreLocation
import Flutter
import Foundation
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // The publisher belongs to the native app, not to a Flutter widget or Dart timer.
  private let publisher = NativeGpsPublisher()
  private var controlChannel: FlutterMethodChannel?
  private var stateChannel: FlutterEventChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    controlChannel = FlutterMethodChannel(name: "technician_tracker/control", binaryMessenger: messenger)
    stateChannel = FlutterEventChannel(name: "technician_tracker/state", binaryMessenger: messenger)
    stateChannel?.setStreamHandler(publisher)
    controlChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "UNAVAILABLE", message: "Please reopen the app.", details: nil))
        return
      }
      self.publisher.handle(call, result: result)
    }
  }
}

// All state transitions and CLLocationManager calls run on the main thread.
// Tokens remain in memory, never enter URLs, preferences, logs, or background-upload files.
private final class NativeGpsPublisher: NSObject, FlutterStreamHandler, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private let api = PublisherAPI()
  private var eventSink: FlutterEventSink?
  private var token: String?
  private var generation = 0
  private var request: URLSessionDataTask?
  private var stopRequest: URLSessionDataTask?
  private var requestingStart = false
  private var sharing = false
  private var requestedAlways = false
  private var expiresAtMs: Double?
  private var serverOffsetMs = 0.0
  private var expiryTimer: Timer?
  private var uploadTimer: Timer?
  private var watchdogTimer: Timer?
  private var pendingLocation: CLLocation?
  private var lastObservedAtMs = 0.0
  private var serverAcceptedAtMs = 0.0
  private var gpsStartedAt = Date.distantPast
  private var lastInvitationCheck = Date.distantPast
  private var nextUploadAt = Date.distantPast
  private var retryDelay = 5.0
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var foregroundObserver: NSObjectProtocol?
  private var state: [String: Any] = [
    "status": "idle", "message": "Paste the invitation link sent by your agent.", "sharing": false,
    "expiresAtMs": NSNull(), "receivedAtMs": NSNull(), "latitude": NSNull(),
    "longitude": NSNull(), "accuracy": NSNull(), "capturedAtMs": NSNull()
  ]

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.distanceFilter = kCLDistanceFilterNone
    manager.activityType = .otherNavigation
    manager.pausesLocationUpdatesAutomatically = false
    manager.showsBackgroundLocationIndicator = true
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self, !self.checkExpiry(), self.requestingStart else { return }
      if self.manager.authorizationStatus == .authorizedWhenInUse
        || self.manager.authorizationStatus == .authorizedAlways {
        self.startLocationUpdates()
      }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "validateInvitation":
      guard !sharing && !requestingStart else { result(state); return }
      guard let value = tokenArgument(call) else {
        setStatus("error", "This invitation code is not valid. Paste the complete phone invitation link.")
        result(state)
        return
      }
      validate(value, startAfterValidation: false, result: result)
    case "startSharing":
      guard !sharing && !requestingStart else { result(state); return }
      guard UIApplication.shared.applicationState == .active else {
        setStatus("error", "Open the app and tap Start sharing to begin.")
        result(state)
        return
      }
      guard let value = tokenArgument(call) else {
        setStatus("error", "This invitation code is not valid. Paste your phone invitation again.")
        result(state)
        return
      }
      validate(value, startAfterValidation: true, result: nil)
      result(state)
    case "stopSharing":
      stopByUser()
      result(state)
    case "getState":
      _ = checkExpiry()
      refreshSharingHealth()
      result(state)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    _ = checkExpiry()
    refreshSharingHealth()
    events(state)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    // A hidden/disposed Flutter screen must not stop an explicitly started native session.
    return nil
  }

  private func tokenArgument(_ call: FlutterMethodCall) -> String? {
    guard let arguments = call.arguments as? [String: Any],
          let value = arguments["token"] as? String,
          value.utf8.count == 64,
          value.range(of: "^[0-9A-Fa-f]{64}$", options: .regularExpression) != nil else { return nil }
    return value.lowercased()
  }

  private func validate(_ value: String, startAfterValidation: Bool, result: FlutterResult?) {
    generation += 1
    let operation = generation
    request?.cancel()
    request = nil
    token = nil
    expiresAtMs = nil
    expiryTimer?.invalidate()
    requestingStart = startAfterValidation
    clearLocationState()
    setStatus("starting", "Checking your invitation…")
    request = api.send(action: "validate", token: value) { [weak self] response in
      guard let self = self else { result?(nil); return }
      guard operation == self.generation else { result?(self.state); return }
      self.request = nil
      switch response {
      case .success(let receipt):
        guard receipt.active == true, receipt.expired != true,
              let expiry = receipt.expiresAtMs, expiry.isFinite,
              let serverTime = receipt.serverTimeMs, serverTime.isFinite,
              expiry > serverTime else {
          self.halt(status: "expired", message: "This invitation has ended. Ask your agent for a new link.")
          result?(self.state)
          return
        }
        self.token = value
        self.expiresAtMs = expiry
        self.serverOffsetMs = serverTime - Self.nowMs
        self.lastInvitationCheck = Date()
        self.state["expiresAtMs"] = expiry
        // GPS fix timestamps come from the phone. A badly set clock would otherwise
        // produce repeated INVALID_SAMPLE responses and misleading sharing status.
        guard abs(self.serverOffsetMs) < 45_000 else {
          self.halt(status: "error", message: "Set your phone date and time to Automatic, then connect again.")
          result?(self.state)
          return
        }
        self.armExpiryTimer()
        if startAfterValidation {
          self.requestLocationPermission()
        } else {
          self.setStatus("ready", "Invitation connected. Tap Start sharing when you are ready.")
        }
      case .failure(let failure):
        self.halt(status: failure.isInvalidInvitation ? "expired" : "error", message: failure.message)
      }
      result?(self.state)
    }
  }

  private func requestLocationPermission() {
    guard UIApplication.shared.applicationState == .active else {
      requestingStart = false
      setStatus("ready", "Return to this app and tap Start sharing to begin.")
      return
    }
    guard CLLocationManager.locationServicesEnabled() else {
      halt(status: "error", message: "Turn on Location Services in iPhone Settings, then try again.")
      return
    }
    switch manager.authorizationStatus {
    case .notDetermined:
      setStatus("starting", "Allow location access so this phone can share its GPS during this session.")
      manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways:
      startLocationUpdates()
    case .denied, .restricted:
      halt(status: "error", message: "Location access is off. Allow it in Settings → Technician Tracker → Location, then try again.")
    @unknown default:
      halt(status: "error", message: "Location permission could not be checked. Reopen the app and try again.")
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      if requestingStart { startLocationUpdates() }
    case .denied, .restricted:
      if sharing || requestingStart {
        halt(status: "error", message: "Location permission was removed. Sharing has stopped on this phone.")
      }
    case .notDetermined:
      if sharing {
        halt(status: "error", message: "The temporary location permission ended. Sharing has stopped; tap Start to grant access again.")
      }
    default:
      break
    }
  }

  private func startLocationUpdates() {
    guard requestingStart, !sharing, token != nil, !checkExpiry() else { return }
    guard UIApplication.shared.applicationState == .active else {
      // Permission callbacks can arrive while the system dialog still leaves
      // the app inactive. Resume this explicit Start when it becomes active.
      setStatus("starting", "Return to this app to finish starting location sharing.")
      return
    }
    requestingStart = false
    sharing = true
    retryDelay = 5
    nextUploadAt = .distantPast
    lastObservedAtMs = 0
    serverAcceptedAtMs = 0
    gpsStartedAt = Date()
    manager.allowsBackgroundLocationUpdates = true
    manager.startUpdatingLocation()
    watchdogTimer?.invalidate()
    watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      self?.refreshSharingHealth()
    }
    setStatus("starting", "Waiting for a fresh GPS fix… You can lock the screen after sharing starts.")
    // When In Use can continue this user-started session in the background with
    // the visible location indicator. Always is requested as an upgrade, never
    // treated as a reason to hang the Start button or to silently restart later.
    if manager.authorizationStatus == .authorizedWhenInUse && !requestedAlways {
      requestedAlways = true
      manager.requestAlwaysAuthorization()
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard sharing, !checkExpiry() else { return }
    guard let location = locations.filter({ isUsable($0) }).max(by: { $0.timestamp < $1.timestamp }) else { return }
    let capturedAt = location.timestamp.timeIntervalSince1970 * 1000
    guard capturedAt > lastObservedAtMs else { return }
    lastObservedAtMs = capturedAt
    pendingLocation = location
    state["latitude"] = location.coordinate.latitude
    state["longitude"] = location.coordinate.longitude
    state["accuracy"] = location.horizontalAccuracy
    state["capturedAtMs"] = capturedAt.rounded(.down)
    emit()
    uploadLatestIfPossible()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard sharing else { return }
    if (error as? CLError)?.code == .denied {
      halt(status: "error", message: "Location access is unavailable. Sharing has stopped on this phone.")
    } else {
      setStatus("retrying", "Waiting for a fresh GPS fix. Move outdoors if the signal is weak.")
    }
  }

  private func isUsable(_ location: CLLocation) -> Bool {
    let age = Date().timeIntervalSince(location.timestamp)
    return CLLocationCoordinate2DIsValid(location.coordinate)
      && location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0
      && location.horizontalAccuracy <= 99_999_999.99
      && age >= -60 && age <= 90
  }

  private func uploadLatestIfPossible() {
    guard sharing, !checkExpiry(), request == nil,
          let value = token, let location = pendingLocation else { return }
    guard isUsable(location) else {
      pendingLocation = nil
      setStatus("retrying", "Waiting for a fresh GPS fix before sending another update.")
      return
    }
    let capturedAt = (location.timestamp.timeIntervalSince1970 * 1000).rounded(.down)
    guard capturedAt > serverAcceptedAtMs else {
      pendingLocation = nil
      return
    }
    let delay = nextUploadAt.timeIntervalSinceNow
    if delay > 0 {
      armUploadTimer(after: delay)
      return
    }
    uploadTimer?.invalidate()
    uploadTimer = nil
    pendingLocation = nil
    nextUploadAt = Date().addingTimeInterval(5)
    let operation = generation
    let fields: [String: Any] = [
      "latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude,
      "accuracy": location.horizontalAccuracy, "capturedAtMs": capturedAt
    ]
    beginNetworkBackgroundTask()
    request = api.send(action: "publish", token: value, fields: fields) { [weak self] response in
      guard let self = self, operation == self.generation else { return }
      self.request = nil
      self.endNetworkBackgroundTask()
      guard self.sharing, !self.checkExpiry() else { return }
      switch response {
      case .success(let receipt):
        guard receipt.active == true, receipt.expired != true else {
          self.halt(status: "expired", message: "This invitation has ended. Ask your agent for a new link.")
          return
        }
        guard let savedAt = receipt.receivedAtMs, savedAt.isFinite, savedAt > 0,
              let acceptedAt = receipt.acceptedCapturedAtMs, acceptedAt.isFinite,
              acceptedAt >= capturedAt else {
          self.halt(status: "error", message: "The tracking service returned an unexpected response. Ask your agent to check the mobile API setup.")
          return
        }
        self.retryDelay = 5
        self.serverAcceptedAtMs = acceptedAt
        self.lastInvitationCheck = Date()
        if let expiry = receipt.expiresAtMs, expiry.isFinite {
          self.expiresAtMs = expiry
          self.state["expiresAtMs"] = expiry
          self.armExpiryTimer()
        }
        if acceptedAt == capturedAt {
          self.state["receivedAtMs"] = savedAt
          let precision = self.manager.accuracyAuthorization == .reducedAccuracy
            ? " Precise Location is off; your position may be approximate." : ""
          self.setStatus("sharing", "GPS saved to Salesforce. Sharing continues while the screen is locked." + precision)
        } else {
          self.setStatus("retrying", "Salesforce already has a newer fix, possibly from another phone. Waiting for this phone’s next eligible GPS fix.")
        }
      case .failure(let failure):
        if failure.isInvalidInvitation {
          self.halt(status: "expired", message: failure.message)
          return
        }
        if !failure.retryable {
          self.halt(status: "error", message: failure.message)
          return
        }
        // Retain only the newest real fix, never a stale offline trail.
        if self.pendingLocation == nil || self.pendingLocation!.timestamp < location.timestamp {
          self.pendingLocation = location
        }
        self.nextUploadAt = Date().addingTimeInterval(self.retryDelay)
        self.retryDelay = min(self.retryDelay * 2, 30)
        self.setStatus("retrying", "GPS is running, but Salesforce has not confirmed the latest update. Retrying when connected.")
      }
      self.uploadLatestIfPossible()
    }
  }

  private func refreshSharingHealth() {
    guard sharing, !checkExpiry() else { return }
    let latestObserved = lastObservedAtMs > 0
      ? Date(timeIntervalSince1970: lastObservedAtMs / 1000) : gpsStartedAt
    if Date().timeIntervalSince(latestObserved) > 30 {
      setStatus("retrying", "No fresh GPS fix is available. The map shows the last location saved to Salesforce.")
    }
    uploadLatestIfPossible()
    guard request == nil, Date().timeIntervalSince(lastInvitationCheck) >= 30,
          let value = token else { return }
    // A stationary/indoor phone still checks whether its invitation was revoked.
    // This timer is not the mechanism that keeps the app alive: the active native
    // Core Location background session provides that OS permission to run.
    let operation = generation
    lastInvitationCheck = Date()
    beginNetworkBackgroundTask()
    request = api.send(action: "validate", token: value) { [weak self] response in
      guard let self = self, operation == self.generation else { return }
      self.request = nil
      self.endNetworkBackgroundTask()
      guard self.sharing, !self.checkExpiry() else { return }
      switch response {
      case .success(let receipt):
        guard receipt.active == true, receipt.expired != true,
              let expiry = receipt.expiresAtMs, expiry.isFinite,
              let serverTime = receipt.serverTimeMs, serverTime.isFinite,
              expiry > serverTime else {
          self.halt(status: "expired", message: "This invitation has ended. Ask your agent for a new link.")
          return
        }
        guard abs(serverTime - Self.nowMs) < 45_000 else {
          self.halt(status: "error", message: "Set your phone date and time to Automatic, then connect again.")
          return
        }
        self.serverOffsetMs = serverTime - Self.nowMs
        self.expiresAtMs = expiry
        self.state["expiresAtMs"] = expiry
        self.armExpiryTimer()
      case .failure(let failure):
        if failure.isInvalidInvitation || !failure.retryable {
          self.halt(status: failure.isInvalidInvitation ? "expired" : "error", message: failure.message)
          return
        }
        self.setStatus("retrying", "GPS is active, but Salesforce could not be reached. The map may show an older location.")
      }
      self.uploadLatestIfPossible()
    }
  }

  private func armUploadTimer(after delay: TimeInterval) {
    if uploadTimer != nil { return }
    uploadTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, delay), repeats: false) { [weak self] _ in
      self?.uploadTimer = nil
      self?.uploadLatestIfPossible()
    }
  }

  private func armExpiryTimer() {
    expiryTimer?.invalidate()
    guard let expiry = expiresAtMs else { return }
    let delay = max(0.1, (expiry - Self.nowMs - serverOffsetMs) / 1000)
    expiryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      _ = self?.checkExpiry()
    }
  }

  @discardableResult private func checkExpiry() -> Bool {
    guard let expiry = expiresAtMs, Self.nowMs + serverOffsetMs >= expiry else { return false }
    if sharing || requestingStart || token != nil {
      halt(status: "expired", message: "This tracking session has expired. Sharing has stopped on this phone.")
    }
    return true
  }

  private func stopByUser() {
    let value = token
    halt(status: "stopped", message: "Location sharing has stopped on this phone.")
    guard let value = value else { return }
    let operation = generation
    // Local collection ends before the network request. The invitation is also
    // revoked when reachable; a failed revocation is never presented as success.
    stopRequest = api.send(action: "stop", token: value) { [weak self] response in
      guard let self = self else { return }
      self.stopRequest = nil
      guard operation == self.generation else { return }
      if case .failure(let failure) = response, !failure.isInvalidInvitation {
        self.setStatus("stopped", "Stopped on this phone. The invitation could not be revoked online; ask your agent to revoke it if needed.")
      } else {
        self.setStatus("stopped", "Location sharing has stopped and this invitation is closed.")
      }
    }
  }

  private func halt(status: String, message: String) {
    generation += 1
    requestingStart = false
    sharing = false
    manager.stopUpdatingLocation()
    manager.allowsBackgroundLocationUpdates = false
    token = nil
    pendingLocation = nil
    request?.cancel()
    request = nil
    uploadTimer?.invalidate()
    uploadTimer = nil
    expiryTimer?.invalidate()
    expiryTimer = nil
    watchdogTimer?.invalidate()
    watchdogTimer = nil
    endNetworkBackgroundTask()
    setStatus(status, message)
  }

  private func clearLocationState() {
    for key in ["expiresAtMs", "receivedAtMs", "latitude", "longitude", "accuracy", "capturedAtMs"] {
      state[key] = NSNull()
    }
  }

  private func beginNetworkBackgroundTask() {
    endNetworkBackgroundTask()
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Send latest technician location") { [weak self] in
      self?.request?.cancel()
      self?.endNetworkBackgroundTask()
    }
  }

  private func endNetworkBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  private func setStatus(_ status: String, _ message: String) {
    state["status"] = status
    state["message"] = message
    emit()
  }

  private func emit() {
    state["sharing"] = sharing
    eventSink?(state)
  }

  private static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }
}

private struct PublisherReceipt: Decodable {
  let ok: Bool
  let active: Bool?
  let expired: Bool?
  let expiresAtMs: Double?
  let receivedAtMs: Double?
  let acceptedCapturedAtMs: Double?
  let serverTimeMs: Double?
  let code: String?
}

private struct PublisherFailure: Error {
  let message: String
  let retryable: Bool
  let isInvalidInvitation: Bool

  static let connection = PublisherFailure(
    message: "The tracking service could not be reached. Check your connection and try again.",
    retryable: true, isInvalidInvitation: false)
  static let setup = PublisherFailure(
    message: "The mobile tracking endpoint is unavailable. Ask your agent to check the Salesforce mobile API and guest access setup.",
    retryable: false, isInvalidInvitation: false)
  static let invitation = PublisherFailure(
    message: "This invitation is invalid, expired, or revoked. Ask your agent for a new phone link.",
    retryable: false, isInvalidInvitation: true)
}

private final class PublisherAPI: NSObject, URLSessionTaskDelegate {
  // Never derive a network endpoint from clipboard text or an untrusted invitation URL.
  private let endpoint = URL(string: "https://ddm00000pb3etuay-dev-ed.develop.my.site.com/LiveTracking/services/apexrest/technician-tracking/v1/publisher")!
  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 25
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()

  @discardableResult func send(
    action: String, token: String, fields: [String: Any] = [:],
    completion: @escaping (Result<PublisherReceipt, PublisherFailure>) -> Void
  ) -> URLSessionDataTask {
    var body = fields
    body["action"] = action
    body["token"] = token
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    let task = session.dataTask(with: request) { data, response, error in
      let outcome: Result<PublisherReceipt, PublisherFailure>
      if error != nil {
        outcome = .failure(.connection)
      } else if let http = response as? HTTPURLResponse {
        let receipt: PublisherReceipt?
        if let data = data, data.count <= 8192 {
          receipt = try? JSONDecoder().decode(PublisherReceipt.self, from: data)
        } else { receipt = nil }
        if http.statusCode == 403 && receipt?.code == "INVALID_INVITATION" {
          outcome = .failure(.invitation)
        } else if http.statusCode == 200, let receipt = receipt, receipt.ok {
          outcome = .success(receipt)
        } else if http.statusCode == 400 && receipt?.code == "INVALID_SAMPLE" {
          outcome = .failure(PublisherFailure(
            message: "Salesforce rejected this GPS fix. Set the phone date and time to Automatic, then reconnect.",
            retryable: false, isInvalidInvitation: false))
        } else if http.statusCode == 429 || http.statusCode >= 500 {
          outcome = .failure(.connection)
        } else {
          outcome = .failure(.setup)
        }
      } else {
        outcome = .failure(.connection)
      }
      DispatchQueue.main.async { completion(outcome) }
    }
    task.resume()
    return task
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Login/site redirects indicate a setup problem. Never forward the capability.
    completionHandler(nil)
  }
}
