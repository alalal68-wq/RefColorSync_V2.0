-- tests/test_watcher.lua: watcher regression tests with real Aseprite image objects.

local realApp = app
local realTimer = Timer
local timers = {}

local function fakeTimer(spec)
  local timer = { interval = spec.interval, ontick = spec.ontick, isRunning = false }
  function timer:start() self.isRunning = true end
  function timer:stop() self.isRunning = false end
  timers[#timers + 1] = timer
  return timer
end

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual)), 2)
  end
end

local function assertTrue(value, message)
  if not value then error(message, 2) end
end

local sprite = Sprite(2, 1, ColorMode.RGB)
local target = sprite.layers[1]
target.name = "Target"
local reference = sprite:newLayer()
reference.name = "Reference"
local source = Image(sprite.spec)
source:clear()
local first = realApp.pixelColor.rgba(10, 20, 30, 255)
local second = realApp.pixelColor.rgba(40, 50, 60, 255)
source:drawPixel(0, 0, first)
source:drawPixel(1, 0, second)
sprite:newCel(reference, 1, source, Point(0, 0))

local fakeApp = {
  pixelColor = realApp.pixelColor,
  sprite = sprite,
  frame = sprite.frames[1],
  editor = {
    sprite = sprite,
    spritePos = Point(0, 0)
  },
  alert = function(message) error("unexpected alert: " .. tostring(message)) end,
  fgColor = nil
}

app = fakeApp
Timer = fakeTimer
local watcher = dofile('../src/watcher.lua')
local config = {
  referenceLayerName = "Reference",
  ticksPerSecond = 25,
  ignoreTransparent = true,
  sampleFromComposite = false
}

local ok = watcher.start(config)
assertTrue(ok, "watcher should start")
assertEqual(#timers, 1, "one watcher timer should be created")
timers[1].ontick()
assertEqual(fakeApp.fgColor.red, 10, "first pixel red channel")
assertEqual(fakeApp.fgColor.green, 20, "first pixel green channel")

-- Content changes under a stationary cursor must invalidate the position cache.
local replacement = reference:cel(1).image:clone()
local changed = realApp.pixelColor.rgba(70, 80, 90, 255)
replacement:drawPixel(0, 0, changed)
reference:cel(1).image = replacement
timers[1].ontick()
assertEqual(fakeApp.fgColor.red, 70, "stationary cursor should resample changed content")

-- A frame switch at a stationary position must also resample.
local frame2 = sprite:newEmptyFrame(2)
local source2 = Image(sprite.spec)
source2:clear()
local frameColor = realApp.pixelColor.rgba(100, 110, 120, 255)
source2:drawPixel(0, 0, frameColor)
sprite:newCel(reference, frame2, source2, Point(0, 0))
fakeApp.frame = frame2
timers[1].ontick()
assertEqual(fakeApp.fgColor.red, 100, "stationary cursor should resample the new frame")

-- Updating any live setting restarts with the new snapshot, not only frequency changes.
local alternative = sprite:newLayer()
alternative.name = "Alternative"
local alternativeImage = Image(sprite.spec)
alternativeImage:clear()
local alternativeColor = realApp.pixelColor.rgba(130, 140, 150, 255)
alternativeImage:drawPixel(0, 0, alternativeColor)
sprite:newCel(alternative, frame2, alternativeImage, Point(0, 0))
config.referenceLayerName = "Alternative"
ok = watcher.updateConfig(config)
assertTrue(ok, "watcher config update should succeed")
assertEqual(timers[1].isRunning, false, "old timer should be stopped")
assertEqual(#timers, 2, "updated watcher should create one replacement timer")
timers[2].ontick()
assertEqual(fakeApp.fgColor.red, 130, "updated reference layer should take effect immediately")

-- Tick failures are logged/stopped rather than silently swallowed.
fakeApp.pixelColor = nil
watcher.dirty = true
timers[2].ontick()
assertEqual(watcher.isRunning(), false, "watcher should stop after a tick error")
assertEqual(timers[2].isRunning, false, "timer should stop after a tick error")

app = realApp
Timer = realTimer
sprite:close()
print("ALL TESTS PASSED (watcher)")
