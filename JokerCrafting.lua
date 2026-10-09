--- Joker Crafting, by NickTG. v1.0.0 is v0.2.1 republished for the public release.
--- Every Joker you can get is a Common. Craft two Jokers of the same rarity into
--- one of the next rarity: pick 1 of 3. Common + Common to Uncommon, Uncommon +
--- Uncommon to Rare, Rare + Rare to Legendary.
---
--- DROP 2 (v0.2.0, 4 Oct 2026): crafting-table look, Test mode. Drop 1 was v0.1.0.
--- v0.2.1 (4 Oct): fix "Busy" refusing every Joker that had materialized (see pair_problem).
---
--- BUILT AGAINST WHAT NICK RUNS: Steamodded 1.0.0~BETA-1620a ("smods/..." below) and
--- the lovely dump of 2 Oct ("dump/..." below). Line numbers point into those.
---
--- HOW IT FITS TOGETHER
---   1. Commons only. Every vanilla Joker source (shop, Buffoon pack, Judgement,
---      The Soul, Wraith, Riff-raff, Tags) calls create_card('Joker', ...) without
---      a card key, and this mod rewrites the rarity there, exactly as Ep 004's
---      RarityLock does. Cards created BY KEY pass through untouched, which is how
---      the crafted Joker gets made (smods/src/utils.lua:415 passes the key in).
---   2. The gesture. Pull a Joker down off the Joker row (by more than half a card;
---      the row is at the top of the screen, G.jokers.T.y = 0) and drop it on another
---      Joker. Once pulled off, the drag stays a craft drag until release: dropped over
---      a Joker it opens the screen, dropped clear of every Joker it does nothing. While a Joker is pulled off the row
---      the row stops reordering, so the target stays put; a normal sideways drag
---      reorders as usual and can never craft. The Joker row re-sorts by position
---      every frame (dump/cardarea.lua:568), which is why the freeze is needed.
---   3. The drop opens a "Craft?" screen. Back costs nothing. Craft rolls three
---      offers of the next rarity and opens the pick screen (no Back). Both are
---      overlays like Run Info, which works in the shop, at blind select, between
---      hands and over an open pack. A booster pack could not be used: closing one
---      draws the hand back to the deck (dump/functions/button_callbacks.lua:2638).
---   4. Confirm closes the screen FIRST, then the two ingredients dissolve and the
---      pick is created with the carried edition. Nothing is removed or created
---      while a screen is open: Card:remove only frees a Joker for future shops
---      when no overlay is up (dump/card.lua:5242).
---
--- EVERY ROLL IS SEEDED, and rolled with the game unpaused: while paused,
--- pseudoseed returns math.random() (dump/functions/misc_functions.lua:330).

local THIS_MOD = SMODS.current_mod          -- must be captured at load time
local cfg      = THIS_MOD.config

----------------------------------------------------------------------
-- Config.
----------------------------------------------------------------------
if cfg.enabled      == nil then cfg.enabled      = true end
if cfg.commons_only == nil then cfg.commons_only = true end
if cfg.table_look   == nil then cfg.table_look   = true end    -- Drop 2 layout; off = Drop 1 layout
if cfg.test_mode    == nil then cfg.test_mode    = false end   -- Ctrl+1/2/3/E/J helpers, see section 5
local CONFIG_VERSION = 2
if cfg.cfg_version ~= CONFIG_VERSION then cfg.cfg_version = CONFIG_VERSION end

local COBALT = HEX('0047AB')
local LIGHT  = HEX('4A9EFF')

local RARITY_NAME = { [1] = 'Common', [2] = 'Uncommon', [3] = 'Rare', [4] = 'Legendary' }
local RARITY_NUM  = { Common = 1, Uncommon = 2, Rare = 3, Legendary = 4 }

--- The game's own rarity colours (dump/globals.lua:457): blue, green, red, purple.
local function rarity_colour(r)
    return (G.C.RARITY and G.C.RARITY[r]) or LIGHT
end
local LIFT = 0.55        -- card heights off the row before the drag counts as a craft drag

----------------------------------------------------------------------
-- Session state. Not saved: a quit mid-craft rewinds to before the craft (Nick, 4 Oct).
----------------------------------------------------------------------
local JC = {
    drag = nil,      -- { card, lifted, target } while a Joker is being dragged
    prompt = nil,    -- the "Craft?" screen's state
    pick = nil,      -- the pick screen's state
    busy = false,    -- from Confirm until the crafted Joker exists
}

local function log(msg)
    sendInfoMessage(msg, 'JokerCrafting')
end

