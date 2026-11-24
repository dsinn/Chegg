-- Beam search over one player's actions within a turn, keeping the action
-- sequence that leads to each position. Used by the reply search
-- (ai/replysearch.lua) through its worker jobs (ai/jobs.lua).

local sim  = require'ai.sim'
local eval = require'ai.eval'

local turnsearch = {}

-- Everything that matters within a turn, as far as players[idx] can see:
-- the board, everyone's mana and card counts, and idx's own hand.
function turnsearch.key(b, idx)
    local parts = {b.turn}
    for x=1, b.cols do
        for y=1, b.rows do
            local pc = b:getLivingPieceAt(x, y)
            if pc then
                parts[#parts+1] = ('%d,%d,%s,%d,%d,%d,%s'):format(x, y, pc.type,
                    pc.player==b.players[1] and 1 or 2,
                    pc.lastMoved==b.turn and 1 or 0,
                    pc.lastSpecialed==b.turn and 1 or 0,
                    pc.attackAs or '')
            end
        end
    end
    for _, p in ipairs(b.players) do
        parts[#parts+1] = ('%d/%d/%d/%s'):format(p.mana, #p.hand, #p.deck, p.dead and 1 or 0)
    end
    local hand = {}
    for i, card in ipairs(b.players[idx].hand) do hand[i] = card end
    table.sort(hand)
    parts[#parts+1] = table.concat(hand, '.')
    return table.concat(parts, '|')
end

local function append(list, v)
    local n = {}
    for i=1, #list do n[i] = list[i] end
    n[#n+1] = v
    return n
end

-- Searches from `root` (already re-dealt from players[idx]'s point of view).
-- Returns every distinct position reached, best score first, as
-- {board, seq (actions), keys (turnsearch.key before each action), score}.
-- With `part` and `parts`, only first actions numbered part, part+parts, ...
-- are explored, so several workers can split one search. See search's
-- `scorer` below for ranking positions some other way.
-- `scorer(board)` ranks positions (higher is kept); by default players[idx]'s
-- own evaluation at the end of its turn.
local function aliveCount(p)
    local n = 0
    for _, pc in ipairs(p.summons) do
        if pc:isAlive() then n = n+1 end
    end
    return n
end

-- A move onto an occupied square or an attack: the only actions that can
-- take a piece.
local function canTake(b, f)
    return f.k=='attack' or (f.k=='move' and b:getLivingPieceAt(f.x, f.y)~=nil)
end

-- What stands on (x, y): kind and owner, or nil.
local function heldAt(b, x, y)
    local pc = b:getLivingPieceAt(x, y)
    return pc and pc.type..(pc.player==b.players[1] and 1 or 2)
end

local function cheb(x1, y1, x2, y2)
    return math.max(math.abs(x1-x2), math.abs(y1-y2))
end

-- The ways the piece on (x, y) can take a piece in one or two actions from
-- `g` (a capture, or a move to an empty square then a capture), appended to
-- `out` as {steps = {{action, key before}, ...} after `prefix`, board}.
-- With `target` ({x, y}), only sequences that take the piece standing there.
local function killsBy(g, idx, x, y, target, prefix, out, ctx)
    local p = g.players[idx]
    local victimIdx = 3-idx
    local victims = aliveCount(g.players[victimIdx])
    local held = target and heldAt(g, target[1], target[2])
    local function took(s)
        return sim.isOver(s) or (aliveCount(s.players[victimIdx])<victims
            and (not target or heldAt(s, target[1], target[2])~=held))
    end
    local mr = g:getLivingPieceAt(x, y).moveRange or 0
    local h
    for _, b in ipairs(sim.pieceActions(g, p, x, y)) do
        local take = canTake(g, b)
        local s = sim.clone(g)
        if sim.apply(s, s.players[idx], b) then
            if take then
                if took(s) then
                    h = h or turnsearch.key(g, idx)
                    out[#out+1] = {steps = append(prefix, {b, h}), board = s}
                end
            elseif b.k=='move' and not sim.isOver(s) and s:isActivePlayer(s.players[idx]) then
                -- Only from a square within reach of the target (or of any
                -- enemy piece): the attack range or, for pieces that take by
                -- moving, the move range, plus one for splash.
                local reach = math.max(mr, s:getLivingPieceAt(b.x, b.y).attackRange or 0) + 1
                local inReach = false
                if target then
                    inReach = cheb(b.x, b.y, target[1], target[2])<=reach
                else
                    for _, e in ipairs(s.players[victimIdx].summons) do
                        if e:isAlive() and cheb(b.x, b.y, e.pos[1], e.pos[2])<=reach then
                            inReach = true
                            break
                        end
                    end
                end
                if inReach then
                    local h2
                    for _, b2 in ipairs(sim.pieceActions(s, s.players[idx], b.x, b.y)) do
                        if canTake(s, b2) then
                            local s2 = sim.clone(s)
                            if sim.apply(s2, s2.players[idx], b2) and took(s2) then
                                h = h or turnsearch.key(g, idx)
                                h2 = h2 or turnsearch.key(s, idx)
                                out[#out+1] = {steps = append(append(prefix, {b, h}), {b2, h2}), board = s2}
                            end
                        end
                        ctx.check()
                    end
                end
            end
        end
        ctx.check()
    end
end

-- After attack `a` took `g` to `c` without taking anything: if it set
-- something up (a frog's pull moved a piece, a parrot copied an attack), the
-- kills it set up, in one or two actions by one piece: the pulled piece
-- taken by any of idx's pieces in reach, a pulled own piece's kills, the
-- parrot's kills with its new attack.
local function setupKills(g, c, idx, a, prefix, out, ctx)
    if a.k~='attack' or sim.isOver(c) or not c:isActivePlayer(c.players[idx]) then return end
    if aliveCount(c.players[3-idx])<aliveCount(g.players[3-idx]) then return end
    local before = g:getLivingPieceAt(a.fx, a.fy)
    if not before then return end
    local after = c:getLivingPieceAt(a.fx, a.fy)
    if not before.attackAs and after and after.attackAs then
        killsBy(c, idx, a.fx, a.fy, nil, prefix, out, ctx)
    end
    -- A piece moved by the attack: one on a square that held nothing, or
    -- something else, before.
    local me = c.players[idx]
    for x=1, c.cols do
        for y=1, c.rows do
            local pc = c:getLivingPieceAt(x, y)
            if pc and heldAt(g, x, y)~=heldAt(c, x, y) then
                if pc.player==me then
                    killsBy(c, idx, x, y, nil, prefix, out, ctx)
                else
                    for _, own in ipairs(me.summons) do
                        if own:isAlive() then
                            local mr = own.moveRange or 0
                            local reach = mr + math.max(mr, own.attackRange or 0)
                            if cheb(own.pos[1], own.pos[2], x, y)<=reach then
                                killsBy(c, idx, own.pos[1], own.pos[2], {x, y}, prefix, out, ctx)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- After one of idx's pieces left (vx, vy) for (mx, my) (position `c`, key
-- `mid`): a frog of ours (or a parrot copying one) that the square was
-- blocking may now pull an enemy piece through it, from where it stands or
-- after hopping into line behind the square, or hop onto it and pull from
-- there. Adds those pulls and the kills they set up (see setupKills). People
-- clear a frog's line this way before a pull-and-kill.
local function vacatedSetups(c, idx, vx, vy, mx, my, mid, out, ctx)
    local me = c.players[idx]
    -- What a pull through the square could catch: in each direction, the
    -- nearest piece beyond it, if it is the opponent's.
    local targets = {}
    for _, d in ipairs{{1, 0}, {-1, 0}, {0, 1}, {0, -1}} do
        local x, y = vx+d[1], vy+d[2]
        while x>=1 and x<=c.cols and y>=1 and y<=c.rows do
            local pc = c:getLivingPieceAt(x, y)
            if pc then
                if pc.player~=me then targets[#targets+1] = {x, y, d[1], d[2]} end
                break
            end
            x, y = x+d[1], y+d[2]
        end
    end
    if #targets==0 then return end
    -- Whether (ox, oy) lies on the far side of the square from a target in
    -- direction (dx, dy).
    local function behind(ox, oy, dx, dy)
        local rx, ry = ox-vx, oy-vy
        return (dx==0 and rx==0 and ry*dy<0) or (dy==0 and ry==0 and rx*dx<0)
    end
    local function behindAny(ox, oy)
        for _, t in ipairs(targets) do
            if behind(ox, oy, t[3], t[4]) then return true end
        end
        return false
    end
    for _, f in ipairs(me.summons) do
        local hx, hy = f.pos[1], f.pos[2]
        if f:isAlive() and (f.attackAs or f.type)=='frog' and not (hx==mx and hy==my) then
            -- Where it can pull from: here, or a square it hops to that is
            -- the vacated one or behind it from a target.
            local origins = {}
            if behindAny(hx, hy) then
                origins[#origins+1] = {c, {}, hx, hy}
            end
            for _, b in ipairs(sim.pieceActions(c, me, hx, hy)) do
                if b.k=='move' and ((b.x==vx and b.y==vy) or behindAny(b.x, b.y))
                    and not c:getLivingPieceAt(b.x, b.y) then
                    local g1 = sim.clone(c)
                    if sim.apply(g1, g1.players[idx], b) and not sim.isOver(g1) and g1:isActivePlayer(g1.players[idx]) then
                        origins[#origins+1] = {g1, {{b, mid}}, b.x, b.y}
                    end
                end
                ctx.check()
            end
            for _, o in ipairs(origins) do
                local g1, pre, ox, oy = o[1], o[2], o[3], o[4]
                local h1 = #pre==0 and mid or nil
                for _, p in ipairs(sim.pieceActions(g1, g1.players[idx], ox, oy)) do
                    local through = false
                    if p.k=='attack' then
                        for _, t in ipairs(targets) do
                            if t[1]==p.x and t[2]==p.y and ((ox==vx and oy==vy) or behind(ox, oy, t[3], t[4])) then
                                through = true
                            end
                        end
                    end
                    if through then
                        local g2 = sim.clone(g1)
                        if sim.apply(g2, g2.players[idx], p) then
                            h1 = h1 or turnsearch.key(g1, idx)
                            setupKills(g1, g2, idx, p, append(pre, {p, h1}), out, ctx)
                        end
                    end
                    ctx.check()
                end
            end
        end
    end
end

-- The tactical extension's follow-ups to `a` (which took `g` to `c`, whose
-- key is `mid`): kills by the same piece in one action and, at `level` 2,
-- the kills `a` set up, after a move the moved piece's setups and the kills
-- they set up (a frog hops into line, pulls, and another piece takes), and
-- after a summon beside our parrot, the parrot copying it and the kills that
-- gives. At level 3, also a frog's pull through the square a move just
-- left (vacatedSetups).
local function followUps(g, c, idx, a, mid, level, ctx)
    local setups = level>1
    local out = {}
    if sim.isOver(c) or not c:isActivePlayer(c.players[idx]) then return out end
    local ax, ay
    if a.k=='move' then ax, ay = a.x, a.y
    elseif a.k=='attack' then ax, ay = a.fx, a.fy end
    if ax then
        local victims = aliveCount(c.players[3-idx])
        for _, f in ipairs(sim.captureActions(c, c.players[idx], ax, ay)) do
            local cc = sim.clone(c)
            if sim.apply(cc, cc.players[idx], f) then
                if sim.isOver(cc) or aliveCount(cc.players[3-idx])<victims then
                    out[#out+1] = {steps = {{f, mid}}, board = cc}
                elseif setups and a.k=='move' and f.k=='attack' then
                    setupKills(c, cc, idx, f, {{f, mid}}, out, ctx)
                end
            end
            ctx.check()
        end
    end
    if setups then
        if level>2 and a.k=='move' and c:getLivingPieceAt(a.x, a.y) then
            vacatedSetups(c, idx, a.fx, a.fy, a.x, a.y, mid, out, ctx)
        end
        -- A piece summoned beside our parrot: the parrot copies its attack at
        -- once and uses it.
        if a.k=='summon' then
            for _, px in ipairs{a.x-1, a.x+1} do
                local pp = px>=1 and px<=c.cols and c:getLivingPieceAt(px, a.y)
                if pp and pp.player==c.players[idx] and pp.type=='parrot' and not pp.attackAs then
                    local copy = {k='attack', fx=px, fy=a.y, x=a.x, y=a.y}
                    local cc = sim.clone(c)
                    if sim.apply(cc, cc.players[idx], copy) then
                        setupKills(c, cc, idx, copy, {{copy, mid}}, out, ctx)
                    end
                end
            end
        end
        setupKills(g, c, idx, a, {}, out, ctx)
    end
    return out
end

-- With `tactical`, every move or attack is also tried with each follow-up
-- by the same piece that takes a piece (sim.captureActions), and the pair
-- joins the same beam step: a move that sets up a capture (step then shoot,
-- a parrot copying a range before attacking) doesn't score better on its
-- own, so a narrow beam would drop it before the capture could follow.
-- `tactical` 2 also follows setups with the kills they make possible (see
-- followUps): a frog's pull and another piece's hit, a parrot's copy and
-- its attack. `tactical` 3 also tries a frog's pull through a square one
-- of our pieces just left.

-- With `noSummons`, summoning is left out, except a Wither (its summon
-- explodes): for modelling the opponent's reply, where summons crowd the
-- beam out of a second capture.
function turnsearch.search(root, idx, beam, depth, ctx, part, parts, scorer, tactical, noSummons)
    scorer = scorer or function(b) return eval.score(b, b.players[idx], 'opp') end
    local level = tactical==true and 1 or tactical or 0
    local rootNode = {
        board = root,
        seq = {},
        keys = {},
        score = scorer(root),
    }
    local all = {rootNode}
    local seen = {[turnsearch.key(root, idx)] = true}
    local frontier = {rootNode}
    for d=1, depth do
        local nextFrontier = {}
        for _, node in ipairs(frontier) do
            local b = node.board
            local p = b.players[idx]
            if not sim.isOver(b) and b:isActivePlayer(p) then
                local before = turnsearch.key(b, idx)
                local n = 0
                for _, a in ipairs(sim.actions(b, p)) do
                    if a.k~='end' and not (noSummons and a.k=='summon' and a.card~='wither') then
                        n = n+1
                        if d>1 or not parts or (n-1)%parts==part-1 then
                            local c = sim.clone(b)
                            if sim.apply(c, c.players[idx], a) then
                                local key = turnsearch.key(c, idx)
                                if not seen[key] then
                                    seen[key] = true
                                    local child = {
                                        board = c,
                                        seq = append(node.seq, a),
                                        keys = append(node.keys, before),
                                    }
                                    if level>0 then
                                        for _, f in ipairs(followUps(b, c, idx, a, key, level, ctx)) do
                                            local key2 = turnsearch.key(f.board, idx)
                                            if not seen[key2] then
                                                seen[key2] = true
                                                local seq, keys = child.seq, child.keys
                                                for _, st in ipairs(f.steps) do
                                                    seq = append(seq, st[1])
                                                    keys = append(keys, st[2])
                                                end
                                                local node2 = {board = f.board, seq = seq, keys = keys, score = scorer(f.board)}
                                                all[#all+1] = node2
                                                nextFrontier[#nextFrontier+1] = node2
                                            end
                                        end
                                    end
                                    child.score = scorer(c)
                                    all[#all+1] = child
                                    nextFrontier[#nextFrontier+1] = child
                                end
                            end
                        end
                        ctx.check()
                    end
                end
            end
        end
        if #nextFrontier==0 then break end
        table.sort(nextFrontier, function(x, y) return x.score>y.score end)
        for i=#nextFrontier, beam+1, -1 do nextFrontier[i] = nil end
        frontier = nextFrontier
    end
    table.sort(all, function(x, y) return x.score>y.score end)
    return all
end

return turnsearch
