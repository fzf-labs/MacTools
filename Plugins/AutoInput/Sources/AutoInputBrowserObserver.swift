import AppKit
import ApplicationServices
import Foundation

@MainActor
final class AccessibilityAutoInputBrowserObserver: AutoInputBrowserObserving {
    var onContextChange: ((AutoInputBrowserContext) -> Void)?

    private let runLoop = AutoInputAccessibilityRunLoop()
    private let session = AutoInputBrowserSession()
    private let validity = AutoInputBrowserValidity()
    private var generation = 0
    private var application: AutoInputApplication?

    func observe(_ application: AutoInputApplication) {
        guard AutoInputBrowser.supports(application.bundleIdentifier),
              application.processIdentifier != nil else { stop(); return }
        if self.application != application {
            generation += 1
            self.application = application
        }
        let generation = generation
        validity.set(generation)
        let delivery: @MainActor @Sendable (AutoInputBrowserContext) -> Void = { [weak self] context in
            guard let self, self.generation == generation,
                  self.application == application else { return }
            self.onContextChange?(context)
        }
        runLoop.perform(priority: .foreground) { [session, validity] in
            guard validity.accepts(generation) else { return }
            session.observe(application, isCurrent: { validity.accepts(generation) }) { context in
                Task { @MainActor in delivery(context) }
            }
        }
    }

    func stop() {
        generation += 1
        validity.set(generation)
        application = nil
        runLoop.perform(priority: .foreground) { [session] in session.stop() }
    }

    deinit {
        validity.set(-1)
        let session = session
        runLoop.shutdown { session.stop() }
    }
}

private final class AutoInputBrowserValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    func set(_ generation: Int) {
        lock.withLock { self.generation = generation }
    }

    func accepts(_ generation: Int) -> Bool {
        lock.withLock { self.generation == generation }
    }
}

/// All AX handles, timers and mutable state are confined to the dedicated run loop.
private final class AutoInputBrowserSession: @unchecked Sendable {
    private var application: AutoInputApplication?
    private var applicationElement: AXUIElement?
    private var observer: AXObserver?
    private var observedWindow: AXUIElement?
    private var observedWebArea: AXUIElement?
    private var registrations: [(AXUIElement, CFString)] = []
    private var pendingRead: CFRunLoopTimer?
    private var fallbackTimer: CFRunLoopTimer?
    private var deliver: (@Sendable (AutoInputBrowserContext) -> Void)?
    private var previousContext: AutoInputBrowserContext?
    private var isCurrent: @Sendable () -> Bool = { false }

