//
//  ClaudeLoginNote.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import BurnlineCore
import SwiftUI

/// Why Claude Code's login could not be read, with the way to allow it again,
/// for Settings and the Limits page. Nil when there is nothing to say.
///
/// Claude Code rewrites its login each time it renews it, and macOS then asks
/// again whether Burnline may read it. Burnline does not ask on its own
/// schedule, so the question waits here for the user.
struct ClaudeLoginNote {
    let message: String

    init?(status: ClaudeLoginAccess.Status?) {
        switch status {
        case .needsPermission:
            message = "Claude Code renewed its login, so macOS asks again before Burnline reads it. "
                + "Until then, quota comes through Claude Code and banked resets stay as last read."
        case .declined:
            message = "Burnline was not allowed to read Claude Code's login. "
                + "Quota comes through Claude Code and banked resets stay as last read."
        case .unknown, .allowed, .off, nil:
            return nil
        }
    }

    /// The note and its Allow button, which shows macOS's question.
    func allowing(_ allow: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(message, systemImage: "key")
                .font(.callout).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Allow…", action: allow)
                .help("macOS asks for your password, then Burnline reads Claude Code's login")
        }
    }
}
