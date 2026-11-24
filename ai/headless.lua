-- Lets the rules and AI modules load where there are no graphics or audio:
-- LÖVE worker threads (and test harnesses). pieces.lua, board.lua and the
-- particle effects create images, quads and shaders when they load; here
-- those calls get harmless stand-ins. Sounds are muted.

-- A stand-in for any LÖVE object: every method exists and returns another stub.
local stub
stub = setmetatable({}, {
    __index = function() return function() return stub end end,
    __call = function() return stub end,
})

local function stubModule(fields)
    return setmetatable(fields or {}, {__index = function() return function() return stub end end})
end

if not love.graphics then
    love.graphics = stubModule{
        getWidth = function() return 1920 end,
        getHeight = function() return 1080 end,
    }
end
if not love.math then require'love.math' end
if not love.timer then require'love.timer' end

spriteSize = spriteSize or 50
spriteAtlas = spriteAtlas or stub
genQuad = genQuad or function() return stub end
sounds = sounds or {play = function() end, muted = true}

require'utils'
