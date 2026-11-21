-- Peaceful: a training opponent that never fights. Greedy over single
-- actions, like the old Easy, but scored only on keeping away from the other
-- player: its villager (king) as far from enemy pieces as it can get, and its
-- minions out of enemy minions' reach. It never attacks, and never takes a
-- move that kills anything (a Phantom's or Slime's attack-move). It summons a
-- minion only where it lands well away from the enemy, and ends its turn
-- once nothing improves on standing still.

local sim = require'ai.sim'

local peaceful = {}

local KING_WEIGHT = 10   -- per square between the villager and the nearest enemy
local KING_CAP = 8       -- distances beyond this count as safe enough
local NEAR = 4           -- a minion closer than this to an enemy minion is "near"
local NEAR_WEIGHT = 3    -- per square inside NEAR, per pair of minions
local MINION_BONUS = 5   -- per own minion on the board, so safe summons happen

local function cheb(a, b)
    return math.max(math.abs(a.pos[1]-b.pos[1]), math.abs(a.pos[2]-b.pos[2]))
end

local function living(player)
    local t = {}
    for _, pc in ipairs(player.summons) do
        if pc:isAlive() then t[#t+1] = pc end
    end
    return t
end

local function opponent(board, me)
    for _, p in ipairs(board.players) do
        if p~=me then return p end
    end
end

-- How peaceful `me`'s position is: higher is safer and further apart.
function peaceful.score(board, me)
    local mine, theirs = living(me), living(opponent(board, me))
    local s = 0
    for _, pc in ipairs(mine) do
        if pc.type=='king' then
            local d = KING_CAP
            for _, e in ipairs(theirs) do d = math.min(d, cheb(pc, e)) end
            s = s+KING_WEIGHT*d
        else
            s = s+MINION_BONUS
            for _, e in ipairs(theirs) do
                if e.type~='king' then
                    s = s-NEAR_WEIGHT*math.max(0, NEAR-cheb(pc, e))
                end
            end
        end
    end
    return s
end

local function count(player)
    return #living(player)
end

function peaceful.choose(board, me, params, ctx, rng)
    local idx = sim.playerIndex(board, me)
    local them = opponent(board, me)
    local enemies = count(them)
    local best, bestScore = {k='end'}, peaceful.score(board, me)
    for _, a in ipairs(sim.actions(board, me)) do
        if a.k=='summon' or a.k=='move' then
            local c = sim.clone(board)
            local cme = c.players[idx]
            if sim.apply(c, cme, a) and count(opponent(c, cme))>=enemies then
                local s = peaceful.score(c, cme)+(params.noise or 0)*(rng:random()*2-1)
                if s>bestScore then best, bestScore = a, s end
            end
        end
        ctx.check()
    end
    -- Ending the turn may be impossible (rules that force an action); then
    -- take the best action found anyway, or let ai:perform end the turn.
    return best
end

return peaceful
