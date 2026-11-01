# dmgbuild settings for the release DMG; used by scripts/make-dmg.sh.
#   dmgbuild -s scripts/dmg-settings.py -D app=build/Polylocal.app -D root=. Polylocal out.dmg
# Icon positions must match scripts/make-dmg-background.swift.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
root = defines["root"]  # noqa: F821
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(root, "Resources/AppIcon.icns")  # volume icon

background = os.path.join(root, "Resources/dmg-background.png")  # @2x is picked up automatically
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {app_name: (170, 200), "Applications": (490, 200)}
hide_extension = [app_name]
