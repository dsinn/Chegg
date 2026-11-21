-- A LÖVE worker thread for the AI (started by ai/pool.lua). Takes serialised
-- jobs from `jobsIn`, runs them (ai/jobs.lua) and posts serialised results
-- to `resultsOut` as {id, ok, result | err}. Stops on the message 'quit'.
-- A job older than the latest generation in `generations` (ai/pool.lua) is
-- abandoned part-way and posts nothing.

local jobsIn, resultsOut, generations = ...

require'ai.headless'
local jobs = require'ai.jobs'

local CANCELLED = {}
local current, calls = math.huge, 0
local ctx = {
    check = function()
        calls = calls+1
        if calls%64~=0 or not generations then return end
        local latest = generations:peek()
        if latest and latest>current then error(CANCELLED, 0) end
    end,
    wait = function() end,
}

local function decode(text)
    return setfenv(assert(loadstring(text, 'job')), {})()
end

while true do
    local msg = jobsIn:demand()
    if msg=='quit' then break end
    local job = decode(msg)
    current = job.gen or math.huge
    local latest = generations and generations:peek()
    local ok, result
    if latest and latest>current then
        ok, result = false, CANCELLED
    else
        ok, result = pcall(jobs.run, job, ctx)
    end
    if result==CANCELLED then
        -- Abandoned: nobody is waiting for it.
    elseif ok then
        resultsOut:push(table.serialize{id = job.id, ok = true, result = result})
    else
        resultsOut:push(table.serialize{id = job.id, ok = false, err = tostring(result)})
    end
end
