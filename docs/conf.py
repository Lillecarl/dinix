"""Sphinx configuration for the dinix documentation site.

MyST for Markdown and furo for the theme, the pair solid-kubernetes uses. The
source tree is assembled by docs/site.nix, not checked in: the guide is the
repository README, and the option page is rendered from options.nix itself.

The build runs with ``-W``, so a broken relative link fails it. That is why
``suppress_warnings`` is empty.
"""

from __future__ import annotations

project = "dinix"
copyright = "2026, Carl Andersson"
author = "Carl Andersson"

extensions = ["myst_parser"]

myst_enable_extensions = [
    "colon_fence",
    "deflist",
]

# The guide links its own headings, as GitHub renders them.
myst_heading_anchors = 3

exclude_patterns = ["_build"]

suppress_warnings = []

html_theme = "furo"
html_title = "dinix"

# The prose uses `--` as an em dash, and the option text is code. Neither
# should be prettified.
smartquotes = False