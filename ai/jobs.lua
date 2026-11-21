-- The AI's units of work, run either in a worker thread (ai/worker.lua) or
-- directly when threads aren't available (ai/pool.lua). A job is a plain
-- table, so it can be serialised; positions travel as snapshots.
--
--   {kind='candidates', snap, detSeed, me, beam, depth, k, part, parts, tactical}
--       Re-deals the hidden cards from player `me`'s view (seeded by
--       detSeed), searches the turn's actions (only this part of the first
--       actions) and returns the best k end-of-turn plans:
--       {{seq, endKey, foot, score}, ...}, where foot lists where `me`'s
--       pieces end up (sorted 'x,y,type' strings, for candidate diversity).
--       `tactical` is the turn search's tactical level (0 to 3). With
--       `refutations` (opponent action lists), positions are scored by
--       jobs.refutedScore against them; with `caution`, by
--       eval.cautiousScore with that factor.
--   {kind='reply', snap, detSeed, me, seq, samples, seed, replyBeam, replyDepth, minimax, guided, tactical,
--    replySummons}
--       Rebuilds the same re-dealt position (same detSeed), plays `seq`, ends
--       the turn and lets the opponent play a whole reply turn `samples`
--       times with fresh re-deals: with the turn planner (ai/planner.lua) at
--       replyBeam x replyDepth, or Greedy without them. With `minimax`, the
--       opponent's turn is beam-searched at replyBeam x replyDepth instead,
--       and the position worst for `me` among all it reaches counts, judged
--       without the exposure features (the reply has tested exposure for
--       real). Returns {score, reply}: the average score for `me` after the
--       reply, and with `minimax` the reply found in the first sample.

local sim        = require'ai.sim'
local eval       = require'ai.eval'
local greedy     = require'ai.greedy'
local planner    = require'ai.planner'
local snapshot   = require'ai.snapshot'
local turnsearch = require'ai.turnsearch'

local jobs = {}

local MAX_REPLY_ACTIONS = 40

-- The position a job searches: the snapshot with the hidden cards re-dealt
-- from player `me`'s view. The same detSeed always gives the same deal.
function jobs.root(job)
    local board = snapshot.decode(job.snap)
    local rng = love.math.newRandomGenerator(job.detSeed)
    return sim.clone(board, board.players[job.me], rng), rng
end
local root = jobs.root

