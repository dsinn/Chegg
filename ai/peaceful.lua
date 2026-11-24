-- Peaceful: a training opponent that never fights. Greedy over single
-- actions, like the old Easy. It keeps its villager (king) as far from enemy
-- pieces as it can get, and walks its minions up to the other player's
-- minions (or to their villager once they have none), aiming to stand right
-- beside them rather than diagonally (straight-line distance), so there is
-- always something to practise on. It never attacks, and never takes a move
-- that kills anything, its own pieces included (a Phantom's or Slime's
-- attack-move). It ends its turn once nothing improves on standing still.

local sim = require'ai.sim'

local peaceful = {}

local KING_WEIGHT = 10   -- per square between the villager and the nearest enemy
local KING_CAP = 8       -- distances beyond this count as safe enough
local HUG_WEIGHT = 2     -- per square (straight-line) a minion is closer than HUG_CAP to its target
local HUG_CAP = 12       -- more than the board's longest diagonal, so this stays >= 0
local MINION_BONUS = 5   -- per own minion on the board, so it keeps summoning

local function cheb(a, b)
    return math.max(math.abs(a.pos[1]-b.pos[1]), math.abs(a.pos[2]-b.pos[2]))
end

-- Straight-line distance, so a minion beside its target (1) beats one
-- diagonally next to it (1.41).
local function euclid(a, b)
    local dx, dy = a.pos[1]-b.pos[1], a.pos[2]-b.pos[2]
    return math.sqrt(dx*dx+dy*dy)
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

-- How good `me`'s position is: higher means a safer villager and minions
-- closer to their targets. Every term is >= 0, so losing pieces never helps.
function peaceful.score(board, me)
    local mine, theirs = living(me), living(opponent(board, me))
    -- Minions head for enemy minions, or for the villager when there are none.
    local targets = {}
    for _, e in ipairs(theirs) do
        if e.type~='king' then targets[#targets+1] = e end
    end
    if #targets==0 then targets = theirs end
    local s = 0
    for _, pc in ipairs(mine) do
        if pc.type=='king' then
            local d = KING_CAP
            for _, e in ipairs(theirs) do d = math.min(d, cheb(pc, e)) end
            s = s+KING_WEIGHT*d
        else
            local d = HUG_CAP
            for _, e in ipairs(targets) do d = math.min(d, euclid(pc, e)) end
            s = s+MINION_BONUS+HUG_WEIGHT*(HUG_CAP-d)
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
    local enemies, own = count(them), count(me)
    local best, bestScore = {k='end'}, peaceful.score(board, me)
    for _, a in ipairs(sim.actions(board, me)) do
        if a.k=='summon' or a.k=='move' then
            local c = sim.clone(board)
            local cme = c.players[idx]
            -- Nothing may die, on either side (a Phantom can land on its own
            -- villager and kill it).
            if sim.apply(c, cme, a) and count(opponent(c, cme))>=enemies and count(cme)>=own then
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
