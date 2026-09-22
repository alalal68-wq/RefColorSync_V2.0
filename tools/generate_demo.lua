-- tools/generate_demo.lua: creates the README Auto-Paint animation in Aseprite.

local realTimer = Timer
local timers = {}
Timer = function(spec)
  local timer = { ontick = spec.ontick, interval = spec.interval, isRunning = false }
  function timer:start() self.isRunning = true end
  function timer:stop() self.isRunning = false end
  timers[#timers + 1] = timer
  return timer
end

local autopaint = dofile('../src/autopaint.lua')

local width = 48
local height = 40
local gap = 10
local margin = 2
local outputWidth = margin * 2 + width * 2 + gap
local outputHeight = margin * 2 + height

local function rgba(r, g, b, a)
  return app.pixelColor.rgba(r, g, b, a or 255)
end

local transparent = rgba(0, 0, 0, 0)
local work = Sprite(width, height, ColorMode.RGB)
local target = work.layers[1]
target.name = "Target"
if target:cel(1) then work:deleteCel(target:cel(1)) end

local reference = work:newLayer()
reference.name = "Reference"
local source = Image(work.spec)
source:clear(transparent)

local sky = {
  rgba(48, 40, 102), rgba(65, 49, 126), rgba(91, 58, 135),
  rgba(139, 70, 131), rgba(194, 86, 117), rgba(239, 122, 95)
}
for y = 2, 25 do
  local band = math.min(#sky, math.floor((y - 2) / 4) + 1)
  for x = 2, 45 do source:drawPixel(x, y, sky[band]) end
end

local sunOuter = rgba(255, 183, 89)
local sunInner = rgba(255, 225, 130)
for y = 6, 19 do
  for x = 28, 41 do
    local dx = x - 34.5
    local dy = y - 12.5
    local distance = dx * dx + dy * dy
    if distance <= 42 then source:drawPixel(x, y, distance <= 22 and sunInner or sunOuter) end
  end
end

for x = 2, 45 do
  local mountain = 27 - math.floor(math.abs(x - 14) * 0.45)
  local mountain2 = 29 - math.floor(math.abs(x - 34) * 0.35)
  local top = math.max(18, math.min(mountain, mountain2))
  for y = top, 30 do source:drawPixel(x, y, rgba(50, 42, 83)) end
  for y = 31, 37 do
    local checker = ((x + y) % 3 == 0)
    source:drawPixel(x, y, checker and rgba(30, 42, 67) or rgba(25, 33, 55))
  end
end

for _, star in ipairs({ {7, 7}, {13, 11}, {20, 6}, {24, 15}, {42, 4} }) do
  source:drawPixel(star[1], star[2], rgba(255, 236, 185))
end

work:newCel(reference, 1, source, Point(0, 0))

-- A few hand-drawn foreground pixels demonstrate that existing art is preserved.
local manual = Image(work.spec)
manual:clear(transparent)
local ink = rgba(14, 19, 34)
for x = 2, 45 do
  manual:drawPixel(x, 37, ink)
end
for y = 25, 36 do
  manual:drawPixel(10, y, ink)
end
for x = 7, 13 do manual:drawPixel(x, 25, ink) end
manual:drawPixel(8, 24, ink)
manual:drawPixel(12, 24, ink)
work:newCel(target, 1, manual, Point(0, 0))

app.activeSprite = work
app.activeLayer = target
app.activeFrame = work.frames[1]

local frames = {}
local function capture()
  local image = Image(ImageSpec{
    width = outputWidth,
    height = outputHeight,
    colorMode = ColorMode.RGB
  })

  local checkerA = rgba(38, 41, 50)
  local checkerB = rgba(51, 55, 66)
  for y = 0, outputHeight - 1 do
    for x = 0, outputWidth - 1 do
      local color = (math.floor(x / 4) + math.floor(y / 4)) % 2 == 0 and checkerA or checkerB
      image:drawPixel(x, y, color)
    end
  end

  image:drawImage(source, Point(margin, margin))
  local targetCel = target:cel(1)
  if targetCel then
    image:drawImage(targetCel.image, Point(
      margin + width + gap + targetCel.position.x,
      margin + targetCel.position.y))
  end

  local arrowX = margin + width + 2
  local arrowColor = rgba(222, 226, 235)
  local centerY = math.floor(outputHeight / 2)
  for x = arrowX, arrowX + 4 do image:drawPixel(x, centerY, arrowColor) end
  image:drawPixel(arrowX + 3, centerY - 1, arrowColor)
  image:drawPixel(arrowX + 4, centerY - 2, arrowColor)
  image:drawPixel(arrowX + 3, centerY + 1, arrowColor)
  image:drawPixel(arrowX + 4, centerY + 2, arrowColor)

  frames[#frames + 1] = image
end

capture()
local ok, err = autopaint.start({
  referenceLayerName = "Reference",
  sampleFromComposite = false,
  autopaintTicksPerSecond = 30,
  autopaintPixelsPerTick = 90,
  autopaintOrder = "random"
}, {})
if not ok then error(err) end

while autopaint.isRunning() do
  local before = autopaint.getStatus()
  timers[#timers].ontick()
  local after = autopaint.getStatus()
  if before and before.phase == "painting" then capture() end
  if after and after.phase == "painting" and before.phase ~= "painting" then capture() end
end
capture()

local output = Sprite(outputWidth, outputHeight, ColorMode.RGB)
local layer = output.layers[1]
layer.name = "Auto-Paint Demo"
if layer:cel(1) then output:deleteCel(layer:cel(1)) end

for index, image in ipairs(frames) do
  local frame
  if index == 1 then
    frame = output.frames[1]
  else
    frame = output:newEmptyFrame(index)
  end
  frame.duration = (index == 1 or index == #frames) and 0.8 or 0.09
  output:newCel(layer, frame, image, Point(0, 0))
end

output:saveAs('screenshots/07-autopaint-demo.gif')
output:close()
work:close()
Timer = realTimer
print(string.format("Generated Auto-Paint demo with %d frames", #frames))
