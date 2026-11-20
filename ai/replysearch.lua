-- Hard: plan whole turns, then check how the opponent answers them.
--
-- 1. The turn's actions are searched in parallel (each worker takes a share
--    of the possible first actions). From the best end-of-turn plans,
--    `candidates` are shortlisted; with `spread`, each must leave the AI's
--    pieces placed differently from every plan already on the list (at least
--    `spread` differing piece placements), so "push" gets compared with
--    "hold back" instead of with near-copies of itself.
-- 2. For each plan, workers play out the opponent's whole reply turn
--    (with the turn planner at replyBeam x replyDepth, or Greedy),
--    `samples` times with the hidden cards re-dealt.
-- 3. The plan with the best average position after the reply is chosen and
--    committed to: the rest of the turn follows it without searching again,
--    unless a draw or other surprise changes the position.
--
-- Ported from chegg-headless (src/ai/reply.rs), where it beats the turn
-- planner by about 40-55 Elo.

local sim        = require'ai.sim'
local eval       = require'ai.eval'
local pool       = require'ai.pool'
local snapshot   = require'ai.snapshot'
local turnsearch = require'ai.turnsearch'
local jobs       = require'ai.jobs'

local replysearch = {}

local function sameAction(a, b)
    return a.k==b.k and a.card==b.card and a.x==b.x and a.y==b.y and a.fx==b.fx and a.fy==b.fy
end

local function isLegal(board, me, a)
    for _, b in ipairs(sim.actions(board, me)) do
        if sameAction(a, b) then return true end
    end
    return false
end

-- Size of the symmetric difference of two sorted footprints (jobs.footprint).
local function footDistance(a, b)
    local i, j, d = 1, 1, 0
    while i<=#a and j<=#b do
        if a[i]==b[j] then i, j = i+1, j+1
        elseif a[i]<b[j] then d, i = d+1, i+1
        else d, j = d+1, j+1 end
    end
    return d+(#a-i+1)+(#b-j+1)
end

-- The `k` plans to check from `found` (best first); see the header. Places
-- the spread rule leaves empty go to the best of the rest.
local function pickCandidates(found, k, spread)
    local picked, used = {}, {}
    if spread and spread>0 then
        for i, c in ipairs(found) do
            if #picked>=k then break end
            local ok = true
            for _, p in ipairs(picked) do
                if footDistance(c.foot, p.foot)<spread then ok = false break end
            end
            if ok then picked[#picked+1], used[i] = c, true end
        end
    end
    for i, c in ipairs(found) do
        if #picked>=k then break end
        if not used[i] then picked[#picked+1] = c end
    end
    return picked
end

-- `memory` keeps the committed plan between calls (the AI object).
function replysearch.choose(board, me, params, ctx, rng, memory)
    local idx = sim.playerIndex(board, me)

    local plan = memory.plan
    memory.plan = nil
    if plan and plan.turn==board.turn then
        local key = turnsearch.key(board, idx)
        if plan.next<=#plan.seq and plan.keys[plan.next]==key then
            local a = plan.seq[plan.next]
            if isLegal(board, me, a) then
                plan.next = plan.next+1
                memory.plan = plan
                return a
            end
        elseif plan.next>#plan.seq and plan.endKey==key and board:canEndTurn(me) then
            return {k='end'}
        end
    end

    local snap = snapshot.encode(board)
    local detSeed = rng:random(1, 1073741823)

    local parts = pool.size()
    local searches = {}
    -- With spread, each part returns extra plans for the shortlist to choose from.
    local perPart = params.candidates*((params.spread or 0)>0 and 3 or 1)
    for part=1, parts do
        searches[part] = {kind='candidates', snap=snap, detSeed=detSeed, me=idx,
            beam=params.beam, depth=params.depth, k=perPart, part=part, parts=parts,
            tactical=params.ownTactical}
    end
    local found, seen = {}, {}
    for _, list in ipairs(pool.run(searches, ctx)) do
        for _, c in ipairs(list) do
            if not seen[c.endKey] then
                seen[c.endKey] = true
                found[#found+1] = c
            end
        end
    end
    table.sort(found, function(a, b) return a.score>b.score end)
    if found[1].score>=eval.WIN then
        return found[1].seq[1] or {k='end'}
    end
    found = pickCandidates(found, params.candidates, params.spread)

    local replies = {}
    for i, c in ipairs(found) do
        replies[i] = {kind='reply', snap=snap, detSeed=detSeed, me=idx, seq=c.seq,
            samples=params.samples, seed=rng:random(1, 1073741823),
            replyBeam=params.replyBeam, replyDepth=params.replyDepth, minimax=params.minimax,
            guided=params.guided, tactical=params.tactical,
            replySummons=params.replySummons}
    end
    local best, bestScore
    for i, r in ipairs(pool.run(replies, ctx)) do
        if not bestScore or r.score>bestScore then best, bestScore = found[i], r.score end
    end

    if #best.seq==0 then return {k='end'} end
    -- The positions the plan expects before each action, rebuilt on the same
    -- re-dealt position the workers searched (same detSeed).
    local b = jobs.root{snap=snap, detSeed=detSeed, me=idx}
    local keys = {}
    for i, a in ipairs(best.seq) do
        keys[i] = turnsearch.key(b, idx)
        sim.apply(b, b.players[idx], a)
        ctx.check()
    end
    memory.plan = {turn=board.turn, seq=best.seq, keys=keys, endKey=best.endKey, next=2}
    return best.seq[1]
end

return replysearch
