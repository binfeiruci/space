//
//  TerminalViewRepresentable.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import SwiftUI
import AppKit

@MainActor
struct TerminalViewRepresentable {
    let context: TerminalViewState
    let controller: TerminalController
    let configuration: TerminalSurfaceOptions
    let focusBinding: TerminalFocusBinding?

    func configureView(_ view: TerminalView, initial: Bool) {
        if initial {
            view.delegate = context
        }

        if let currentController = view.controller, currentController === controller {
            // Keep the current surface.
        } else {
            view.controller = controller
        }

        if !view.configuration.isEquivalent(to: configuration) {
            view.configuration = configuration
        }
    }

    static func synchronizeFocus(_ view: TerminalView, with binding: TerminalFocusBinding?) {
        guard let binding else { return }

        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            if binding.isFocused {
                if window.firstResponder !== view {
                    window.makeFirstResponder(view)
                }
            } else if window.firstResponder === view {
                window.makeFirstResponder(nil)
            }
        }
    }
}

@MainActor
struct TerminalFocusBinding {
    private let read: () -> Bool
    private let write: (Bool) -> Void

    var isFocused: Bool {
        read()
    }

    func setFocused(_ focused: Bool) {
        write(focused)
    }

    static func bool(_ binding: FocusState<Bool>.Binding) -> TerminalFocusBinding {
        TerminalFocusBinding(
            read: { binding.wrappedValue },
            write: { binding.wrappedValue = $0 }
        )
    }

    static func optional<Value: Hashable>(
        _ binding: FocusState<Value?>.Binding,
        equals value: Value
    ) -> TerminalFocusBinding {
        TerminalFocusBinding(
            read: { binding.wrappedValue == value },
            write: { focused in
                binding.wrappedValue = focused ? value : nil
            }
        )
    }
}

@MainActor
extension TerminalFocusBinding? {
    func setFocused(_ focused: Bool) {
        guard let binding = self, binding.isFocused != focused else {
            return
        }
        binding.setFocused(focused)
    }
}
