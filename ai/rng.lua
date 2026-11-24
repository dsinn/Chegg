-- The random generator used in games against the computer: Park-Miller
-- (exact in LuaJIT's doubles), simple enough to reproduce anywhere, so a game
-- log's starting state plus its actions replay exactly, random discards
-- included (ai/gamelog.lua). Same interface as the game's use of a
-- LÖVE RandomGenerator: random(), random(n) and random(a, b).

local rng = {}
rng.__index = rng

local M = 2147483647

function rng.new(seed)
    local s = math.floor(seed) % M
    if s<=0 then s = s+(M-1) end
    return setmetatable({s = s}, rng)
end

function rng:random(a, b)
    self.s = (self.s*48271) % M
    if a==nil then return self.s/M end
    if b==nil then a, b = 1, a end
    return a+self.s % (b-a+1)
end

-- The whole state; rng.new(getState()) continues the same sequence.
function rng:getState()
    return self.s
end

return rng
