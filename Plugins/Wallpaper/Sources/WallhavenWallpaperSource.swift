import Foundation

/// A bounded transfer. Delegates inspect headers, redirects, and streamed bytes before retaining data.
final class WallpaperHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var stopped = false
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    static func allows(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && ["wallhaven.cc", "www.wallhaven.cc", "w.wallhaven.cc", "th.wallhaven.cc"].contains(url.host?.lowercased() ?? "")
    }

    func fetch(_ url: URL) async throws -> Data {
        guard Self.allows(url) else { throw WallpaperFailure.invalidResponse }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if stopped { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 90
                config.httpMaximumConnectionsPerHost = 2
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("MacTools-Wallpaper/1.0", forHTTPHeaderField: "User-Agent")
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        self.task = nil
        buffer = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.allows(url) else {
            completionHandler(nil)
            finish(.failure(WallpaperFailure.invalidResponse))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(WallpaperFailure.invalidResponse)); return
        }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            if http.statusCode == 429 {
                let raw = http.value(forHTTPHeaderField: "Retry-After") ?? ""
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                let delay = Double(raw) ?? formatter.date(from: raw)?.timeIntervalSinceNow ?? 60
                finish(.failure(WallpaperFailure.rateLimited(max(60, delay))))
            } else { finish(.failure(WallpaperFailure.http(http.statusCode))) }
            return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(WallpaperFailure.invalidImage)); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if buffer.count + data.count > limit {
            lock.unlock(); finish(.failure(WallpaperFailure.invalidImage)); return
        }
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let result = buffer
        lock.unlock()
        finish(.success(result))
    }
}

protocol WallpaperSource: Sendable {
    func search(_ query: WallpaperQuery, page: Int) async throws -> WallpaperPage
}

actor WallhavenWallpaperSource: WallpaperSource {
    private var nextRequest = ContinuousClock.now
    private var blockedUntil = Date.distantPast

    func search(_ query: WallpaperQuery, page: Int) async throws -> WallpaperPage {
        let delay = max(0, blockedUntil.timeIntervalSinceNow)
        if delay > 0 { throw WallpaperFailure.rateLimited(delay) }
        let slot = max(nextRequest, .now)
        nextRequest = slot.advanced(by: .seconds(2))
        try await ContinuousClock().sleep(until: slot)
        try Task.checkCancellation()
        var components = URLComponents(string: "https://wallhaven.cc/api/v1/search")!
        var items = [URLQueryItem(name: "q", value: String(query.keywords.prefix(200))),
                     URLQueryItem(name: "purity", value: "100"),
                     URLQueryItem(name: "categories", value: query.categories),
                     URLQueryItem(name: "sorting", value: query.sorting),
                     URLQueryItem(name: "topRange", value: "1M"),
                     URLQueryItem(name: "page", value: String(max(1, min(100, page))))]
        if query.minimumWidth > 0, query.minimumHeight > 0 {
            items.append(URLQueryItem(name: "atleast", value: "\(query.minimumWidth)x\(query.minimumHeight)"))
        }
        components.queryItems = items
        do {
            let data = try await WallpaperHTTP(limit: 2 * 1_024 * 1_024).fetch(components.url!)
            return try Self.decode(data, query: query)
        } catch WallpaperFailure.rateLimited(let seconds) {
            blockedUntil = Date().addingTimeInterval(seconds)
            throw WallpaperFailure.rateLimited(seconds)
        }
    }

    static func decode(_ data: Data, query: WallpaperQuery) throws -> WallpaperPage {
        struct Response: Decodable {
            struct Item: Decodable {
                struct Thumbs: Decodable { let small: URL; let large: URL? }
                struct Uploader: Decodable { let username: String }
                let id: String
                let url: URL
                let path: URL
                let purity: String
                let dimension_x: Int
                let dimension_y: Int
                let thumbs: Thumbs
                let source: String?
                let uploader: Uploader?
            }
            struct Meta: Decodable { let current_page: Int; let last_page: Int }
            let data: [Item]
            let meta: Meta
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let assets = response.data.prefix(24).compactMap { item -> WallpaperAsset? in
            guard item.purity == "sfw", WallpaperHTTP.allows(item.path), WallpaperHTTP.allows(item.thumbs.small),
                  item.dimension_x > 0, item.dimension_y > 0,
                  item.dimension_x >= query.minimumWidth, item.dimension_y >= query.minimumHeight,
                  (query.orientation != "landscape" || item.dimension_x >= item.dimension_y),
                  (query.orientation != "portrait" || item.dimension_y >= item.dimension_x),
                  item.id.range(of: "^[a-z0-9]{6}$", options: .regularExpression) != nil else { return nil }
            return WallpaperAsset(id: "wallhaven.\(item.id)", title: "Wallhaven · \(item.id)",
                                  remoteURL: item.path, thumbnailURL: item.thumbs.large.flatMap { WallpaperHTTP.allows($0) ? $0 : nil } ?? item.thumbs.small,
                                  pageURL: item.url, sourceURL: item.source.flatMap(URL.init(string:)),
                                  uploader: item.uploader?.username, width: item.dimension_x,
                                  height: item.dimension_y, queryID: query.identity)
        }
        return WallpaperPage(assets: assets, page: response.meta.current_page,
                             lastPage: min(100, response.meta.last_page))
    }
}
