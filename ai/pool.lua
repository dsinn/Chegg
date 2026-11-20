-- Runs AI jobs (ai/jobs.lua) on worker threads, one per spare CPU core (up
-- to 8). The workers are started once and shared by every game. Where LÖVE
-- threads aren't available (e.g. test harnesses) jobs run directly instead,
-- so the same code is exercised either way.

local jobs = require'ai.jobs'

local pool = {}

local MAX_WORKERS = 8
local started, threads, jobsIn, resultsOut
local nextId = 0

local function start()
    if started then return end
    started = true
    if not (love.thread and love.thread.newThread and love.system) then return end
    local n = math.max(1, math.min(MAX_WORKERS, love.system.getProcessorCount()-1))
    jobsIn = love.thread.newChannel()
    resultsOut = love.thread.newChannel()
    threads = {}
    for i=1, n do
        threads[i] = love.thread.newThread('ai/worker.lua')
        threads[i]:start(jobsIn, resultsOut)
    end
end

-- How many jobs can run at once.
function pool.size()
    start()
    return threads and #threads or 1
end

local function decode(text)
    return setfenv(assert(loadstring(text, 'result')), {})()
end

-- Runs a list of jobs and returns their results in the same order. Called
-- from inside the AI's coroutine: while workers think it yields (ctx.wait),
-- so the game keeps drawing.
function pool.run(list, ctx)
    start()
    if not threads then
        local out = {}
        for i, job in ipairs(list) do out[i] = jobs.run(job, ctx) end
        return out
    end

    -- Jobs from an abandoned search (say, the player left the game) are
    -- dropped, and any of their late results ignored.
    jobsIn:clear()
    local slot = {}
    for i, job in ipairs(list) do
        nextId = nextId+1
        job.id = nextId
        slot[nextId] = i
        jobsIn:push(table.serialize(job))
    end
    local out, remaining = {}, #list
    while remaining>0 do
        local msg = resultsOut:pop()
        if msg then
            local r = decode(msg)
            local i = slot[r.id]
            if i then
                if not r.ok then error('AI worker failed: '..r.err, 0) end
                out[i] = r.result
                slot[r.id] = nil
                remaining = remaining-1
            end
        else
            for _, t in ipairs(threads) do
                local err = t:getError()
                if err then error('AI worker crashed: '..err, 0) end
            end
            ctx.wait()
        end
    end
    return out
end

return pool
