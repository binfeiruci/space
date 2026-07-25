//
//  TerminalView+Process.swift
//  libghostty-spm
//
//  Public read access to the pty's foreground process, exposed by the
//  AppKit `AppTerminalView` through the `TerminalView` typealias.
//

import Foundation

public extension TerminalView {
    /// PID of the pty's foreground process group (`tcgetpgrp(pty)`). When the
    /// user runs a program in the pty this is that program's pid, so hosts can
    /// correlate the surface with an external process list. Nil until the
    /// surface has a process.
    var foregroundPid: pid_t? {
        surface?.foregroundPid
    }

    /// Name of the pty's controlling tty (e.g. `/dev/ttys004`), or nil until
    /// the surface has a process.
    var ttyName: String? {
        surface?.ttyName
    }
}