-- Where players[idx]'s living pieces stand, as sorted 'x,y,type' strings.
function jobs.footprint(b, idx)
    local foot = {}
    for _, pc in ipairs(b.players[idx].summons) do
        if pc:isAlive() then foot[#foot+1] = pc.pos[1]..','..pc.pos[2]..','..pc.type end
    end
    table.sort(foot)
    return foot
end

-- Score of players[idx]'s end-of-turn position `b`, lowered to what is left
-- after any of `refutations` (opponent action lists) that still works there:
-- the turn ends and the opponent plays it action by action (judged with
-- `leaf`, as replies are). One that hits an illegal action doesn't count.
-- Mirrors `refuted_score` in chegg-headless.
function jobs.refutedScore(b, idx, refutations, leaf)
    local p = b.players[idx]
    local s = eval.score(b, p, 'opp')
    if sim.isOver(b) or not b:isActivePlayer(p) or not b:canEndTurn(p) then return s end
    local ended = sim.clone(b)
    ended:endTurn(ended.players[idx])
    for _, r in ipairs(refutations) do
        local c = sim.clone(ended)
        local opp = c:getOpponent(c.players[idx])
        local works = true
        for _, a in ipairs(r) do
            if sim.isOver(c) then break end
            if not sim.apply(c, opp, a) then works = false break end
        end
        if works then
            s = math.min(s, eval.score(c, c.players[idx], 'me', leaf))
        end
    end
    return s
end

function jobs.candidates(job, ctx)
    local start = root(job)
    local scorer
    if job.refutations then
        local leaf = eval.withoutExposure()
        scorer = function(b) return jobs.refutedScore(b, job.me, job.refutations, leaf) end
    elseif job.caution then
        scorer = function(b) return eval.cautiousScore(b, b.players[job.me], job.caution) end
    end
    local nodes = turnsearch.search(start, job.me, job.beam, job.depth, ctx, job.part, job.parts, scorer, job.tactical)
    local out = {}
    for i=1, math.min(job.k, #nodes) do
        local n = nodes[i]
        out[i] = {seq = n.seq, endKey = turnsearch.key(n.board, job.me),
            foot = jobs.footprint(n.board, job.me), score = n.score}
    end
    return out
end

-- Plays the opponent's whole reply turn on `c` with the planner or Greedy,
-- then scores the result for `me`.
local function playedReply(c, me, opp, job, ctx, rng)
    local params = job.replyBeam and {beam = job.replyBeam, depth = job.replyDepth, noise = 0}
    local n = 0
    while not sim.isOver(c) and c:isActivePlayer(opp) do
        n = n+1
        local a
        if n>MAX_REPLY_ACTIONS then
            a = {k='end'}
        elseif params then
            a = planner.choose(c, opp, params, ctx, rng)
        else
            a = greedy.choose(c, opp, {noise = 0}, ctx, rng)
        end
        if not sim.apply(c, opp, a) then break end
    end
    return eval.score(c, me)
end

-- Beam-searches the opponent's reply turn on `c` and returns the score for
-- players[meIdx] of the worst position it reaches (stopping anywhere),
-- judged with `leafWeights`, and the opponent's actions that reach it. With job.guided, the opponent's partial turns
-- are ranked by the damage they set up against players[meIdx] (its full
-- evaluation, negated) rather than by the opponent's own evaluation, so a
-- set-up like a frog pull before the kill survives the beam. With
-- job.tactical (a level), the search also tries each action with follow-up
-- captures (see turnsearch.search); with job.replySummons == false, the
-- opponent doesn't summon (a Wither still may).
local function minimaxReply(c, meIdx, opp, job, ctx, leafWeights)
    local scorer
    if job.guided then
        scorer = function(b) return -eval.score(b, b.players[meIdx], 'opp') end
    end
    local worst, worstSeq
    for _, node in ipairs(turnsearch.search(c, sim.playerIndex(c, opp), job.replyBeam, job.replyDepth, ctx, nil, nil, scorer, job.tactical,
        job.replySummons==false)) do
        local s = eval.score(node.board, node.board.players[meIdx], 'me', leafWeights)
        if not worst or s<worst then worst, worstSeq = s, node.seq end
    end
    return worst, worstSeq
end

function jobs.reply(job, ctx)
    local b = root(job)
    for _, a in ipairs(job.seq) do
        if not sim.apply(b, b.players[job.me], a) then return {score = -eval.WIN} end
    end
    local rng = love.math.newRandomGenerator(job.seed)
    local leafWeights = job.minimax and eval.withoutExposure()
    local total, reply = 0, nil
    for i=1, job.samples do
        local c = sim.clone(b, b.players[job.me], rng)
        local me = c.players[job.me]
        local opp = c:getOpponent(me)
        if not sim.isOver(c) and c:isActivePlayer(me) and c:canEndTurn(me) then
            c:endTurn(me)
        end
        if job.minimax and not sim.isOver(c) and c:isActivePlayer(opp) then
            local s, seq = minimaxReply(c, job.me, opp, job, ctx, leafWeights)
            total = total+s
            if i==1 then reply = seq end
        else
            total = total+playedReply(c, me, opp, job, ctx, rng)
        end
    end
    return {score = total/job.samples, reply = reply}
end

function jobs.run(job, ctx)
    local f = jobs[job.kind]
    if not f then error('unknown AI job: '..tostring(job.kind)) end
    return f(job, ctx)
end

return jobs
