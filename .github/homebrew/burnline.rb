# burnline.rb
# Burnline
#
# Copyright (C) 2026 Challapalli Harshavardhan Reddy
# Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
#
# The Homebrew cask, as published to igharsha7/homebrew-tap. The release
# workflow fills in the version and checksum of each stable release and
# pushes it there; edit it here, never in the tap.

cask "burnline" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://github.com/igharsha7/Burnline-AI-Usage-Tracker/releases/download/v#{version}/Burnline-#{version}.dmg"
  name "Burnline"
  desc "Menu bar dashboard for AI coding usage, plan limits and API-price cost"
  homepage "https://github.com/igharsha7/Burnline-AI-Usage-Tracker"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Burnline updates itself through Sparkle.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Burnline.app"

  zap trash: [
    "~/Library/Application Support/Burnline",
    "~/Library/Caches/io.github.igharsha7.Burnline",
    "~/Library/HTTPStorages/io.github.igharsha7.Burnline",
    "~/Library/Preferences/io.github.igharsha7.Burnline.plist",
    "~/Library/Saved Application State/io.github.igharsha7.Burnline.savedState",
  ]

  caveats <<~EOS
    Burnline is not notarized (that needs Apple's $99-a-year developer program,
    and Burnline is free), so macOS asks once, the first time it opens:

      1. Open Burnline. When macOS says it cannot verify the developer, choose Done.
      2. Open System Settings, then Privacy & Security, and scroll to Security.
      3. Choose Open Anyway beside Burnline, then confirm with your password or Touch ID.

    This is needed once. Updates install from within Burnline and open straight away.
  EOS
end
