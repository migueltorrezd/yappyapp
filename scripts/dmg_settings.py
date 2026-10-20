# dmgbuild settings for the YappYapp installer window. Invoked by
# scripts/create_dmg.sh; paths arrive via -D defines. Headless: writes the
# .DS_Store directly, no Finder scripting, deterministic in CI.
import os.path

app = defines.get("app")            # noqa: F821  (dmgbuild injects `defines`)
staging = defines.get("staging")    # noqa: F821
background_path = defines.get("background")  # noqa: F821

format = "UDZO"
volume_name = "YappYapp"

files = [
    app,
    os.path.join(staging, "FIRST-OPEN.txt"),
    os.path.join(staging, "GATEKEEPER.md"),
]
symlinks = {"Applications": "/Applications"}

icon = defines.get("icon")  # noqa: F821  (volume icon = the pixel cat)

background = background_path
window_rect = ((200, 120), (660, 460))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 100
text_size = 12
# The docs live below the 460px window fold: the installer window shows only
# app -> Applications, and scrolling down reveals the help files when needed.
icon_locations = {
    "YappYapp.app": (140, 250),
    "Applications": (520, 250),
    "FIRST-OPEN.txt": (240, 600),
    "GATEKEEPER.md": (420, 600),
    ".background.tiff": (330, 750),
}
