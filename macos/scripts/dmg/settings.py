# settings.py
# Burnline
#
# Copyright (C) 2026 Challapalli Harshavardhan Reddy
# Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
"""dmgbuild's settings for Burnline's disk image: the app beside an
Applications link on the burn-line background, so installing is one drag.

build-release.sh passes `app` and `background` with `-D`. The window and the
icon centres match `Layout` in background.swift, which draws the fuse
between them.
"""

import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)

files = [app]
symlinks = {"Applications": "/Applications"}

background = defines["background"]  # noqa: F821
# The window's frame includes its title bar, so it is taller than the
# 440-point background by that much. Finder may add a path bar over the
# bottom, which the background leaves empty.
window_rect = ((200, 120), (660, 472))
icon_locations = {
    os.path.basename(app): (165, 172),
    "Applications": (495, 172),
}
icon_size = 112
text_size = 13

default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
show_sidebar = False

# LZFSE: smaller than zlib, and every macOS Burnline runs on reads it.
format = "ULFO"
