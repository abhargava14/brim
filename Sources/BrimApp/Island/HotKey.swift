import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (⌥Space) through Carbon's hot keys, which need no
/// Accessibility permission. If another app already owns the combination, registering fails quietly.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey), action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in hotKey.action() }
            return noErr
        }, 1, &spec, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x4252_494D), id: 1) // "BRIM"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}
