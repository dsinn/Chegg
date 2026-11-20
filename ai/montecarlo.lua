-- Medium and Hard: flat Monte Carlo over the current decision.
--
-- 1. Score every legal action with the greedy one-step evaluation and keep
--    the best `candidates` of them (ending the turn is always kept).
-- 2. Repeatedly pick a candidate with UCB1, play it on a copy of the board
--    with hidden cards re-dealt, end the turn, then let a fast rollout policy
--    play `depth` more turns (opponent first). Score the final position.
-- 3. Choose the candidate that was simulated most.
--
-- The AI then makes that one action and decides again, so the rest of the
-- turn is planned with the new position in view.

local sim    = require'ai.sim'
local eval   = require'ai.eval'
local greedy = require'ai.greedy'

local mc = {}

local function worth(pc)
    return pc.type=='king' and 1000 or eval.typeValue(pc.type)
end

local function hitValue(board, player, x, y)
    if not board:isWithinBounds(x, y) then return 0 end
    local t = board:getLivingPieceAt(x, y)
    if not t then return 0 end
    return t.player==player and -worth(t) or worth(t)
end

-- Cheap score for the rollout policy: no copying, just what the action
-- obviously does (kills, summons, getting closer to the enemy king).
local function quickScore(board, player, a, enemyKing)
    if a.k=='summon' then
        return 4+eval.typeValue(a.card)*0.25
    end
    local pc = board:getLivingPieceAt(a.fx, a.fy)
    if not pc then return -100 end

    if a.k=='attack' then
        if (pc.attackDamage or 1)==0 then return -1 end -- pulls and copies
        local total = -3
        if pc.getAttackSplash then
            local c = {pc:getAttackSplash(a.x, a.y)}
            for i=1, #c, 2 do total = total+hitValue(board, player, c[i], c[i+1]) end
        else
            total = total+hitValue(board, player, a.x, a.y)
        end
        return total
    end

    local cost = pc:canMove() and 0 or 4 -- a dash spends mana
    if board:getLivingPieceAt(a.x, a.y) then
        if pc.move then return -1-cost end -- Enderman swap
        return hitValue(board, player, a.x, a.y)-3-cost -- attack-move
    end
    if pc.type=='king' or not enemyKing then return -1-cost end
    local ex, ey = enemyKing.pos[1], enemyKing.pos[2]
    local before = math.max(math.abs(pc.pos[1]-ex), math.abs(pc.pos[2]-ey))
    local after = math.max(math.abs(a.x-ex), math.abs(a.y-ey))
    return (before-after)*1.5-cost
end

-- Plays one whole turn for `player` with an epsilon-greedy policy.
local function playTurn(board, player, rng, policy)
    local opp = board:getOpponent(player)
    for _=1, policy.maxActions do
        if player.dead or opp.dead or not board:isActivePlayer(player) then return end
        local acts = sim.actions(board, player)
        local enemyKing = sim.findKing(opp)
        local best, bestScore, count = nil, 0, 0
        for _, a in ipairs(acts) do
            if a.k~='end' then
                count = count+1
                local s = quickScore(board, player, a, enemyKing)+policy.jitter*rng:random()
                if s>bestScore then best, bestScore = a, s end
            end
        end
        local choice = best
        if count>0 and rng:random()<policy.epsilon then
            local r, j = rng:random(1, count), 0
            for _, a in ipairs(acts) do
                if a.k~='end' then
                    j = j+1
                    if j==r then choice = a break end
                end
            end
        end
        if not choice or not sim.apply(board, player, choice) then break end
    end
    if not player.dead and board:isActivePlayer(player) and board:canEndTurn(player) then
        board:endTurn(player)
    end
end

-- One simulation of "do `action`, end the turn, play on". Returns (-1, 1).
local function simulate(board, me, idx, action, params, rng)
    local c = sim.clone(board, me, rng)
    local cme = c.players[idx]
    if not sim.apply(c, cme, action) then return -1 end
    if action.k~='end' and not sim.isOver(c) and c:isActivePlayer(cme) and c:canEndTurn(cme) then
        c:endTurn(cme)
    end
    local copp = c:getOpponent(cme)
    for t=1, params.depth do
        if sim.isOver(c) then break end
        playTurn(c, t%2==1 and copp or cme, rng, params.rollout)
    end
    return eval.squash(eval.score(c, cme))
end

function mc.choose(board, me, params, ctx, rng)
    local acts = sim.actions(board, me)
    if #acts<=1 then return acts[1] end
    local idx = sim.playerIndex(board, me)

    local cands = {}
    for _, a in ipairs(acts) do
        local s = greedy.scoreAction(board, me, a, rng)
        if s then
            if s>=eval.WIN then return a end -- wins on the spot
            cands[#cands+1] = {a=a, prior=s, n=0, w=0}
        end
        ctx.check()
    end
    if #cands==0 then return nil end
    table.sort(cands, function(x, y) return x.prior>y.prior end)

    local kept, haveEnd = {}, false
    for i, c in ipairs(cands) do
        local isEnd = c.a.k=='end'
        if i<=params.candidates or (isEnd and not haveEnd) then
            kept[#kept+1] = c
            haveEnd = haveEnd or isEnd
        end
    end
    if #kept==1 then return kept[1].a end

    local total = 0
    while total<params.maxSims do
        if total>=#kept and ctx.outOfTime() then break end
        local pick
        if total<#kept then
            pick = kept[total+1] -- try everything once first
        else
            local logN, bestU = math.log(total)
            for _, c in ipairs(kept) do
                local u = c.w/c.n+params.ucb*math.sqrt(logN/c.n)
                if not bestU or u>bestU then pick, bestU = c, u end
            end
        end
        pick.w = pick.w+simulate(board, me, idx, pick.a, params, rng)
        pick.n = pick.n+1
        total = total+1
        ctx.check()
    end

    local best
    for _, c in ipairs(kept) do
        if c.n>0 and (not best or c.n>best.n or (c.n==best.n and c.w>best.w)) then
            best = c
        end
    end
    mc.lastStats = {sims=total, candidates=#kept}
    return (best or kept[1]).a
end

return mc
