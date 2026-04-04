library(hexSticker)
library(sysfonts)
library(showtext)

font_add_google("Montserrat", "montserrat")
showtext_auto()

sticker(
  subplot = "logo/abalone.png",
  package = "irid",
  p_size = 26,
  p_color = "#E0F2F1",
  p_family = "montserrat",
  p_y = 0.51,
  s_x = 1.04,
  s_y = 1.2,
  s_width = 0.65,
  h_fill = "#24313a",
  h_color = "#A8DADC",
  dpi = 300,
  filename = "man/figures/logo.png"
)