----------------------------------------------------------------------
-- 1. Commons only. Same rewrite as RarityLock (Mods/NickTGMods/modules/raritylock.lua):
-- the roll value 0.3 means Common (dump/functions/common_events.lua:2241), and
-- legendary=false stops The Soul. Skipped when a card key is forced.
-- Turn OFF NickTGMods' RarityLock, ForceEdition and JudgementRun for this run:
-- all three also wrap create_card.
----------------------------------------------------------------------
local ref_create_card = create_card
function create_card(_type, area, legendary, _rarity, skip_materialize, soulable, forced_key, key_append)
    if cfg.enabled and cfg.commons_only and _type == 'Joker' and not forced_key then
        legendary = false
        _rarity = 0.3
    end
    return ref_create_card(_type, area, legendary, _rarity, skip_materialize, soulable, forced_key, key_append)
end

----------------------------------------------------------------------
-- Rules.
----------------------------------------------------------------------
local function rarity_of_center(center)
    local r = center and center.rarity
    if type(r) == 'string' then r = RARITY_NUM[r] end
    return r
end

local function rarity_of(card)
    return card and card.config and rarity_of_center(card.config.center)
end

local function edition_key(card)
    return card and card.edition and card.edition.key or nil
end

local function edition_name(key)
    if not key then return nil end
    local ok, name = pcall(localize, { type = 'name_text', set = 'Edition', key = key })
    if ok and type(name) == 'string' and name ~= 'ERROR' then return name end
    return (G.P_CENTERS[key] and G.P_CENTERS[key].name) or key
end

local function is_eternal(card)
    if card.ability and card.ability.eternal then return true end
    if SMODS.is_eternal then
        local ok, res = pcall(SMODS.is_eternal, card)
        if ok and res then return true end
    end
    return false
end

local function in_jokers(card)
    if not (G.jokers and card) then return false end
    for _, c in ipairs(G.jokers.cards) do
        if c == card then return true end
    end
    return false
end

--- nil when the two can be crafted together, otherwise the reason they can't.
local function pair_problem(a, b)
    if not (a and b) or a == b then return 'need two Jokers' end
    if not (in_jokers(a) and in_jokers(b)) then return 'both must be in your Joker row' end
    --- Not card.dissolve: every card that materializes keeps dissolve = 0 afterwards
    --- (dump/card.lua:2579, eased to 0), and 0 is true in Lua. That refused every crafted
    --- or materialized Joker as "Busy" in v0.2.0. The mod marks its own ingredients instead.
    if a.ntgjc_used or b.ntgjc_used or a.getting_sliced or b.getting_sliced
        or a.removed or b.removed or a.REMOVED or b.REMOVED then return 'already used' end
    if a.ability.set ~= 'Joker' or b.ability.set ~= 'Joker' then return 'only Jokers craft' end
    local ra, rb = rarity_of(a), rarity_of(b)
    if ra ~= rb then return 'different rarities' end
    if ra == 4 then return 'Legendaries cannot be crafted' end
    if not (ra == 1 or ra == 2 or ra == 3) then return 'this rarity cannot be crafted' end
    if is_eternal(a) or is_eternal(b) then return 'Eternal Jokers cannot be crafted' end
    return nil
end

local function pack_state(s)
    return s ~= nil and (s == G.STATES.SMODS_BOOSTER_OPENED or s == G.STATES.TAROT_PACK
        or s == G.STATES.PLANET_PACK or s == G.STATES.SPECTRAL_PACK
        or s == G.STATES.STANDARD_PACK or s == G.STATES.BUFFOON_PACK)
end

--- Crafting is allowed whenever selling a Joker would be: in the shop, at blind select,
--- between hands, and inside an open pack once its cards are out. Not while a hand is
--- played or scored (HAND_PLAYED), during draws (DRAW_TO_HAND), or in round evaluation.
local function craft_allowed()
    if not cfg.enabled or G.STAGE ~= G.STAGES.RUN then return false end
    if G.SETTINGS.paused or G.OVERLAY_MENU or JC.busy or not G.jokers then return false end
    local s = G.STATE
    if s == G.STATES.SHOP or s == G.STATES.BLIND_SELECT or s == G.STATES.SELECTING_HAND then return true end
    if pack_state(s) then
        return G.pack_cards ~= nil and not G.pack_cards.REMOVED and G.pack_cards.cards ~= nil and #G.pack_cards.cards > 0
    end
    return false
end