    func observe(
        _ application: AutoInputApplication,
        isCurrent: @escaping @Sendable () -> Bool,
        deliver: @escaping @Sendable (AutoInputBrowserContext) -> Void
    ) {
        if self.application != application {
            stop()
            self.application = application
            guard let pid = application.processIdentifier else { return }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.1)
            applicationElement = element
            var created: AXObserver?
            let result = AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                Unmanaged<AutoInputBrowserSession>.fromOpaque(context).takeUnretainedValue().scheduleRead()
            }, &created)
            if result == .success, let created {
                observer = created
                CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
                for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                             kAXWindowCreatedNotification] {
                    register(element, name as CFString)
                }
            }
            // Some browser navigations emit no AX notification. This fallback runs
            // only for the foreground supported browser while website rules are active.
            fallbackTimer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 2, 2, 0, 0) {
                [weak self] _ in self?.read()
            }
            if let fallbackTimer {
                CFRunLoopAddTimer(CFRunLoopGetCurrent(), fallbackTimer, .defaultMode)
            }
        }
        self.isCurrent = isCurrent
        self.deliver = deliver
        read()
    }

    func stop() {
        if let pendingRead { CFRunLoopTimerInvalidate(pendingRead) }
        if let fallbackTimer { CFRunLoopTimerInvalidate(fallbackTimer) }
        pendingRead = nil
        fallbackTimer = nil
        if let observer {
            for (element, name) in registrations {
                AXObserverRemoveNotification(observer, element, name)
            }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        registrations.removeAll()
        observer = nil
        observedWindow = nil
        observedWebArea = nil
        applicationElement = nil
        application = nil
        previousContext = nil
        deliver = nil
        isCurrent = { false }
    }

    private func register(_ element: AXUIElement, _ name: CFString) {
        guard let observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if AXObserverAddNotification(observer, element, name, context) == .success {
            registrations.append((element, name))
        }
    }

    private func scheduleRead() {
        guard pendingRead == nil else { return }
        pendingRead = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.12, 0, 0, 0) {
            [weak self] _ in
            self?.pendingRead = nil
            self?.read()
        }
        if let pendingRead { CFRunLoopAddTimer(CFRunLoopGetCurrent(), pendingRead, .defaultMode) }
    }

    private func read() {
        guard isCurrent(), let application, let pid = application.processIdentifier, let applicationElement else { return }
        var context = AutoInputBrowserContext(bundleIdentifier: application.bundleIdentifier, processIdentifier: pid)
        if !AXIsProcessTrusted() {
            context.permissionDenied = true
            publish(context)
            return
        }
        guard let window = element(attribute(kAXFocusedWindowAttribute, of: applicationElement)) else {
            publish(context)
            return
        }
        let focused = element(attribute(kAXFocusedUIElementAttribute, of: applicationElement))
        context.isAddressBarFocused = focused.map(isAddressBar) ?? false
        // Never match text being composed in the omnibox as a visited website.
        if !context.isAddressBarFocused {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
            let focusedArea = ancestorWebArea(focused, deadline: deadline)
            let area = focusedArea ?? webArea(in: window, deadline: deadline)
            let document = attribute(kAXDocumentAttribute, of: window)
            if let focusedArea, let address = attribute("AXURL", of: focusedArea) {
                context.url = validURL(address)
            } else if let address = rawURL(document), address.scheme != nil {
                context.url = validURL(document)
            } else {
                context.url = area.flatMap { validURL(attribute("AXURL", of: $0)) }
            }
            updateWindow(window, webArea: area)
        } else {
            updateWindow(window, webArea: nil)
        }
        publish(context)
    }

    private func updateWindow(_ window: AXUIElement, webArea: AXUIElement?) {
        guard (observedWindow.map({ !CFEqual($0, window) }) ?? true)
                || !sameElement(observedWebArea, webArea) else { return }
        if let observer {
            let retained = registrations.filter { entry in
                guard let applicationElement else { return false }
                if CFEqual(entry.0, applicationElement) { return true }
                AXObserverRemoveNotification(observer, entry.0, entry.1)
                return false
            }
            registrations = retained
        }
        observedWindow = window
        observedWebArea = webArea
        register(window, kAXTitleChangedNotification as CFString)
        register(window, kAXUIElementDestroyedNotification as CFString)
        if let webArea {
            register(webArea, kAXValueChangedNotification as CFString)
            register(webArea, "AXLoadComplete" as CFString)
        }
    }

    private func publish(_ context: AutoInputBrowserContext) {
        guard isCurrent(), previousContext != context else { return }
        previousContext = context
        deliver?(context)
    }

    private func ancestorWebArea(_ focused: AXUIElement?, deadline: ContinuousClock.Instant) -> AXUIElement? {
        var ancestor = focused
        for _ in 0..<12 {
            guard isCurrent(), let current = ancestor, ContinuousClock.now < deadline else { break }
            if attribute(kAXRoleAttribute, of: current) as? String == "AXWebArea" { return current }
            ancestor = element(attribute(kAXParentAttribute, of: current))
        }
        return nil
    }

    private func webArea(in window: AXUIElement, deadline: ContinuousClock.Instant) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        var found: AXUIElement?
        while isCurrent(), index < queue.count, index < 160, ContinuousClock.now < deadline {
            let (current, depth) = queue[index]
            index += 1
            if attribute("AXHidden", of: current) as? Bool == true { continue }
            if attribute(kAXRoleAttribute, of: current) as? String == "AXWebArea" {
                // Without a focused document or AXDocument, multiple web areas
                // can represent sidebars or split panes. Do not guess a website.
                guard found == nil else { return nil }
                found = current
                continue
            }
            guard depth < 8 else { continue }
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(current, kAXChildrenAttribute as CFString, &count) == .success else { continue }
            var children: CFArray?
            guard AXUIElementCopyAttributeValues(current, kAXChildrenAttribute as CFString, 0,
                                                min(count, 160 - queue.count), &children) == .success,
                  let values = children as? [AXUIElement] else { continue }
            queue.append(contentsOf: values.map { ($0, depth + 1) })
        }
        return index == queue.count ? found : nil
    }

    private func isAddressBar(_ element: AXUIElement) -> Bool {
        let identifiers = [kAXIdentifierAttribute, "AXDOMIdentifier"].compactMap {
            attribute($0, of: element) as? String
        }
        if identifiers.contains(where: {
            ["WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD", "urlbar-input", "commandBarTextField"].contains($0)
        }) { return true }
        let classes = attribute("AXDOMClassList", of: element) as? [String] ?? []
        return classes.contains { ["OmniboxViewViews", "UrlBar-UrlField", "AddressTextfieldView"].contains($0) }
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func rawURL(_ value: CFTypeRef?) -> URL? {
        (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    private func validURL(_ value: CFTypeRef?) -> URL? {
        guard let url = rawURL(value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.absoluteString.utf16.count <= 8192 else { return nil }
        return url
    }

    private func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): CFEqual(lhs, rhs)
        case (nil, nil): true
        default: false
        }
    }
}
