import Foundation
import When

public class Networking: NSObject {

  enum SessionTaskKind {
    case Data, Upload, Download
  }

  public enum Mode {
    case Sync, Async, Limited(Int)
  }

  public var additionalHeaders: (() -> [String: String])?
  public var beforeEach: (Requestable -> Requestable)?
  public var preProcessRequest: (NSMutableURLRequest -> Void)?

  public var middleware: (Promise<Void>) -> Void = { promise in
    promise.resolve()
  }

  var baseURLString: URLStringConvertible?
  let sessionConfiguration: SessionConfiguration
  var customHeaders = [String: String]()
  var mocks = [String: Mock]()
  var requestStorage = RequestStorage()
  var mode: Mode = .Async
  let queue: NSOperationQueue

  weak var sessionDelegate: NSURLSessionDelegate?

  lazy var session: NSURLSession = { [unowned self] in
    return NSURLSession(
      configuration: self.sessionConfiguration.value,
      delegate: self.sessionDelegate ?? self,
      delegateQueue: nil)
    }()

  var requestHeaders: [String: String] {
    var headers = customHeaders

    headers["Accept-Language"] = Header.acceptLanguage

    let extraHeaders = additionalHeaders?() ?? [:]

    extraHeaders.forEach { key, value in
      headers[key] = value
    }

    return headers
  }

  // MARK: - Initialization

  public init(baseURLString: URLStringConvertible? = nil,
              mode: Mode = .Async,
              sessionConfiguration: SessionConfiguration = .Default,
              sessionDelegate: NSURLSessionDelegate? = nil) {
    self.baseURLString = baseURLString
    self.sessionConfiguration = sessionConfiguration
    self.sessionDelegate = sessionDelegate

    queue = NSOperationQueue()
    super.init()
    resetMode(mode)
  }

  // MARK: - Mode

  func resetMode(mode: Mode) {
    self.mode = mode

    switch mode {
    case .Sync:
      queue.maxConcurrentOperationCount = 1
    case .Async:
      queue.maxConcurrentOperationCount = -1
    case .Limited(let count):
      queue.maxConcurrentOperationCount = count
    }
  }

  // MARK: - Networking

  func start(request: Requestable) -> Ride {
    let ride = Ride()
    let URLRequest: NSMutableURLRequest

    do {
      let request = beforeEach?(request) ?? request
      URLRequest = try request.toURLRequest(baseURLString, additionalHeaders: requestHeaders)
    } catch {
      ride.reject(error)
      return ride
    }

    preProcessRequest?(URLRequest)

    let operation: ConcurrentOperation

    switch Malibu.mode {
    case .Regular:
      operation = DataOperation(session: session, URLRequest: URLRequest, ride: ride)
    case .Partial:
      if let mock = prepareMock(request) {
        operation = MockOperation(mock: mock, URLRequest: URLRequest, ride: ride)
      } else {
        operation = DataOperation(session: session, URLRequest: URLRequest, ride: ride)
      }
    case .Fake:
      guard let mock = prepareMock(request) else {
        ride.reject(Error.NoMockProvided)
        return ride
      }

      operation = MockOperation(mock: mock, URLRequest: URLRequest, ride: ride)
    }

    let etagPromise = ride.then { [weak self] result -> Wave in
      self?.saveEtag(request, response: result.response)
      return result
    }

    let nextRide = Ride()

    etagPromise
      .done({ value in
        if logger.enabled {
          logger.requestLogger.init(level: logger.level).logRequest(request, URLRequest: value.request)
          logger.responseLogger.init(level: logger.level).logResponse(value.response)
        }
        nextRide.resolve(value)
      })
      .fail({ [weak self] error in
        if logger.enabled {
          logger.errorLogger.init(level: logger.level).logError(error)
        }

        self?.handleError(error, on: request)
        nextRide.reject(error)
      })

    queue.addOperation(operation)

    return nextRide
  }

  func execute(request: Requestable) -> Ride {
    let ride = Ride()
    let beforePromise = Promise<Void>()

    beforePromise
      .then({
        return self.start(request)
      })
      .done({ wave in
        ride.resolve(wave)
      })
      .fail({ error in
        ride.reject(error)
      })

    middleware(beforePromise)

    return ride
  }

  // MARK: - Authentication

  public func authenticate(username username: String, password: String) {
    guard let header = Header.authentication(username: username, password: password) else {
      return
    }

    customHeaders["Authorization"] = header
  }

  public func authenticate(authorizationHeader authorizationHeader: String) {
    customHeaders["Authorization"] = authorizationHeader
  }

  public func authenticate(bearerToken bearerToken: String) {
    customHeaders["Authorization"] = "Bearer \(bearerToken)"
  }

  // MARK: - Mocks

  public func register(mock mock: Mock) {
    mocks[mock.request.key] = mock
  }

  func prepareMock(request: Requestable) -> Mock? {
    guard let mock = mocks[request.key] else { return nil }

    mock.request = beforeEach?(mock.request) ?? mock.request

    return mock
  }

  // MARK: - Helpers

  func saveEtag(request: Requestable, response: NSHTTPURLResponse) {
    guard let etag = response.allHeaderFields["ETag"] as? String else {
      return
    }

    let prefix = baseURLString?.URLString ?? ""

    ETagStorage().add(etag, forKey: request.etagKey(prefix))
  }

  func handleError(error: ErrorType, on request: Requestable) {
    guard request.storePolicy == StorePolicy.Offline && (error as NSError).isOffline else {
      return
    }

    requestStorage.save(RequestCapsule(request: request))
  }
}

// MARK: - Requests

public extension Networking {

  func GET(request: GETRequestable) -> Ride {
    return execute(request)
  }

  func POST(request: POSTRequestable) -> Ride {
    return execute(request)
  }

  func PUT(request: PUTRequestable) -> Ride {
    return execute(request)
  }

  func PATCH(request: PATCHRequestable) -> Ride {
    return execute(request)
  }

  func DELETE(request: DELETERequestable) -> Ride {
    return execute(request)
  }

  func HEAD(request: HEADRequestable) -> Ride {
    return execute(request)
  }

  func cancelAllRequests() {
    queue.cancelAllOperations()
  }
}

// MARK: - Replay

extension Networking {

  public func replay() -> Ride {
    let requests = requestStorage.requests.values
    let currentMode = mode

    resetMode(.Sync)

    let lastRide = Ride()

    for (index, request) in requests.enumerate() {
      execute(request)
        .done({ value in
          lastRide.resolve(value)
        })
        .fail({ error in
          lastRide.reject(error)
        })
        .always({ [weak self] _ in
          if index == requests.count - 1 {
            self?.resetMode(currentMode)
          }
        })
    }

    return lastRide
  }
}

// MARK: - NSURLSessionDelegate

extension Networking: NSURLSessionDelegate {

  public func URLSession(session: NSURLSession, didReceiveChallenge challenge: NSURLAuthenticationChallenge, completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential?) -> Void) {
    guard let baseURLString = baseURLString,
      baseURL = NSURL(string: baseURLString.URLString),
      serverTrust = challenge.protectionSpace.serverTrust
      else { return }

    if challenge.protectionSpace.host == baseURL.host {
      completionHandler(
        NSURLSessionAuthChallengeDisposition.UseCredential,
        NSURLCredential(forTrust: serverTrust))
    }
  }
}
