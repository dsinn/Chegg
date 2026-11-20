-- A LÖVE worker thread for the AI (started by ai/pool.lua). Takes serialised
-- jobs from `jobsIn`, runs them (ai/jobs.lua) and posts serialised results
-- to `resultsOut` as {id, ok, result | err}. Stops on the message 'quit'.

local jobsIn, resultsOut = ...

require'ai.headless'
local jobs = require'ai.jobs'

local ctx = {check = function() end, wait = function() end}

local function decode(text)
    return setfenv(assert(loadstring(text, 'job')), {})()
end

while true do
    local msg = jobsIn:demand()
    if msg=='quit' then break end
    local job = decode(msg)
    local ok, result = pcall(jobs.run, job, ctx)
    if ok then
        resultsOut:push(table.serialize{id = job.id, ok = true, result = result})
    else
        resultsOut:push(table.serialize{id = job.id, ok = false, err = tostring(result)})
    end
end
