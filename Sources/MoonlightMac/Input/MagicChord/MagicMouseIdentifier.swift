//
//  MagicMouseIdentifier.swift
//  MoonlightMac
//

import AppKit
import IOKit

public final class MagicMouseIdentifier: @unchecked Sendable {
    public static let shared = MagicMouseIdentifier()

    private typealias CGEventCopyIOHIDEventFunc = @convention(c) (CGEvent) -> Unmanaged<AnyObject>?
    private typealias IOHIDEventGetSenderIDFunc = @convention(c) (AnyObject) -> UInt64

    private let copyIOHIDEvent: CGEventCopyIOHIDEventFunc?
    private let getSenderID: IOHIDEventGetSenderIDFunc?

    private let cacheLock = os_unfair_lock_t.allocate(capacity: 1)
    private var senderCache: [UInt64: Bool] = [:]

    private init() {
        cacheLock.initialize(to: os_unfair_lock())
        let defaultHandle = dlopen(nil, RTLD_NOW)
        if let copyPtr = dlsym(defaultHandle, "CGEventCopyIOHIDEvent"),
           let senderPtr = dlsym(defaultHandle, "IOHIDEventGetSenderID") {
            self.copyIOHIDEvent = unsafeBitCast(copyPtr, to: CGEventCopyIOHIDEventFunc.self)
            self.getSenderID = unsafeBitCast(senderPtr, to: IOHIDEventGetSenderIDFunc.self)
        } else {
            self.copyIOHIDEvent = nil
            self.getSenderID = nil
        }
    }

    deinit {
        cacheLock.deallocate()
    }

    /// Determines whether the given event originated from an Apple Magic Mouse device.
    /// If coming from a Logitech mouse, trackball, built-in trackpad, or other peripheral, returns false.
    public func isMagicMouse(event: NSEvent) -> Bool {
        guard MultitouchDeviceManager.shared.isMagicMouseConnected else {
            return false
        }

        if let cgEvent = event.cgEvent,
           let copyIOHIDEvent,
           let getSenderID,
           let unmanagedHID = copyIOHIDEvent(cgEvent) {
            let hidEvent = unmanagedHID.takeRetainedValue()
            let senderID = getSenderID(hidEvent)
            if senderID != 0 {
                return isMagicMouse(senderID: senderID)
            }
        }

        // On an Apple Magic Mouse, it is physically impossible to press the mechanical switch
        // without touching the capacitive multi-touch surface. Conversely, clicking an external
        // mouse (Logitech, Razer, USB receiver) or trackpad means zero active touch contacts on the Magic Mouse.
        let touches = MultitouchDeviceManager.shared.getLatestTouches()
        return touches.contains(where: { $0.isTouching })
    }

    public func isMagicMouse(cgEvent: CGEvent) -> Bool {
        guard let copyIOHIDEvent, let getSenderID else { return false }
        guard let unmanagedHID = copyIOHIDEvent(cgEvent) else { return false }
        let hidEvent = unmanagedHID.takeRetainedValue()
        let senderID = getSenderID(hidEvent)
        guard senderID != 0 else { return false }
        return isMagicMouse(senderID: senderID)
    }

    public func isMagicMouse(senderID: UInt64) -> Bool {
        guard senderID != 0 else { return false }

        os_unfair_lock_lock(cacheLock)
        if let cached = senderCache[senderID] {
            os_unfair_lock_unlock(cacheLock)
            return cached
        }
        os_unfair_lock_unlock(cacheLock)

        let isMatch = checkRegistryForMagicMouse(senderID: senderID)

        os_unfair_lock_lock(cacheLock)
        senderCache[senderID] = isMatch
        os_unfair_lock_unlock(cacheLock)

        return isMatch
    }

    public func clearCache() {
        os_unfair_lock_lock(cacheLock)
        senderCache.removeAll()
        os_unfair_lock_unlock(cacheLock)
    }

    private func checkRegistryForMagicMouse(senderID: UInt64) -> Bool {
        let matching = IORegistryEntryIDMatching(senderID)
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return false }

        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(entry) }

        while current != 0 {
            if let name = IORegistryEntryCreateCFProperty(current, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                if name.localizedCaseInsensitiveContains("Magic Mouse") {
                    IOObjectRelease(current)
                    return true
                }
            }
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS {
                IOObjectRelease(current)
                current = parent
            } else {
                IOObjectRelease(current)
                break
            }
        }
        return false
    }
}