--- The Jokers of one rarity that could be offered, by key. get_current_pool returns a
--- SHARED table that the next call wipes (dump/functions/common_events.lua:2238), so it
--- is copied first. 'UNAVAILABLE' placeholders and anything of another rarity are dropped:
--- an exhausted pool silently returns {'j_joker'} (common_events.lua:2335). Asking by
--- rarity NAME gives a pool key with this mod's append, so crafting has its own stream.
local function offer_pool(rarity)
    local pool = get_current_pool('Joker', RARITY_NAME[rarity], nil, 'ntgjc')
    local list = {}
    for _, k in ipairs(pool or {}) do
        if k ~= 'UNAVAILABLE' and G.P_CENTERS[k] and rarity_of_center(G.P_CENTERS[k]) == rarity then
            list[#list + 1] = k
        end
    end
    return list
end

--- Up to three offers, without repeats. Rolled with the game unpaused (see header).
local function roll_offers(rarity)
    local was = G.SETTINGS.paused
    G.SETTINGS.paused = false
    local list = offer_pool(rarity)
    local offers = {}
    for _ = 1, 3 do
        if #list == 0 then break end
        local k, idx = pseudorandom_element(list, pseudoseed('ntgjc_craft' .. G.GAME.round_resets.ante))
        if not k then break end
        offers[#offers + 1] = k
        table.remove(list, idx)
    end
    G.SETTINGS.paused = was
    return offers
end

----------------------------------------------------------------------
-- 2. The gesture.
----------------------------------------------------------------------
local function rest_y(card)
    return G.jokers.T.y + G.jokers.T.h / 2 - card.T.h / 2
end

--- The Joker whose slot the dragged card's centre is over.
local function find_target(card)
    local cx = card.T.x + card.T.w / 2
    local best, best_d
    for _, c in ipairs(G.jokers.cards) do
        if c ~= card then
            local d = math.abs(c.T.x + c.T.w / 2 - cx)
            if d < c.T.w * 0.5 and (not best_d or d < best_d) then best, best_d = c, d end
        end
    end
    return best
end

--- A label that rides above the pulled Joker for the whole drag: what a drop there would do.
--- Drop 1 used a one-shot attention_text under the target; it faded in half a second and sat
--- behind JokerDisplay's box, so it was hard to read.
local SHORT_REASON = {
    ['different rarities'] = 'Different rarity',
    ['Legendaries cannot be crafted'] = 'Legendary is the top',
    ['Eternal Jokers cannot be crafted'] = 'Eternal',
    ['already used'] = 'Busy',
}

local function set_colour(dst, src)
    for i = 1, 4 do dst[i] = src[i] or 1 end
end

local function drag_label(D, text, colour)
    if not D.ui then
        D.lbl = { text = text }
        D.lbl_col = { 0, 0, 0, 1 }
        set_colour(D.lbl_col, colour)
        D.ui = UIBox({
            definition = { n = G.UIT.ROOT, config = { align = 'cm', colour = G.C.CLEAR }, nodes = {
                { n = G.UIT.C, config = { align = 'cm', padding = 0.08, r = 0.1, colour = D.lbl_col, emboss = 0.05 }, nodes = {
                    { n = G.UIT.T, config = { ref_table = D.lbl, ref_value = 'text', scale = 0.42, colour = G.C.WHITE, shadow = true } },
                } },
            } },
            config = { align = 'tm', offset = { x = 0, y = -0.12 }, major = D.card, bond = 'Strong', can_collide = false },
        })
        --- Drawn in the attention-text pass, after the Joker row and JokerDisplay's boxes and
        --- before the dragged card (dump/game.lua:2934-2968). The flag does nothing else.
        D.ui.attention_text = true
        return
    end
    if D.lbl.text ~= text then
        D.lbl.text = text
        set_colour(D.lbl_col, colour)
        D.ui:recalculate()
    end
end

local function drag_label_remove(D)
    if D and D.ui then
        D.ui:remove()
        D.ui = nil
    end
end
JC.drag_label_remove = drag_label_remove

--- Card has no drag of its own; this wraps Moveable:drag, which the controller calls
--- every frame for the card being dragged (dump/engine/controller.lua:382).
local ref_card_drag = Card.drag
function Card:drag(offset)
    local ret = ref_card_drag(self, offset)
    if G.jokers and self.area == G.jokers and self.states.drag.is then
        local D = JC.drag
        if not D or D.card ~= self then
            drag_label_remove(D)      -- a drag that ended without stop_drag (card removed mid-drag)
            D = { card = self }
            JC.drag = D
        end
        --- Once pulled off the row, the drag stays a craft drag until release, so bringing
        --- the card back down onto the target still crafts instead of reordering.
        D.lifted = D.lifted or (craft_allowed() and math.abs(self.T.y - rest_y(self)) > LIFT * self.T.h)
        local t = D.lifted and find_target(self) or nil
        if D.lifted then
            local allowed = craft_allowed()
            --- Worked out only when the target or the allowed state changes: the pool count
            --- calls get_current_pool, which is too heavy for every frame.
            if t ~= D.label_for or allowed ~= D.label_allowed or not D.ui then
                D.label_for, D.label_allowed = t, allowed
                if not allowed then
                    drag_label(D, "Can't craft now", G.C.UI.BACKGROUND_INACTIVE)
                elseif not t then
                    drag_label(D, 'Drop on a Joker', G.C.UI.BACKGROUND_INACTIVE)
                else
                    local bad = pair_problem(self, t)
                    local r = rarity_of(self)
                    if bad then
                        drag_label(D, SHORT_REASON[bad] or "Can't craft", G.C.RED)
                    elseif #offer_pool(r + 1) == 0 then
                        drag_label(D, 'No ' .. RARITY_NAME[r + 1] .. ' left', G.C.RED)
                    else
                        drag_label(D, 'Craft: ' .. RARITY_NAME[r + 1], COBALT)
                    end
                end
            end
        end
        if t ~= D.target then
            D.target = t
            if t then
                t:juice_up(0.25, 0.25)
                play_sound('cardSlide1', pair_problem(self, t) and 0.8 or 1.25, 0.5)
            end
        end
    end
    return ret
end

--- While a Joker is pulled off the row, the row keeps its order. align_cards places every
--- card by its index BEFORE it sorts (dump/cardarea.lua:546-568), so putting the old order
--- back after the call leaves every position consistent with it. When the drag ends the
--- card is placed back into its own slot by index, so an abandoned craft drag never
--- reorders anything.
local ref_align = CardArea.align_cards
function CardArea:align_cards()
    local D = JC.drag
    if self == G.jokers and D and D.lifted and D.card and D.card.states.drag.is then
        local saved = {}
        for i, c in ipairs(self.cards) do saved[i] = c end
        local ret = ref_align(self)
        local same = self.cards ~= nil and #saved == #self.cards
        for _, c in ipairs(saved) do
            if c.area ~= self then same = false end
        end
        if same then
            for i, c in ipairs(saved) do
                self.cards[i] = c
                c.rank = i      -- align_cards sets ranks after its sort (cardarea.lua:582)
            end
        end
        return ret
    end
    return ref_align(self)
end

--- The controller calls stop_drag just before it clears the drag (controller.lua:334).
local ref_stop_drag = Card.stop_drag
function Card:stop_drag()
    local D = JC.drag
    local ret = ref_stop_drag(self)
    if D and D.card == self then
        JC.drag = nil
        drag_label_remove(D)
        if D.lifted and D.target and craft_allowed() then
            local a, b = self, D.target
            local bad = pair_problem(a, b)
            if bad then
                play_sound('cancel', 0.8, 0.5)
                log('Drop refused: ' .. bad)
            else
                --- Opened on the next event tick rather than inside the controller update.
                G.E_MANAGER:add_event(Event({ trigger = 'immediate', blocking = false, blockable = false, func = function()
                    JC.open_prompt(a, b)
                    return true
                end }))
            end
        end
    end
    return ret
end

--- Node:remove clears the controller's drag without calling stop_drag (dump/engine/node.lua:355),
--- for example Handy selling the held card. Take the label down with it.
local ref_card_remove = Card.remove
function Card:remove()
    if JC.drag and JC.drag.card == self then
        drag_label_remove(JC.drag)
        JC.drag = nil
    end
    return ref_card_remove(self)
end

----------------------------------------------------------------------
-- Display cards for the two screens. Created with Card() and never added to the
-- deck, so no Joker effect runs. A card created while no overlay is up marks its key
-- as owned (dump/card.lua:472-475), which would hide an OFFERED Joker from later
-- shops and packs, so the owned-Joker record is put back as it was.
----------------------------------------------------------------------
local function display_card(key, edition)
    local was = G.GAME.used_jokers[key]
    local c = Card(0, 0, G.CARD_W, G.CARD_H, nil, G.P_CENTERS[key],
        { bypass_discovery_center = true, bypass_discovery_ui = true })
    G.GAME.used_jokers[key] = was
    if edition then c:set_edition(edition, true, true) end
    c.ntgjc_key = key
    return c
end

local function no_highlight(self, card) return false end

local function display_area(n, selectable)
    local area = CardArea(G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2, G.ROOM.T.h, math.max(n, 1) * G.CARD_W * 1.15, G.CARD_H * 1.1, {
        card_limit = math.max(n, 1), type = 'title', highlight_limit = selectable and 1 or 0, card_w = G.CARD_W,
    })
    if not selectable then area.can_highlight = no_highlight end
    return area
end

--- A highlighted Joker grows Use and Sell buttons (dump/card.lua:5049), and Sell on a
--- display card would pay out, so they are removed straight away.
local function strip_buttons(card)
    if card.children.use_button then
        card.children.use_button:remove()
        card.children.use_button = nil
    end
end

local function pick_can_highlight(self, card) return JC.pick ~= nil end

local function pick_add(self, card, silent)
    for i = #self.highlighted, 1, -1 do
        local h = self.highlighted[i]
        table.remove(self.highlighted, i)
        h:highlight(false)
        strip_buttons(h)
    end
    self.highlighted[1] = card
    card:highlight(true)
    strip_buttons(card)
    if JC.pick then JC.pick.chosen = card.ntgjc_key end
    if not silent then play_sound('cardSlide1') end
end

local function pick_remove(self, card, force)
    for i = #self.highlighted, 1, -1 do
        if self.highlighted[i] == card then table.remove(self.highlighted, i) end
    end
    card:highlight(false)
    strip_buttons(card)
    if not force and JC.pick and JC.pick.chosen == card.ntgjc_key then JC.pick.chosen = nil end
end

local function pick_unhighlight_all(self) end

----------------------------------------------------------------------
-- UI pieces.
----------------------------------------------------------------------
local function text_row(text, scale, colour)
    return { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
        { n = G.UIT.T, config = { text = text, scale = scale or 0.35, colour = colour or G.C.UI.TEXT_LIGHT, shadow = true } },
    } }
end

local function button(label, scale, minh, colour, btn, func, extra)
    local config = { align = 'cm', minw = 2.6, minh = minh, padding = 0.1, r = 0.1, hover = true, shadow = true,
        colour = colour, button = btn, func = func }
    for k, v in pairs(extra or {}) do config[k] = v end
    return { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
        { n = G.UIT.C, config = config, nodes = {
            { n = G.UIT.T, config = { text = label, scale = scale, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
        } },
    } }
end

local function framed(contents)
    return create_UIBox_generic_options({ no_back = true, outline_colour = COBALT, contents = contents })
end

----------------------------------------------------------------------
-- 3a. The "Craft?" screen.
----------------------------------------------------------------------
local function slot(contents, colour)
    return { n = G.UIT.C, config = { align = 'cm', padding = 0.1, r = 0.1, colour = colour or G.C.BLACK, emboss = 0.05 }, nodes = contents }
end

local function symbol(text)
    return { n = G.UIT.C, config = { align = 'cm', padding = 0.05 }, nodes = {
        { n = G.UIT.T, config = { text = text, scale = 0.9, colour = G.C.WHITE, shadow = true } },
    } }
end

--- The info lines and buttons shared by both layouts.
local function prompt_rows(P, into, with_title)
    local rows = {}
    local function add(node) rows[#rows + 1] = node end
    if with_title then
        add({ n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
            { n = G.UIT.T, config = { text = 'Craft?', scale = 0.7, colour = G.C.WHITE, shadow = true } },
        } })
        add(text_row((P.next == 2 and 'into an ' or 'into a ') .. into .. ' Joker', 0.38))
    end
    if P.available > 0 then
        add(text_row('Pick 1 of ' .. math.min(3, P.available) .. ' ' .. into .. ' Jokers', 0.4, with_title and LIGHT or G.C.WHITE))
    else
        add(text_row('No ' .. into .. ' Jokers left to offer', 0.4, G.C.RED))
    end
    local ea, eb = edition_key(P.a), edition_key(P.b)
    if ea and eb and ea ~= eb then
        add(text_row('You choose which edition carries over', 0.32))
    elseif ea or eb then
        add(text_row(edition_name(ea or eb) .. ' carries over', 0.32))
    end
    add(text_row('Both Jokers are used up', 0.32))
    return rows
end

local function prompt_buttons(P)
    return {
        button('Craft', 0.5, 0.75, P.available > 0 and COBALT or G.C.UI.BACKGROUND_INACTIVE,
            P.available > 0 and 'ntgjc_craft' or nil, nil),
        button(localize('b_back'), 0.45, 0.6, G.C.ORANGE, 'ntgjc_back', nil),
    }
end

local function prompt_definition()
    local P = JC.prompt
    local into = RARITY_NAME[P.next]
    local ingredients = {}
    for i, c in ipairs({ P.a, P.b }) do
        local area = display_area(1, false)
        local d = display_card(c.config.center.key, edition_key(c))
        area:emplace(d)
        d.states.drag.can = false   -- after emplace: set_ranks turns it back on (cardarea.lua:256)
        ingredients[i] = area
    end

    if not cfg.table_look then
        --- Drop 1 layout: the two ingredients side by side, the words and buttons to the right.
        local rows = prompt_rows(P, into, true)
        for _, b in ipairs(prompt_buttons(P)) do rows[#rows + 1] = b end
        return framed({
            { n = G.UIT.R, config = { align = 'cm' }, nodes = {
                slot({ { n = G.UIT.O, config = { object = ingredients[1] } }, { n = G.UIT.O, config = { object = ingredients[2] } } }),
                { n = G.UIT.B, config = { w = 0.2, h = 0.1 } },
                { n = G.UIT.C, config = { align = 'cm', padding = 0.1, minw = 3.6 }, nodes = rows },
            } },
        })
    end

    --- Drop 2 layout, the crafting table: [Joker] + [Joker] = [ ? ], the empty output slot
    --- outlined in the next rarity's colour, then the words and the buttons underneath.
    local col = rarity_colour(P.next)
    local output = { n = G.UIT.C, config = { align = 'cm', minw = G.CARD_W * 1.15, minh = G.CARD_H * 1.1, r = 0.1,
        colour = G.C.BLACK, emboss = 0.05, outline = 1.5, outline_colour = col }, nodes = {
        { n = G.UIT.R, config = { align = 'cm' }, nodes = {
            { n = G.UIT.T, config = { text = '?', scale = 1.3, colour = col, shadow = true } },
        } },
    } }
    local info = prompt_rows(P, into, false)
    local btns = prompt_buttons(P)
    return framed({
        { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
            { n = G.UIT.T, config = { text = 'Craft?', scale = 0.75, colour = G.C.WHITE, shadow = true } },
        } },
        { n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
            slot({ { n = G.UIT.O, config = { object = ingredients[1] } } }),
            symbol('+'),
            slot({ { n = G.UIT.O, config = { object = ingredients[2] } } }),
            symbol('='),
            output,
        } },
        { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
            { n = G.UIT.T, config = { text = (P.next == 2 and 'an ' or 'a ') .. into .. ' Joker', scale = 0.5, colour = col, shadow = true } },
        } },
        { n = G.UIT.R, config = { align = 'cm' }, nodes = {
            { n = G.UIT.C, config = { align = 'cm', padding = 0.05 }, nodes = info },
        } },
        { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
            { n = G.UIT.C, config = { align = 'cm' }, nodes = { btns[1] } },
            { n = G.UIT.C, config = { align = 'cm' }, nodes = { btns[2] } },
        } },
    })
