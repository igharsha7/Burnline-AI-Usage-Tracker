//
//  AboutView.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

import AppKit
import SwiftUI

/// Burnline's Appropriate Legal Notices, which the GPL requires an
/// interactive program to show: copyright, licence, no warranty, the source,
/// and the attribution NOTICE's Section 7(b) term requires to be reachable
/// from the interface. Shown in Settings and in its own window, reached from
/// the app menu and the menu bar. A licence obligation: never behind a flag.
public struct AboutView: View {
    @Environment(UpdateModel.self) private var updates: UpdateModel?

    public init() {}

    /// The attribution exactly as NOTICE words it. It must not be altered.
    static let attribution = """
        Burnline
        Originally created by Challapalli Harshavardhan Reddy
        Source: https://github.com/igharsha7/Burnline-AI-Usage-Tracker
        """
    static let source = URL(string: "https://github.com/igharsha7/Burnline-AI-Usage-Tracker")!
    static let license = URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!

    /// Libraries, the font and the animation built into Burnline, each with
    /// the licence file shipped beside the app, as their licences require.
    static let libraries: [(name: String, license: String, file: String)] = [
        ("GRDB.swift", "MIT License", "GRDB"),
        ("Zstandard", "BSD License", "zstd"),
        ("Lottie", "Apache License 2.0", "Lottie"),
        ("Sparkle", "MIT License", "Sparkle"),
        ("Silkscreen font", "SIL Open Font License 1.1", "Silkscreen"),
        ("Animated Noto Emoji fire, by Google", "CC BY 4.0", "NotoFire"),
    ]

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Image(nsImage: AboutView.icon).resizable().frame(width: 96, height: 96)
                    Text("Burnline").font(.title.weight(.semibold))
                    Text("Version \(build.fullVersion)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if build.isNightly { NightlyBadge(build: build) }
                    Text("AI coding usage, limits, and cost in one place.").foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    Text("Copyright © 2026 Challapalli Harshavardhan Reddy")
                    Text("Free software under the GNU Affero General Public License, version 3 or later, with an "
                         + "attribution term under its Section 7(b). It comes with absolutely no warranty.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Link("Licence", destination: Self.license)
                        Link("Source Code", destination: Self.source)
                    }
                    .padding(.top, 4)
                }
                .font(.callout)

                Text(Self.attribution)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Attribution: Burnline, originally created by Challapalli Harshavardhan Reddy")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Third-party software").font(.headline)
                    ForEach(Self.libraries, id: \.name) { library in
                        DisclosureGroup("\(library.name) · \(library.license)") {
                            Text(Self.text(of: library.file))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private var build: BuildInfo { updates?.build ?? .main() }

    /// This build's icon from the asset catalog, the nightly one in a
    /// nightly. The system's own copy comes through Launch Services, which
    /// shows a placeholder for an unregistered build.
    public static var icon: NSImage {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String ?? "AppIcon"
        return NSImage(named: name) ?? NSApp.applicationIconImage
    }

    /// A shipped licence file, wherever the build placed it in the bundle.
    static func text(of file: String) -> String {
        let url = Bundle.main.url(forResource: file, withExtension: "txt")
            ?? Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: "Acknowledgements")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "This build is missing the licence file \(file).txt."
    }
}

/// The app menu's About item, opening Burnline's own About window, which
/// carries the notices the standard panel has no room for.
public struct AboutCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Burnline") { openWindow(id: SceneID.about) }
        }
    }
}
