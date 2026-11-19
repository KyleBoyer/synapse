# dmgbuild settings: dmgbuild -s scripts/dmg/settings.py -D app=<Synapse.app> -D background=scripts/dmg/background.png Synapse out.dmg
# Icon positions match the arrow in make-background.swift (centers at 160,190 and 480,190 on a 640x400 window).
import os.path

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
# dmgbuild picks up background@2x.png beside it for Retina.
background = defines["background"]
icon_locations = {os.path.basename(app): (160, 190), "Applications": (480, 190)}
# The height includes the 32 pt title bar, so the content matches the 640x400 background.
window_rect = ((200, 160), (640, 432))
icon_size = 128
text_size = 13
format = "UDZO"
filesystem = "HFS+"
default_view = "icon-view"
show_icon_preview = False
