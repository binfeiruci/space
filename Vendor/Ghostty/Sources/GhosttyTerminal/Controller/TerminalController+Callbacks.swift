//
//  TerminalController+Callbacks.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit
import AppKit

private enum TerminalCallbacks {
    static func wakeup(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let controller = Unmanaged<TerminalController>.fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            controller.handleWakeup()
        }
    }

    static func action(
        appPtr: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let appPtr else { return false }
        guard ghostty_app_userdata(appPtr) != nil else { return false }
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surfacePtr = target.target.surface else { return false }
        guard let bridgePtr = ghostty_surface_userdata(surfacePtr) else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(bridgePtr)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleAction(action)
        }

        return false
    }

    static func closeSurface(
        userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClose(processAlive: processAlive)
        }
    }

    static func writeClipboard(
        userdata _: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        contentsLen: Int,
        confirm _: Bool
    ) {
        guard contentsLen > 0, let contents else { return }

        var string: String?
        for index in 0..<contentsLen {
            let content = contents[index]
            guard String(cString: content.mime) == "text/plain",
                  let data = content.data else { continue }
            string = String(
                data: Data(bytes: data, count: content.len),
                encoding: .utf8
            )
            break
        }
        guard let string else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        opaquePtr: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let userdata else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        let string = NSPasteboard.general.string(forType: .string)
        var requestsPlainText = false
        if let mimes {
            for index in 0..<mimesLen {
                guard let mime = mimes[index] else { continue }
                if String(cString: mime) == "text/plain" {
                    requestsPlainText = true
                    break
                }
            }
        }

        guard (requestsPlainText && string != nil) || list else {
            TerminalDebugLog.log(.input, "clipboard paste read empty")
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        if let string, requestsPlainText {
            TerminalDebugLog.log(
                .input,
                "clipboard paste read bytes=\(string.utf8.count) lines=\(TerminalInputText.lineCount(in: string))"
            )
        }
        completeTextClipboardRequest(
            surface: surface,
            text: requestsPlainText ? string : nil,
            listTextAsAvailable: list && string != nil,
            opaquePtr: opaquePtr
        )
        TerminalDebugLog.log(.input, "clipboard paste complete")
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        confirmation: UnsafePointer<ghostty_clipboard_confirm_s>?,
        opaquePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return }

        guard let confirmation else {
            ghostty_surface_deny_clipboard_request(surface, opaquePtr)
            return
        }
        let value = confirmation.pointee
        var completion = ghostty_clipboard_complete_s(
            contents: value.contents,
            contents_len: value.contents_len,
            available: value.available,
            available_len: value.available_len,
            confirmed: true,
            remember: false
        )
        TerminalDebugLog.log(.input, "clipboard paste confirm request=\(request.rawValue)")
        ghostty_surface_complete_clipboard_request(surface, &completion, opaquePtr)
        TerminalDebugLog.log(.input, "clipboard paste confirmed")
    }

    private static func completeTextClipboardRequest(
        surface: ghostty_surface_t,
        text: String?,
        listTextAsAvailable: Bool,
        opaquePtr: UnsafeMutableRawPointer?
    ) {
        var bytes = Array((text ?? "").utf8)
        bytes.append(0)

        "text/plain".withCString { mime in
            bytes.withUnsafeBufferPointer { bytesBuffer in
                let content = ghostty_clipboard_content_s(
                    mime: mime,
                    data: UnsafeRawPointer(bytesBuffer.baseAddress!)
                        .assumingMemoryBound(to: CChar.self),
                    len: bytes.count - 1
                )
                let contents = text == nil ? [] : [content]
                let available: [UnsafePointer<CChar>?] = listTextAsAvailable ? [mime] : []
                contents.withUnsafeBufferPointer { contentsBuffer in
                    available.withUnsafeBufferPointer { availableBuffer in
                        var completion = ghostty_clipboard_complete_s(
                            contents: contentsBuffer.baseAddress,
                            contents_len: contentsBuffer.count,
                            available: availableBuffer.baseAddress,
                            available_len: availableBuffer.count,
                            confirmed: false,
                            remember: false
                        )
                        ghostty_surface_complete_clipboard_request(
                            surface,
                            &completion,
                            opaquePtr
                        )
                    }
                }
            }
        }
    }
}

func terminalControllerWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    TerminalCallbacks.wakeup(userdata: userdata)
}

func terminalControllerActionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    TerminalCallbacks.action(appPtr: appPtr, target: target, action: action)
}

func terminalControllerCloseSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    TerminalCallbacks.closeSurface(userdata: userdata, processAlive: processAlive)
}

func terminalControllerWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm: Bool
) {
    TerminalCallbacks.writeClipboard(
        userdata: userdata,
        clipboard: clipboard,
        contents: contents,
        contentsLen: contentsLen,
        confirm: confirm
    )
}

func terminalControllerReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    opaquePtr: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimesLen: Int,
    list: Bool
) -> ghostty_clipboard_read_result_e {
    TerminalCallbacks.readClipboard(
        userdata: userdata,
        clipboard: clipboard,
        opaquePtr: opaquePtr,
        mimes: mimes,
        mimesLen: mimesLen,
        list: list
    )
}

func terminalControllerConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    confirmation: UnsafePointer<ghostty_clipboard_confirm_s>?,
    opaquePtr: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    TerminalCallbacks.confirmReadClipboard(
        userdata: userdata,
        confirmation: confirmation,
        opaquePtr: opaquePtr,
        request: request
    )
}
