# dmgbuild settings for Brim.dmg: Brim.app and an Applications link on a background that explains
# the first open. Used by scripts/build-dmg.sh:
#   dmgbuild -s packaging/dmg/settings.py -D app=build/Brim.app "Brim" build/Brim.dmg
# Icon positions must match the arrow drawn by packaging/dmg/make-background.swift.
import os.path

application = defines.get("app", "build/Brim.app")  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = "packaging/AppIcon.icns"

background = "packaging/dmg/background.tiff"
window_rect = ((200, 140), (660, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 96
text_size = 13
icon_locations = {appname: (170, 175), "Applications": (490, 175)}
hide_extensions = [appname]
