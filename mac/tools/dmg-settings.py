# dmgbuild settings for the Mac download (used by mac/package.sh).
# Passed in with -D: app (path to Lan-Line.app), background (the 1x+2x TIFF).
# Window and icon positions match mac/tools/make-dmg-background.swift.
import os

application = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(application)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = [appname]

background = defines["background"]  # noqa: F821
# 428 = the 400 pt background plus Finder's title bar; a user's path bar covers the bottom 24 pt, so the
# background keeps its text above that line.
window_rect = ((200, 120), (640, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {appname: (165, 185), "Applications": (475, 185)}
