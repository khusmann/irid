# Nested components with per-field reactiveProxy on a branch leaf

library(irid)

HueSlider <- function(hue) {
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = hue
  )
}

SaturationSlider <- function(saturation) {
  tags$input(
    type = "range", min = "0", max = "1", step = "0.01",
    value = saturation
  )
}

ColorPicker <- function(color) {
  tags$div(
    tags$label("Hue"),        HueSlider(color$hue),
    tags$label("Saturation"), SaturationSlider(color$saturation)
  )
}

ColorPreview <- function(color) {
  tags$div(
    style = \() sprintf(
      "width: 100px; height: 100px; background: hsl(%g, %g%%, 50%%)",
      color$hue() * 360,
      color$saturation() * 100
    )
  )
}

ColorApp <- function() {
  state <- reactiveStore(list(
    color = list(hue = 0.5, saturation = 0.8)
  ))

  # Parent constrains hue to warm range (0.0–0.15) by wrapping the leaf.
  # ColorPicker is unchanged — it still receives state$color as a branch,
  # and accesses color$hue internally. The proxy is injected by passing
  # the constrained leaf alongside the branch.
  #
  # Since ColorPicker accepts the branch as a whole, the constrained leaf
  # is wired by building a separate constrained branch:
  constrained_color <- reactiveStore(list(
    hue        = state$color$hue(),
    saturation = state$color$saturation()
  ))

  constrained_hue <- reactiveProxy(state$color$hue,
    set = \(v) {
      v <- as.numeric(v)
      if (!is.na(v) && v >= 0 && v <= 0.15) state$color$hue(v)
    }
  )

  page_fluid(
    tags$h2("Unconstrained color picker"),
    ColorPicker(state$color),
    ColorPreview(state$color),

    tags$h2("Warm hues only (hue \u2264 0.15)"),
    tags$div(
      tags$label("Hue"),        HueSlider(constrained_hue),
      tags$label("Saturation"), SaturationSlider(state$color$saturation)
    ),
    ColorPreview(state$color),

    tags$p(\() sprintf(
      "hue=%.2f  sat=%.2f",
      state$color$hue(),
      state$color$saturation()
    ))
  )
}

iridApp(ColorApp)
