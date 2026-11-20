-- Score of a position from one player's point of view: a weighted sum of
-- features, each "mine minus theirs". Positive is good for `me`; a win or
-- loss is +-eval.WIN.
--
-- The features and weights mirror chegg-headless (src/ai/eval.rs), where the
-- weights are tuned by self-play. Its parity test checks that this file
-- computes exactly the same features as the Rust engine, so tuned weights
-- can be pasted in here unchanged.

local Piece = require'pieces'

local eval = {}

eval.WIN = 10000

-- Deck kinds in the Rust engine's order (material features 1-17).
local KINDS = {'zombie', 'creeper', 'pig', 'rabbit', 'pufferfish', 'golem', 'frog', 'skeleton',
    'blaze', 'phantom', 'farlander', 'slime', 'box', 'parrot', 'cat', 'sniffer', 'wither'}
eval.KINDS = KINDS

-- Feature names, in order (same as `feature_name` in eval.rs).
local NAMES = {}
for i, k in ipairs(KINDS) do NAMES[i] = 'material.'..k end
for _, n in ipairs{'hand', 'deck', 'king_threat_moving', 'king_threat_waiting', 'hanging_moving',
    'hanging_waiting', 'advance', 'guard', 'tempo', 'king_advance', 'king_zone', 'king_escape',
    'defended', 'home_intrusion', 'mana_wasted', 'exposed_moving', 'exposed_waiting',
    'exposed_undefended'} do
    NAMES[#NAMES+1] = n
end
eval.NAMES = NAMES
local INDEX = {}
for i, n in ipairs(NAMES) do INDEX[n] = i end

-- The original hand-written piece values, still used as quick piece values by
-- the Monte Carlo rollouts (as in the Rust port).
local valueCache = {}
function eval.typeValue(t)
    local v = valueCache[t]
    if v then return v end
    local data = Piece.getTypeData(t)
    if t=='king' or not data then
        v = 0
    elseif t=='cat' then
        v = 60
    else
        v = 10+(data.cost or 0)*9
    end
    valueCache[t] = v
    return v
end

-- Weights by feature name, from chegg-headless's weights/patient-1.txt
-- (2026-11-20): tuned by self-play (SPSA with the turn planner,
-- weights/spsa-exposed.txt), except the exposure weights (-3) and advance
-- (-1, half the tuned pull forward; no cost against the AI), set by hand
-- from games against a human. Self-play can't learn them: no AI opponent keeps
-- its pieces out of reach and punishes whatever walks into it, which is how
-- people beat the computer.
eval.weights = {
    ['material.zombie'] = 29.5319,
    ['material.creeper'] = 28.1178,
    ['material.pig'] = 11.1017,
    ['material.rabbit'] = 20.2823,
    ['material.pufferfish'] = 31.3145,
    ['material.golem'] = 37.7523,
    ['material.frog'] = 27.1309,
    ['material.skeleton'] = 55.6210,
    ['material.blaze'] = 45.5208,
    ['material.phantom'] = 63.1713,
    ['material.farlander'] = 25.4440,
    ['material.slime'] = 67.4685,
    ['material.box'] = 30.3708,
    ['material.parrot'] = 31.5568,
    ['material.cat'] = 42.9626,
    ['material.sniffer'] = 27.8557,
    ['material.wither'] = 41.2614,
    hand = 6.1637,
    deck = 2.0242,
    king_threat_moving = -35.0353,
    king_threat_waiting = -337.2631,
    hanging_moving = -2.4588,
    hanging_waiting = -1.8006,
    advance = -1.0000,
    guard = 0.5025,
    tempo = 0.0934,
    king_advance = -1.6047,
    king_zone = -0.1725,
    king_escape = -0.6406,
    defended = -0.0298,
    home_intrusion = -0.3045,
    mana_wasted = 0.9154,
    exposed_moving = -0.0462,
    exposed_waiting = -3.0000,
    exposed_undefended = -3.0000,
}

local function key(x, y) return x*100+y end

local function cheb(ax, ay, bx, by)
    return math.max(math.abs(ax-bx), math.abs(ay-by))
end

local function inBounds(board, x, y)
    return x>=1 and y>=1 and x<=board.cols and y<=board.rows
end

-- How many of `player`'s pieces could hit each square with one attack from
-- where they stand, ignoring mana and once-per-turn limits.
function eval.threats(board, player)
    local map = {}
    local function mark(x, y)
        if inBounds(board, x, y) then
            local k = key(x, y)
            map[k] = (map[k] or 0)+1
        end
    end
    for _, q in ipairs(player.summons) do
        if q:isAlive() and (q.attackDamage or 1)~=0 then
            local qx, qy = q.pos[1], q.pos[2]
            local data = q.typeData
            local r = math.max(q.moveRange or 0, q.attackRange or 0)
            for _, owner in ipairs(board.players) do
                for _, t in ipairs(owner.summons) do
                    local tx, ty = t.pos[1], t.pos[2]
                    if t~=q and t:isAlive() and math.abs(tx-qx)<=r and math.abs(ty-qy)<=r then
                        if q.attackMove then
                            if owner~=player and data.canTravelTo(q, tx, ty) then
                                mark(tx, ty)
                            end
                        elseif data.canAttackTo and data.canAttackTo(q, tx, ty) then
                            if q.getAttackSplash then
                                local c = {q:getAttackSplash(tx, ty)}
                                for i=1, #c, 2 do mark(c[i], c[i+1]) end
                            else
                                mark(tx, ty)
                            end
                        end
                    end
                end
            end
        end
    end
    return map
end

-- `player`'s pieces that can hurt, with how far each could strike next turn
-- after moving first: move range + attack range, or for pieces that attack
-- by moving onto their target, two moves (a move and a dash). A cheap
-- Chebyshev bound that ignores blocking, mana and terrain.
-- The longest attack a Parrot at (x, y) could copy this turn: from any living
-- creature but a Parrot or a harmless one within 3 squares (it can fly 2 to
-- land beside it). Attack-move kinds count their move range. Mirrors
-- parrot_copy_range in eval.rs.
local function parrotCopyRange(board, x, y)
    local best
    for _, p in ipairs(board.players) do
        for _, c in ipairs(p.summons) do
            local d = c.typeData
            if c:isAlive() and c.type~='parrot' and (d.attackDamage or 1)~=0 and cheb(c.pos[1], c.pos[2], x, y)<=3 then
                local r
                if d.attackMove then r = d.moveRange or 0 else r = d.attackRange or 0 end
                if r>0 and (not best or r>best) then best = r end
            end
        end
    end
    return best
end

local function reach(board, player)
    local out = {}
    for _, q in ipairs(player.summons) do
        if q:isAlive() and q.type=='parrot' and (q.attackDamage or 1)==0 then
            -- An uncopied Parrot flies up to 2, then copies the attack of a
            -- creature beside it: reach 2 + the best copyable attack within 3.
            local best = parrotCopyRange(board, q.pos[1], q.pos[2])
            if best then out[#out+1] = {q.pos[1], q.pos[2], 2+best} end
        elseif q:isAlive() and (q.attackDamage or 1)~=0 then
            local mr, ar = q.moveRange or 0, q.attackRange or 0
            local r
            if q.type=='farlander' then
                r = ar -- it only moves by swapping (see swapExposed), so just its attack
            elseif q.attackMove then r = 2*mr elseif ar>0 then r = mr+ar end
            if r then out[#out+1] = {q.pos[1], q.pos[2], r} end
        end
    end
    return out
end

-- Whether a piece at (x, y) could be pulled by one of `enemy`'s frogs into
-- `enemyReach`. A frog's attack pulls the nearest creature in a straight line
-- two squares towards it (or up to the square next to the frog; never from
-- the next square), and a frog can first hop up to two steps
-- (|dx| + |dy| <= 2) to an empty square.
-- Mirrors frog_exposed in eval.rs; a cheap approximation that ignores mana.
local FROG_RANGE = Piece.getTypeData('frog').attackRange
local JUMPS = {{0, 0}, {1, 0}, {2, 0}, {-1, 0}, {-2, 0}, {0, 1}, {0, 2}, {0, -1}, {0, -2},
    {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}
local function frogExposed(board, enemy, x, y, enemyReach)
    for _, f in ipairs(enemy.summons) do
        if f:isAlive() and f.type=='frog' then
            for _, j in ipairs(JUMPS) do
                local fx, fy = f.pos[1]+j[1], f.pos[2]+j[2]
                local moved = j[1]~=0 or j[2]~=0
                local ok = not moved or (inBounds(board, fx, fy) and not board:getLivingPieceAt(fx, fy))
                if ok and (fx==x or fy==y) and not (fx==x and fy==y) then
                    local dx = fx>x and 1 or fx<x and -1 or 0
                    local dy = fy>y and 1 or fy<y and -1 or 0
                    local dist = math.max(math.abs(fx-x), math.abs(fy-y))
                    if dist>=2 and dist<=FROG_RANGE then
                        local clear = true
                        for k=1, dist-1 do
                            local q = board:getLivingPieceAt(x+dx*k, y+dy*k)
                            if q and q~=f then clear = false break end
                        end
                        if clear then
                            local step = math.min(2, dist-1)
                            local tx, ty = x+dx*step, y+dy*step
                            for _, r in ipairs(enemyReach) do
                                if cheb(tx, ty, r[1], r[2])<=r[3] then return true end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

-- Whether a piece at (x, y) could be swapped by one of `enemy`'s Endermen
-- ('farlander') onto the Enderman's square, within `enemyReach` of another
-- enemy piece. An Enderman swaps places with any creature but a king that
-- shares its row or column and isn't next to it. Mirrors swap_exposed in
-- eval.rs.
local function swapExposed(enemy, x, y, enemyReach)
    for _, e in ipairs(enemy.summons) do
        local ex, ey = e.pos[1], e.pos[2]
        if e:isAlive() and e.type=='farlander' and (ex==x or ey==y) and math.abs(ex-x)+math.abs(ey-y)>1 then
            for _, r in ipairs(enemyReach) do
                if not (r[1]==ex and r[2]==ey) and cheb(ex, ey, r[1], r[2])<=r[3] then return true end
            end
        end
    end
    return false
end

local function kingOf(player)
    for _, pc in ipairs(player.summons) do
        if pc.type=='king' and pc:isAlive() then return pc end
    end
end

-- The feature vector (a list of NAMES-many numbers) from `me`'s point of view.
function eval.features(board, me, meToMove)
    local f = {}
    for i=1, #NAMES do f[i] = 0 end
    local opp = board:getOpponent(me)
    local threats = {[me] = eval.threats(board, me), [opp] = eval.threats(board, opp)}
    local kings = {[me] = kingOf(me), [opp] = kingOf(opp)}
    local reaches = {[me] = reach(board, me), [opp] = reach(board, opp)}

    f[INDEX.hand] = #me.hand-#opp.hand
    f[INDEX.deck] = #me.deck-#opp.deck
    f[INDEX.tempo] = meToMove and 1 or -1

    for _, p in ipairs{me, opp} do
        local sign = p==me and 1 or -1
        local ownerMoves = (p==me)==meToMove
        local enemy = p==me and opp or me
        local enemyThreats = threats[enemy]
        local ownThreats = threats[p]
        local ownKing, enemyKing = kings[p], kings[enemy]
        if not ownerMoves then
            f[INDEX.mana_wasted] = f[INDEX.mana_wasted]+sign*p.mana
        end

        if ownKing then
            local n = enemyThreats[key(ownKing.pos[1], ownKing.pos[2])] or 0
            local i = ownerMoves and INDEX.king_threat_moving or INDEX.king_threat_waiting
            f[i] = f[i]+sign*n
            local walked = p==board.localplayer and board.rows-ownKing.pos[2] or ownKing.pos[2]-1
            f[INDEX.king_advance] = f[INDEX.king_advance]+sign*walked
            for dx=-1, 1 do
                for dy=-1, 1 do
                    local x, y = ownKing.pos[1]+dx, ownKing.pos[2]+dy
                    if not (dx==0 and dy==0) and inBounds(board, x, y) then
                        local attacked = enemyThreats[key(x, y)] or 0
                        f[INDEX.king_zone] = f[INDEX.king_zone]+sign*attacked
                        if attacked==0 and not board:getLivingPieceAt(x, y) then
                            f[INDEX.king_escape] = f[INDEX.king_escape]+sign
                        end
                    end
                end
            end
        end

        for _, pc in ipairs(p.summons) do
            -- p's piece standing in the enemy's spawn rows counts against the enemy.
            if pc:isAlive() then
                local y = pc.pos[2]
                local inEnemyHome
                if enemy==board.localplayer then
                    inEnemyHome = y>board.rows-board.homeRows
                else
                    inEnemyHome = y<=board.homeRows
                end
                if inEnemyHome then
                    f[INDEX.home_intrusion] = f[INDEX.home_intrusion]-sign
                end
            end
            if pc:isAlive() and pc.type~='king' then
                local m = INDEX['material.'..pc.type]
                f[m] = f[m]+sign
                if (ownThreats[key(pc.pos[1], pc.pos[2])] or 0)>0 then
                    f[INDEX.defended] = f[INDEX.defended]+sign
                end
                local v = (pc.typeData.cost or 0)+1
                if (enemyThreats[key(pc.pos[1], pc.pos[2])] or 0)>0 then
                    local i = ownerMoves and INDEX.hanging_moving or INDEX.hanging_waiting
                    f[i] = f[i]+sign*v
                end
                local exposed = false
                for _, r in ipairs(reaches[enemy]) do
                    if cheb(pc.pos[1], pc.pos[2], r[1], r[2])<=r[3] then exposed = true break end
                end
                if not exposed then
                    exposed = frogExposed(board, enemy, pc.pos[1], pc.pos[2], reaches[enemy])
                        or swapExposed(enemy, pc.pos[1], pc.pos[2], reaches[enemy])
                end
                if exposed then
                    if ownerMoves then
                        f[INDEX.exposed_moving] = f[INDEX.exposed_moving]+sign*v
                    else
                        f[INDEX.exposed_waiting] = f[INDEX.exposed_waiting]+sign*v
                        if (ownThreats[key(pc.pos[1], pc.pos[2])] or 0)==0 then
                            f[INDEX.exposed_undefended] = f[INDEX.exposed_undefended]+sign*v
                        end
                    end
                end
                if enemyKing and ((pc.attackRange or 0)>0 or pc.attackMove) then
                    f[INDEX.advance] = f[INDEX.advance]+sign*cheb(pc.pos[1], pc.pos[2], enemyKing.pos[1], enemyKing.pos[2])
                end
                if ownKing and cheb(pc.pos[1], pc.pos[2], ownKing.pos[1], ownKing.pos[2])==1 then
                    f[INDEX.guard] = f[INDEX.guard]+sign
                end
            end
        end
    end
    return f
end

-- `toMove` is 'me' or 'opp'; by default whoever's turn it is on the board.
-- `weights` defaults to eval.weights (see eval.withoutExposure).
function eval.score(board, me, toMove, weights)
    weights = weights or eval.weights
    local opp = board:getOpponent(me)
    if me.dead and opp.dead then return 0 end
    if me.dead then return -eval.WIN end
    if opp.dead then return eval.WIN end
    local meToMove
    if toMove then
        meToMove = toMove=='me'
    else
        meToMove = board:isActivePlayer(me)
    end
    local f = eval.features(board, me, meToMove)
    local s = 0
    for i, n in ipairs(NAMES) do
        s = s+(weights[n] or 0)*f[i]
    end
    return s
end

-- eval.weights with the exposure features left out, for judging the outcome
-- of a minimax reply (see ai/jobs.lua and reply.rs in chegg-headless).
function eval.withoutExposure()
    local w = {}
    for k, v in pairs(eval.weights) do w[k] = v end
    w.exposed_moving, w.exposed_waiting, w.exposed_undefended = 0, 0, 0
    return w
end

-- Maps a score into (-1, 1) for averaging simulation results.
function eval.squash(s)
    if s>=eval.WIN then return 1 end
    if s<=-eval.WIN then return -1 end
    return s/(math.abs(s)+150)
end

return eval
