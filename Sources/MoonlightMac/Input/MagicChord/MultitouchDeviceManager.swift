//
//  MultitouchDeviceManager.swift
//  MoonlightMac
//

import Foundation
import Combine
import IOKit

public protocol MultitouchDeviceManagerDelegate: AnyObject, Sendable {
    func multitouchDeviceDidUpdateTouches(_ touches: [SurfaceTouch], timestamp: Double)
}

public final class MultitouchDeviceManager: ObservableObject, @unchecked Sendable {
    public static let shared = MultitouchDeviceManager()

    @Published public private(set) var isMagicMouseConnected: Bool = false
    @Published public private(set) var connectedMouseCount: Int = 0

    public weak var delegate: MultitouchDeviceManagerDelegate?

    private typealias MTDeviceRef = UnsafeMutableRawPointer
    private typealias MTContactCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias MTCreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias MTRegisterFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    private typealias MTUnregisterFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    private typealias MTStartFn = @convention(c) (MTDeviceRef, Int32) -> Int32
    private typealias MTStopFn = @convention(c) (MTDeviceRef) -> Int32
    private typealias MTBoolFn = @convention(c) (MTDeviceRef) -> Bool
    private typealias MTFamilyFn = @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>) -> Int32
    private typealias MTDimsFn = @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

    private struct MTPointRaw { var x: Float; var y: Float }
    private struct MTReadoutRaw { var position: MTPointRaw; var velocity: MTPointRaw }
    private struct MTTouchRaw {
        var frame: Int32
        var timestamp: Double
        var identifier: Int32
        var state: Int32
        var fingerID: Int32
        var handID: Int32
        var normalized: MTReadoutRaw
        var size: Float
        var zero1: Int32
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var absolute: MTReadoutRaw
        var zero2: Int32
        var zero3: Int32
        var density: Float
    }

    private let mtLibrary: UnsafeMutableRawPointer?
    private let mtCreateList: MTCreateListFn?
    private let mtRegister: MTRegisterFn?
    private let mtUnregister: MTUnregisterFn?
    private let mtStart: MTStartFn?
    private let mtStop: MTStopFn?
    private let mtIsBuiltIn: MTBoolFn?
    private let mtGetFamilyID: MTFamilyFn?
    private let mtGetDimensions: MTDimsFn?

    private var activeDevices: [MTDeviceRef] = []
    private var retiredLists: [CFMutableArray] = []
    private var currentList: CFMutableArray?
    private var activeRequesters = Set<String>()
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var hotplugTimer: Timer?

    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var latestTouches: [SurfaceTouch] = []

    nonisolated(unsafe) fileprivate static weak var sharedCallbackInstance: MultitouchDeviceManager?

    public init() {
        lock.initialize(to: os_unfair_lock())

        let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        self.mtLibrary = handle

        func loadSymbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: type)
        }

        self.mtCreateList = loadSymbol("MTDeviceCreateList", as: MTCreateListFn.self)
        self.mtRegister = loadSymbol("MTRegisterContactFrameCallback", as: MTRegisterFn.self)
        self.mtUnregister = loadSymbol("MTUnregisterContactFrameCallback", as: MTUnregisterFn.self)
        self.mtStart = loadSymbol("MTDeviceStart", as: MTStartFn.self)
        self.mtStop = loadSymbol("MTDeviceStop", as: MTStopFn.self)
        self.mtIsBuiltIn = loadSymbol("MTDeviceIsBuiltIn", as: MTBoolFn.self)
        self.mtGetFamilyID = loadSymbol("MTDeviceGetFamilyID", as: MTFamilyFn.self)
        self.mtGetDimensions = loadSymbol("MTDeviceGetSensorSurfaceDimensions", as: MTDimsFn.self)

        MultitouchDeviceManager.sharedCallbackInstance = self
        checkConnectionStatusSync()
    }

    deinit {
        stopAll()
        lock.deallocate()
    }

    public var isAvailable: Bool {
        return mtCreateList != nil && mtRegister != nil && mtStart != nil
    }

    // MARK: - Requester Management (Streaming vs Settings Preview)

    public func start(requester: String) {
        os_unfair_lock_lock(lock)
        activeRequesters.insert(requester)
        let shouldStart = (activeDevices.isEmpty)
        os_unfair_lock_unlock(lock)

        if shouldStart {
            refreshDevices()
            startHotplugMonitoring()
        }
    }

    public func stop(requester: String) {
        os_unfair_lock_lock(lock)
        activeRequesters.remove(requester)
        let shouldStop = activeRequesters.isEmpty
        os_unfair_lock_unlock(lock)

        if shouldStop {
            stopAll()
        }
    }

    public func getLatestTouches() -> [SurfaceTouch] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return latestTouches
    }

    // MARK: - Device Management

    public func refreshDevices() {
        guard isAvailable, let mtCreateList, let mtRegister, let mtStart else { return }

        detachAllDevices()

        guard let listRef = mtCreateList() else {
            DispatchQueue.main.async {
                self.isMagicMouseConnected = false
                self.connectedMouseCount = 0
            }
            return
        }

        let list = listRef.takeRetainedValue()
        currentList = list
        let count = CFArrayGetCount(list)

        var matchedMice: [MTDeviceRef] = []

        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            if isMagicMouseDevice(dev) {
                matchedMice.append(dev)
                mtRegister(dev, globalTouchCallback)
                _ = mtStart(dev, 0)
            }
        }

        self.activeDevices = matchedMice
        let hasMice = !matchedMice.isEmpty
        let mouseCount = matchedMice.count

        DispatchQueue.main.async {
            self.isMagicMouseConnected = hasMice
            self.connectedMouseCount = mouseCount
        }
    }

    private func checkConnectionStatusSync() {
        guard isAvailable, let mtCreateList else { return }
        guard let listRef = mtCreateList() else { return }
        let list = listRef.takeRetainedValue()
        let count = CFArrayGetCount(list)
        var countFound = 0
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            if isMagicMouseDevice(UnsafeMutableRawPointer(mutating: raw)) {
                countFound += 1
            }
        }
        DispatchQueue.main.async {
            self.isMagicMouseConnected = (countFound > 0)
            self.connectedMouseCount = countFound
        }
    }

    private func isMagicMouseDevice(_ device: MTDeviceRef) -> Bool {
        var family: Int32 = 0
        _ = mtGetFamilyID?(device, &family)
        // Family IDs 112 (Magic Mouse 1 & 2) and 113 (Magic Mouse USB-C)
        if family == 112 || family == 113 { return true }
        if mtIsBuiltIn?(device) == true { return false }

        var width: Int32 = 0, height: Int32 = 0
        _ = mtGetDimensions?(device, &width, &height)
        // Magic Mouse sensor surface is vertically oriented (height > width), trackpads are wide
        return height > width && width > 0
    }

    private func detachAllDevices() {
        for device in activeDevices {
            mtUnregister?(device, globalTouchCallback)
            _ = mtStop?(device)
        }
        activeDevices.removeAll()
        if let current = currentList {
            retiredLists.append(current)
            currentList = nil
        }
    }

    private func stopAll() {
        detachAllDevices()
        stopHotplugMonitoring()

        os_unfair_lock_lock(lock)
        latestTouches.removeAll()
        os_unfair_lock_unlock(lock)

        DispatchQueue.main.async {
            self.isMagicMouseConnected = false
            self.connectedMouseCount = 0
        }
    }

    // MARK: - Hotplug Notifications

    private func startHotplugMonitoring() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let callback: IOServiceMatchingCallback = { _, iterator in
            while case let service = IOIteratorNext(iterator), service != 0 {
                IOObjectRelease(service)
            }
            MultitouchDeviceManager.sharedCallbackInstance?.refreshDevices()
        }

        for notificationType in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let matching = IOServiceMatching("AppleMultitouchDevice")
            let kr = IOServiceAddMatchingNotification(port, notificationType, matching, callback, nil, &iterator)
            if kr == KERN_SUCCESS {
                while case let service = IOIteratorNext(iterator), service != 0 {
                    IOObjectRelease(service)
                }
                iterators.append(iterator)
            }
        }
    }

    private func stopHotplugMonitoring() {
        for it in iterators {
            IOObjectRelease(it)
        }
        iterators.removeAll()
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    // MARK: - Low-Latency Touch Dispatch

    fileprivate func handleRawTouches(_ rawContacts: UnsafeMutableRawPointer?, count: Int, timestamp: Double) {
        var parsedTouches: [SurfaceTouch] = []

        if let rawContacts, count > 0 {
            let touches = rawContacts.bindMemory(to: MTTouchRaw.self, capacity: count)
            parsedTouches.reserveCapacity(count)
            for i in 0..<count {
                let t = touches[i]
                parsedTouches.append(SurfaceTouch(
                    id: t.identifier,
                    x: Double(t.normalized.position.x),
                    y: Double(t.normalized.position.y),
                    state: t.state,
                    timestamp: timestamp
                ))
            }
        }

        os_unfair_lock_lock(lock)
        self.latestTouches = parsedTouches
        os_unfair_lock_unlock(lock)

        delegate?.multitouchDeviceDidUpdateTouches(parsedTouches, timestamp: timestamp)
    }
}

// Global C callback function for MultitouchSupport
private func globalTouchCallback(device: UnsafeMutableRawPointer?, touches: UnsafeMutableRawPointer?, numTouches: Int32, timestamp: Double, frame: Int32) -> Int32 {
    if let manager = MultitouchDeviceManager.sharedCallbackInstance {
        manager.handleRawTouches(touches, count: Int(numTouches), timestamp: timestamp)
    }
    return 0
}
