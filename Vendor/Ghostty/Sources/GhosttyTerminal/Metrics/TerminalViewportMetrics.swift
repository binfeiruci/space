//
//  TerminalViewportMetrics.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation

/// Scrollback rows and the currently visible range, measured from the top.
public struct TerminalScrollbarMetrics: Equatable, Sendable {
    public let total: UInt64
    public let offset: UInt64
    public let visible: UInt64

    public init(total: UInt64, offset: UInt64, visible: UInt64) {
        self.total = total
        self.visible = min(visible, total)
        self.offset = min(offset, total - self.visible)
    }

    public var maximumOffset: UInt64 { total - visible }
}

struct TerminalViewportMetrics: Equatable {
    var surfaceSize: TerminalGridMetrics
    var scale: Double
}
