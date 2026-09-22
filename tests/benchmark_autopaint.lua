-- tests/benchmark_autopaint.lua: measures queue preparation in Aseprite's Lua runtime.

local realTimer = Timer
local timers = {}
Timer = function(spec)
  local timer = { ontick = spec.ontick, isRunning = false }
  function timer:start() self.isRunning = true end
  function timer:stop() self.isRunning = false end
  timers[#timers + 1] = timer
  return timer
end

local autopaint = dofile('../src/autopaint.lua')

local function runCase(name, canvasSize, sourceSize)
  timers = {}
  local sprite = Sprite(canvasSize, canvasSize, ColorMode.RGB)
  local target = sprite.layers[1]
  if target:cel(1) then sprite:deleteCel(target:cel(1)) end
  local reference = sprite:newLayer()
  reference.name = "Reference"

  local source = Image(sourceSize, sourceSize, ColorMode.RGB)
  source:clear(app.pixelColor.rgba(40, 80, 120, 255))
  local offset = math.floor((canvasSize - sourceSize) / 2)
  sprite:newCel(reference, 1, source, Point(offset, offset))

  app.activeSprite = sprite
  app.activeLayer = target
  app.activeFrame = sprite.frames[1]

  local started = os.clock()
  local ok, err = autopaint.start({
    referenceLayerName = "Reference",
    sampleFromComposite = false,
    autopaintTicksPerSecond = 60,
    autopaintPixelsPerTick = 500,
    autopaintOrder = "raster"
  }, {})
  if not ok then error(err) end

  local ticks = 0
  while autopaint.isRunning() do
    local status = autopaint.getStatus()
    if status.phase == "painting" then break end
    ticks = ticks + 1
    if ticks > 100000 then error("benchmark did not reach painting phase") end
    timers[#timers].ontick()
  end

  local elapsed = os.clock() - started
  local status = autopaint.getStatus()
  print(string.format(
    "%s: canvas=%dx%d source=%dx%d candidates=%d queued=%d prepare=%.3fs timerTicks=%d",
    name,
    canvasSize,
    canvasSize,
    sourceSize,
    sourceSize,
    status.candidates,
    status.total,
    elapsed,
    ticks))

  autopaint.stop("benchmark", false)
  sprite:close()
end

runCase("bounded", 1024, 16)
runCase("full", 1024, 1024)

Timer = realTimer
print("BENCHMARK COMPLETE")
