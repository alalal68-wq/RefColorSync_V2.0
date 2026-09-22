-- tests/ui_smoke.lua: opens a real Auto-Paint dialog with a disposable fixture.

local config = dofile('../src/config.lua')
local watcher = dofile('../src/watcher.lua')
local autopaint = dofile('../src/autopaint.lua')
local autopaintUi = dofile('../src/autopaint_ui.lua')

local plugin = { preferences = {} }
config.init(plugin)
config.update({
  referenceLayerName = "Reference",
  sampleFromComposite = false,
  autopaintTicksPerSecond = 10,
  autopaintPixelsPerTick = 5,
  autopaintOrder = "random"
})

local sprite = Sprite(32, 32, ColorMode.RGB)
local target = sprite.layers[1]
target.name = "Auto-Paint Target"
if target:cel(1) then sprite:deleteCel(target:cel(1)) end

local reference = sprite:newLayer()
reference.name = "Reference"
local image = Image(sprite.spec)
image:clear()

for y = 2, 29 do
  for x = 2, 29 do
    local red = 50 + math.floor(x * 5)
    local green = 50 + math.floor(y * 5)
    local blue = 180 - math.floor((x + y) * 2)
    image:drawPixel(x, y, app.pixelColor.rgba(red, green, blue, 255))
  end
end
sprite:newCel(reference, 1, image, Point(0, 0))
reference.isVisible = false

local manual = Image(sprite.spec)
manual:clear()
local ink = app.pixelColor.rgba(20, 25, 35, 255)
for index = 5, 26 do
  manual:drawPixel(index, index, ink)
  manual:drawPixel(31 - index, index, ink)
end
sprite:newCel(target, 1, manual, Point(0, 0))

app.activeSprite = sprite
app.activeLayer = target
app.activeFrame = sprite.frames[1]
app.command.Zoom{ percentage = 800 }
autopaintUi.show(config, watcher, autopaint)