end

function JC.open_prompt(a, b)
    if not craft_allowed() then return end
    local bad = pair_problem(a, b)
    if bad then
        log('Craft screen not opened: ' .. bad)
        return
    end
    local r = rarity_of(a)
    --- Counting the pool uses no randomness: the rarity is given, so get_current_pool
    --- never polls one (common_events.lua:2244).
    JC.prompt = { a = a, b = b, rarity = r, next = r + 1, available = #offer_pool(r + 1) }
    G.SETTINGS.paused = true
    G.FUNCS.overlay_menu { definition = prompt_definition() }
    log(('Craft screen: %s + %s (%s), %d %s available'):format(a.config.center.key, b.config.center.key,
        RARITY_NAME[r], JC.prompt.available, RARITY_NAME[r + 1]))
end

G.FUNCS.ntgjc_back = function(e)
    JC.prompt = nil
    G.FUNCS.exit_overlay_menu()
    log('Craft screen: Back')
end

----------------------------------------------------------------------
-- 3b. The pick screen.
----------------------------------------------------------------------
local function pick_definition()
    local P = JC.pick
    local area = display_area(#P.offers, true)
    area.can_highlight = pick_can_highlight
    area.add_to_highlighted = pick_add
    area.remove_from_highlighted = pick_remove
    area.unhighlight_all = pick_unhighlight_all
    P.cards = {}
    for _, k in ipairs(P.offers) do
        local c = display_card(k, P.edition)
        area:emplace(c)
        c.states.drag.can = false
        P.cards[#P.cards + 1] = c
    end
    local info = { n = G.UIT.C, config = { align = 'cm', padding = 0.1, minw = 3.6 }, nodes = {
        { n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
            { n = G.UIT.T, config = { text = 'Pick one', scale = 0.7, colour = G.C.WHITE, shadow = true } },
        } },
        text_row(RARITY_NAME[P.next] .. ' Joker', 0.45, rarity_colour(P.next)),
    } }
    if P.editions then
        info.nodes[#info.nodes + 1] = text_row('Edition that carries over:', 0.32)
        for i, ek in ipairs(P.editions) do
            info.nodes[#info.nodes + 1] = button(edition_name(ek), 0.4, 0.5, G.C.UI.BACKGROUND_INACTIVE,
                'ntgjc_edition', 'ntgjc_edition_colour', { ntgjc_index = i })
        end
    elseif P.edition then
        info.nodes[#info.nodes + 1] = text_row(edition_name(P.edition) .. ' carries over', 0.32)
    end
    --- Built WITH its button, which the func clears until a Joker is picked. An element
    --- only becomes clickable if it has a button when it is built (dump/engine/ui.lua:391).
    info.nodes[#info.nodes + 1] = button('Confirm', 0.5, 0.75, G.C.UI.BACKGROUND_INACTIVE, 'ntgjc_confirm', 'ntgjc_can_confirm')
    return framed({
        { n = G.UIT.R, config = { align = 'cm' }, nodes = {
            { n = G.UIT.C, config = { align = 'cm', padding = 0.1, r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = {
                { n = G.UIT.O, config = { object = area } },
            } },
            { n = G.UIT.B, config = { w = 0.2, h = 0.1 } },
            info,
        } },
    })
end

G.FUNCS.ntgjc_craft = function(e)
    local P = JC.prompt
    if not P then return end
    JC.prompt = nil
    local bad = pair_problem(P.a, P.b)
    if bad then
        G.FUNCS.exit_overlay_menu()
        log('Craft cancelled: ' .. bad)
        return
    end
    local offers = roll_offers(P.next)
    if not offers[1] then
        G.FUNCS.exit_overlay_menu()
        log('Craft cancelled: nothing to offer')
        return
    end
    local ea, eb = edition_key(P.a), edition_key(P.b)
    JC.pick = {
        a = P.a, b = P.b, next = P.next, offers = offers, chosen = nil,
        editions = (ea and eb and ea ~= eb) and { ea, eb } or nil,
        edition = ea or eb,
    }
    --- overlay_menu replaces the open screen and the game stays paused
    --- (dump/functions/button_callbacks.lua:1347).
    G.FUNCS.overlay_menu { definition = pick_definition(), config = { no_esc = true } }
    log(('Craft: %s + %s -> offers %s'):format(P.a.config.center.key, P.b.config.center.key, table.concat(offers, ', ')))
end

G.FUNCS.ntgjc_edition = function(e)
    local P = JC.pick
    local i = e and e.config and e.config.ntgjc_index
    if not (P and P.editions and i and P.editions[i]) then return end
    if P.edition == P.editions[i] then return end
    P.edition = P.editions[i]
    for _, c in ipairs(P.cards or {}) do c:set_edition(P.edition, true, true) end
    play_sound('cardSlide1')
end

G.FUNCS.ntgjc_edition_colour = function(e)
    local P = JC.pick
    local i = e.config.ntgjc_index
    e.config.colour = (P and P.editions and P.edition == P.editions[i]) and COBALT or G.C.UI.BACKGROUND_INACTIVE
end

G.FUNCS.ntgjc_can_confirm = function(e)
    if JC.pick and JC.pick.chosen then
        e.config.colour = COBALT
        e.config.button = 'ntgjc_confirm'
    else
        e.config.colour = G.C.UI.BACKGROUND_INACTIVE
        e.config.button = nil
    end
end

----------------------------------------------------------------------
-- 4. Finish: close the screen, then the ingredients dissolve, then the pick appears.
----------------------------------------------------------------------
local function finish(P)
    local bad = pair_problem(P.a, P.b)
    if bad then
        log('Craft cancelled after the pick: ' .. bad)
        return
    end
    JC.busy = true
    for _, c in ipairs({ P.a, P.b }) do
        if c.highlighted and G.jokers then G.jokers:remove_from_highlighted(c, true) end
        --- start_dissolve without getting_sliced: no destroy signal, only the normal
        --- remove_from_deck effects, the same as selling (dump/card.lua:2498, :829).
        c.ntgjc_used = true
        c:start_dissolve()
    end
    play_sound('tarot1', 1.1, 0.6)
    local key, edition = P.chosen, P.edition
    --- The ingredients leave G.jokers at 1.05 x 0.7 = 0.735 s (dump/card.lua:2523, 2562-2566).
    --- The pick arrives after that, so the row never holds one Joker too many, and
    --- busy stays on until then, so a dissolving Joker can't be dragged into a new craft.
    G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.85, blockable = false, func = function()
        if G.jokers and G.STAGE == G.STAGES.RUN then
            local card = SMODS.add_card({ key = key, area = G.jokers, edition = edition, no_edition = not edition, key_append = 'ntgjc' })
            if card and card.start_materialize then card:start_materialize() end
            log(('Crafted %s%s from %s + %s'):format(key, edition and (' (' .. edition .. ')') or '',
                P.a.config.center.key, P.b.config.center.key))
        end
        JC.busy = false
        return true
    end }))
end

G.FUNCS.ntgjc_confirm = function(e)
    local P = JC.pick
    if not (P and P.chosen) then return end
    JC.pick = nil
    G.FUNCS.exit_overlay_menu()
    finish(P)
end

----------------------------------------------------------------------
-- 5. Test mode (config tab, off by default). For testing only, never for recording:
--    Ctrl+1 / Ctrl+2 / Ctrl+3  add two random Commons / Uncommons / Rares
--    Ctrl+E                    cycle the edition of the rightmost Joker
--    Ctrl+J                    one more Joker slot
-- Picks use math.random, not the run's seeded streams. Adding To Do List still advances its
-- own seeded stream when the card sets itself up (dump/card.lua:426-436); harmless for testing.
----------------------------------------------------------------------
local EDITION_CYCLE = { 'e_foil', 'e_holo', 'e_polychrome', 'e_negative' }

--- Same moments as crafting: shop, blind select, between hands, an open pack.
local function test_ready()
    return cfg.test_mode and craft_allowed()
end

local function test_add_pair(rarity)
    if not test_ready() then return end
    local list = offer_pool(rarity)
    if #list == 0 then
        log('Test mode: no ' .. RARITY_NAME[rarity] .. ' Jokers left to add')
        return
    end
    local added = {}
    for _ = 1, 2 do
        local k = list[math.random(#list)]
        SMODS.add_card({ key = k, area = G.jokers, no_edition = true, key_append = 'ntgjc_test' })
        added[#added + 1] = k
    end
    log('Test mode: added ' .. table.concat(added, ' + '))
end

local function test_cycle_edition()
    if not test_ready() then return end
    local c = G.jokers.cards[#G.jokers.cards]
    if not c then return end
    local cur, nxt = edition_key(c), EDITION_CYCLE[1]
    for i, e in ipairs(EDITION_CYCLE) do
        if e == cur then nxt = EDITION_CYCLE[i + 1] end
    end
    c:set_edition(nxt, true)
    log(('Test mode: %s edition %s -> %s'):format(c.config.center.key, tostring(cur), tostring(nxt)))
end

local function test_add_slot()
    if not test_ready() then return end
    G.jokers:change_size(1)   -- Steamodded's slot bookkeeping (dump/cardarea.lua:111)
    log('Test mode: one more Joker slot')
end

for _, kb in ipairs({
    { '1', function() test_add_pair(1) end },
    { '2', function() test_add_pair(2) end },
    { '3', function() test_add_pair(3) end },
    { 'e', test_cycle_edition },
    { 'j', test_add_slot },
}) do
    SMODS.Keybind({ key = 'ntgjc_test_' .. kb[1], key_pressed = kb[1], held_keys = { 'lctrl' }, action = kb[2] })
end

----------------------------------------------------------------------
-- New run or Continue: clear the session state and log what matters for the run.
----------------------------------------------------------------------
local ref_start_run = Game.start_run
function Game:start_run(args)
    drag_label_remove(JC.drag)
    JC.drag, JC.prompt, JC.pick, JC.busy = nil, nil, nil, false
    local ret = ref_start_run(self, args)
    --- object_weights is a Steamodded option, off unless a mod turns it on. With it on the
    --- shop rolls through smods weights.lua; the Commons lock should still hold there
    --- (inferred from source, not tested), so it is logged in case a run shows otherwise.
    log(('Run start: v%s enabled=%s commons_only=%s table_look=%s test_mode=%s object_weights=%s'):format(
        tostring(THIS_MOD.version), tostring(cfg.enabled), tostring(cfg.commons_only), tostring(cfg.table_look),
        tostring(cfg.test_mode), tostring(SMODS.optional_features and SMODS.optional_features.object_weights)))
    return ret
end

----------------------------------------------------------------------
-- Config tab.
----------------------------------------------------------------------
THIS_MOD.config_tab = function()
    local function toggle(label, key)
        return { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
            create_toggle({ label = label, ref_table = cfg, ref_value = key }),
        } }
    end
    return {
        n = G.UIT.ROOT,
        config = { align = 'cm', padding = 0.1, colour = G.C.CLEAR },
        nodes = {
            toggle('Enable Joker Crafting', 'enabled'),
            text_row('Pull a Joker down off the row and drop it on another of the same rarity to craft.', 0.3),
            toggle('Commons only', 'commons_only'),
            text_row('Every Joker the game gives you is a Common. Turn off only for testing.', 0.3),
            toggle('Crafting table look', 'table_look'),
            text_row('Joker + Joker = ?   Off shows the plain layout from v0.1.0.', 0.3),
            toggle('Test mode', 'test_mode'),
            text_row('Left Ctrl + 1 / 2 / 3: two Commons / Uncommons / Rares.', 0.3),
            text_row('Left Ctrl + E: next edition on the rightmost Joker.  Left Ctrl + J: one more slot.', 0.3),
            text_row('Testing only. Turn it off before recording.', 0.3, G.C.RED),
        },
    }
end
