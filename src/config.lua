-- config.lua: validated configuration backed by Aseprite plugin.preferences.

local config = {}

local defaults = {
  enabled = false,
  referenceLayerName = "Reference",
  ticksPerSecond = 25,
  ignoreTransparent = true,
  sampleFromComposite = false,
  autopaintTicksPerSecond = 30,
  autopaintPixelsPerTick = 50,
  autopaintOrder = "raster"
}

local function clampInteger(value, minimum, maximum, fallback)
  value = tonumber(value)
  if not value then return fallback end
  value = math.floor(value)
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

local validators = {
  enabled = function(value)
    return value == true
  end,
  referenceLayerName = function(value)
    if type(value) ~= "string" or value:match("^%s*$") then
      return defaults.referenceLayerName
    end
    return value
  end,
  ticksPerSecond = function(value)
    return clampInteger(value, 15, 40, defaults.ticksPerSecond)
  end,
  ignoreTransparent = function(value)
    if type(value) ~= "boolean" then return defaults.ignoreTransparent end
    return value
  end,
  sampleFromComposite = function(value)
    if type(value) ~= "boolean" then return defaults.sampleFromComposite end
    return value
  end,
  autopaintTicksPerSecond = function(value)
    return clampInteger(value, 1, 60, defaults.autopaintTicksPerSecond)
  end,
  autopaintPixelsPerTick = function(value)
    return clampInteger(value, 1, 500, defaults.autopaintPixelsPerTick)
  end,
  autopaintOrder = function(value)
    if value == "random" then return "random" end
    return "raster"
  end
}

local function validated(key, value)
  local validator = validators[key]
  if not validator then return nil end
  return validator(value)
end

function config.init(plugin)
  config.plugin = plugin

  for key, defaultValue in pairs(defaults) do
    local value = plugin.preferences[key]
    local clean = value == nil and defaultValue or validated(key, value)
    if value ~= clean then plugin.preferences[key] = clean end
  end
end

function config.get(key)
  if defaults[key] == nil then return nil end
  local value = config.plugin.preferences[key]
  if value == nil then return defaults[key] end
  return validated(key, value)
end

function config.set(key, value)
  if defaults[key] == nil then return false end
  config.plugin.preferences[key] = validated(key, value)
  return true
end

function config.getAll()
  local result = {}
  for key, _ in pairs(defaults) do
    result[key] = config.get(key)
  end
  return result
end

function config.update(values)
  for key, value in pairs(values) do
    if defaults[key] ~= nil then config.set(key, value) end
  end
end

return config
