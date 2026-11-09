import
  std/[os, unicode],
  chroma, pixie, silky,
  common

const
  Background* = rgbx(34, 34, 34, 255)
  Ink* = rgbx(255, 255, 255, 255)
  Muted* = rgbx(85, 85, 85, 255)
  Black* = rgbx(0, 0, 0, 255)
  Teal* = rgbx(0, 128, 128, 255)
  PanelFill* = rgbx(249, 249, 249, 255)
  ShadowOffset* = 4.0'f
  Gold* = rgbx(244, 210, 128, 255)
  Grid* = rgbx(36, 40, 46, 255)
  Fog* = rgbx(57, 57, 57, 255)
  PlainColor* = rgbx(230, 230, 230, 255)
  CityColor* = rgbx(128, 128, 128, 255)
  MountainColor* = rgbx(187, 187, 187, 255)
  # A 60% black overlay makes white cells #666666 and dims player colors.
  EliminatedOverlay* = rgbx(0, 0, 0, 153)
  PlayerColors*: array[MaxPlayers, ColorRGBX] = [
    rgbx(255, 0, 0, 255),
    rgbx(39, 146, 255, 255),
    rgbx(0, 128, 0, 255),
    rgbx(0, 128, 128, 255),
    rgbx(250, 140, 1, 255),
    rgbx(240, 50, 230, 255),
    rgbx(128, 0, 128, 255),
    rgbx(155, 1, 1, 255),
    rgbx(179, 172, 50, 255),
    rgbx(154, 94, 36, 255)
  ]
  PatchWidth = 1

proc addTheme*(builder: AtlasBuilder, assets: string) =
  ## Builds square panel and button skins with the shared game typography.
  for (name, fill) in [
    ("window.9patch", PanelFill),
    ("button.9patch", Teal),
    ("button.hover.9patch", rgbx(0, 110, 110, 255)),
    ("button.down.9patch", rgbx(0, 85, 85, 255)),
    ("button.disabled.9patch", rgbx(211, 211, 211, 255)),
    ("button.error.9patch", PlayerColors[0])
  ]:
    let image = newImage(8, 8)
    image.fill(fill)
    if not builder.addImage(name, image):
      raise newException(GeneralsError, "Cannot fit UI skin: " & name)
  for (name, file, size) in [
    ("Title", "Quicksand-Bold.ttf", 54.0'f),
    ("H1", "Quicksand-Bold.ttf", 30.0'f),
    ("OutcomeTitle", "Quicksand-Bold.ttf", 64.0'f),
    ("OutcomeDetail", "Quicksand-Regular.ttf", 28.0'f),
    ("OutcomeButton", "Quicksand-Regular.ttf", 36.0'f),
    ("OutcomeExit", "Quicksand-Regular.ttf", 48.0'f),
    ("Close", "Quicksand-Regular.ttf", 32.0'f),
    ("Default", "Quicksand-Regular.ttf", 18.0'f),
    ("Turn", "Quicksand-Regular.ttf", 18.0'f),
    ("Timestamp", "Quicksand-Regular.ttf", 12.0'f),
    ("Bold", "Quicksand-Bold.ttf", 18.0'f),
    ("Hud", "Quicksand-Regular.ttf", 15.0'f),
    ("Small", "Quicksand-Regular.ttf", 12.0'f),
    ("Mono", "OverpassMono-Regular.ttf", 18.0'f),
    ("Board", "Quicksand-Medium.ttf", 18.0'f),
    ("Board24", "Quicksand-Medium.ttf", 24.0'f),
    ("Board32", "Quicksand-Medium.ttf", 32.0'f),
    ("Board48", "Quicksand-Medium.ttf", 48.0'f)
  ]:
    builder.addFont(assets / "fonts" / file, name, size)
  let typeface = readTypeface(assets / "fonts/Quicksand-Regular.ttf")
  var glyphs: seq[string]
  for code in 32 .. 0x2fff:
    let rune = Rune(code)
    if typeface.hasGlyph(rune):
      glyphs.add(rune.toUTF8())
  for (name, file, size) in [
    ("Chat", "Quicksand-Regular.ttf", 16.0'f),
    ("Event", "Quicksand-Bold.ttf", 16.0'f),
    ("Score", "Quicksand-Regular.ttf", 18.0'f),
    ("OutcomeName", "Quicksand-Bold.ttf", 28.0'f)
  ]:
    builder.addFont(assets / "fonts" / file, name, size, glyphs)

proc applyTheme*(sk: Silky) =
  ## Applies shared skin measurements and legible widget interaction colors.
  sk.theme.windowPatch = PatchWidth
  sk.theme.buttonPatch = PatchWidth
  sk.theme.defaultTextColor = Ink
  sk.theme.disabledTextColor = Muted
  sk.theme.errorTextColor = Ink
  sk.theme.textColor = Black
  sk.theme.textH1Color = Black
