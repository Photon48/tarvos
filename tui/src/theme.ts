export const theme = {
  // Brand
  accent:    "#D75FAF",   // gum pink (was TC_ACCENT  \033[38;5;212m)
  purple:    "#5F00AF",   // deep purple (was TC_PURPLE \033[38;5;57m)

  // Neutrals
  muted:     "#585858",   // dark gray (TC_MUTED)
  subtle:    "#6C6C6C",   // medium gray (TC_SUBTLE)
  normal:    "#D0D0D0",   // near-white body text (TC_NORMAL)

  // Semantic
  success:   "#5FD700",   // bright green (TC_SUCCESS)
  warning:   "#FFAF00",   // orange (TC_WARNING)
  error:     "#FF0000",   // bright red (TC_ERROR)
  info:      "#5FAFFF",   // light blue (TC_INFO)

  // Backgrounds
  panelBg:   "#303030",   // panel background (TC_PANEL_BG)
  selBg:     "#444444",   // selected row highlight (TC_SEL_BG)
  headerBg:  "#5F00AF",   // header background (TC_HEADER_BG)

  // Owl mascot colors
  owl: {
    idle:    "#5FAFFF",   // cool blue
    working: "#FFAF00",   // amber
    done:    "#5FD700",   // bright green
    error:   "#FF0000",   // red
  },
}

export const statusIcons: Record<string, string> = {
  running:     "◉",
  done:        "✓",
  stopped:     "◌",
  failed:      "✗",
  initialized: "○",
}

export const statusColors: Record<string, string> = {
  running:     theme.accent,
  done:        theme.success,
  stopped:     theme.muted,
  failed:      theme.error,
  initialized: theme.info,
}

export const BRAILLE_SPINNER = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
