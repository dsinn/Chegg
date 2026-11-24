-- Medium (the strongest level): plan whole turns, then check how the opponent answers them.
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
-- It beats the turn planner by about 40-55 Elo.

local sim        = require'ai.sim'
local eval       = require'ai.eval'
local pool       = require'ai.pool'
local snapshot   = require'ai.snapshot'
local turnsearch = require'ai.turnsearch'
local jobs       = require'ai.jobs'

local replysearch = {}

-- The turn search's tactical level (see turnsearch.search): 0 off, 1
-- follow-up kills by the same piece, 2 also the kills setups make possible,
-- 3 also pulls through a square just vacated.
local function tacticalLevel(on, params)
    if not on then return 0 end
    if params.vacate then return 3 end
    return params.setups and 2 or 1
end

-- An after-reply score at or below this means the reply wins the game.
local LOST = -eval.WIN/2

-- How much more the cautious candidate search fears its pieces being left
-- in reach (see eval.cautiousScore).
local CAUTION = 5

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
    -- The turn's plans, best first, merged over the worker parts, for each
    -- search in `specs` (all run at once, so no worker idles between them):
    -- with `refutations`, scored against them (see jobs.refutedScore); with
    -- `caution`, by eval.cautiousScore.
    local function search(specs)
        local searches = {}
        -- With spread, each part returns extra plans for the shortlist to choose from.
        local perPart = params.candidates*((params.spread or 0)>0 and 3 or 1)
        for _, spec in ipairs(specs) do
            for part=1, parts do
                searches[#searches+1] = {kind='candidates', snap=snap, detSeed=detSeed, me=idx,
                    beam=params.beam, depth=params.depth, k=perPart, part=part, parts=parts,
                    tactical=tacticalLevel(params.ownTactical, params), refutations=spec.refutations,
                    caution=spec.caution}
            end
        end
        local results = pool.run(searches, ctx)
        local out = {}
        for s=1, #specs do
            local found, seen = {}, {}
            for part=1, parts do
                for _, c in ipairs(results[(s-1)*parts+part]) do
                    if not seen[c.endKey] then
                        seen[c.endKey] = true
                        found[#found+1] = c
                    end
                end
            end
            table.sort(found, function(a, b) return a.score>b.score end)
            out[s] = found
        end
        return out
    end
    -- With `cautious`, also plans from a search that fears leaving pieces in
    -- reach far more than the evaluation does, so a quiet turn gets weighed
    -- against plans that all share a raid or an exposed piece.
    local cautious = (params.cautious or 0)>0
    local searched = search(cautious and {{}, {caution=CAUTION}} or {{}})
    local found = searched[1]
    if found[1].score>=eval.WIN then
        return found[1].seq[1] or {k='end'}
    end

    -- Each shortlisted plan with its average score after the reply and the
    -- reply found in its first sample.
    local weighed = {}
    local function weigh(cands)
        local replies = {}
        for i, c in ipairs(cands) do
            replies[i] = {kind='reply', snap=snap, detSeed=detSeed, me=idx, seq=c.seq,
                samples=params.samples, seed=rng:random(1, 1073741823),
                replyBeam=params.replyBeam, replyDepth=params.replyDepth, minimax=params.minimax,
                guided=params.guided, tactical=tacticalLevel(params.tactical, params),
                replySummons=params.replySummons}
        end
        for i, r in ipairs(pool.run(replies, ctx)) do
            weighed[#weighed+1] = {cand=cands[i], score=r.score, reply=r.reply}
        end
    end
    local cands = pickCandidates(found, params.candidates, params.spread)
    if cautious then
        local known = {}
        for _, c in ipairs(cands) do known[c.endKey] = true end
        local extra = {}
        for _, c in ipairs(searched[2]) do
            if not known[c.endKey] then extra[#extra+1] = c end
        end
        for _, c in ipairs(pickCandidates(extra, params.cautious, params.spread)) do
            cands[#cands+1] = c
        end
    end
    weigh(cands)

    -- With `refute`, when every plan loses the game to its reply, search the
    -- turn again assuming the opponent plays those replies whenever they still
    -- work, so the new plans block or remove the threat (up to two rounds).
    local refutations, known = {}, {}
    for _=1, 2 do
        if not params.refute then break end
        local saved = false
        for _, w in ipairs(weighed) do
            if w.score>LOST then saved = true end
        end
        if saved then break end
        local before = #refutations
        for _, w in ipairs(weighed) do
            local r, names = {}, {}
            for _, a in ipairs(w.reply or {}) do
                if a.k~='summon' and a.k~='end' then
                    r[#r+1] = a
                    names[#names+1] = sim.describe(a)
                end
            end
            local name = table.concat(names, ';')
            if #r>0 and not known[name] then
                known[name] = true
                refutations[#refutations+1] = r
            end
        end
        if #refutations==before then break end
        weigh(pickCandidates(search{{refutations=refutations}}[1], params.candidates, params.spread))
    end

    local best, bestScore
    for _, w in ipairs(weighed) do
        if not bestScore or w.score>bestScore then best, bestScore = w.cand, w.score end
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
