-- What each workshop and furnace can make, and how to build one of its jobs without a
-- manager (plan section 16, P2-2.0). The table mirrors the filter templates of DFHack's
-- `dfhack.workshops.getJobs` (hack/lua/dfhack/workshops.lua, 53.16-r2) where it covers a
-- shop, adds the shops it misses (Forge, Craftsdwarf, Bowyer, Still, Farmer, Clothier,
-- Tanner, Ashery, glass and magma furnaces), and takes reactions from the raws by their
-- `building` entry. Reaction jobs get their item filters from the game's own
-- `reaction_reagent:contribute_to_job_req` vmethod (df.reaction.xml). Item filters for the
-- built-in jobs follow getJobs and DFHack's idle-crafting and autocheese scripts, which
-- create the same jobs in 53.x. Rows marked `unverified` were derived without a template
-- and need a live check that a dwarf starts them. Rows marked `order_only` are offered for
-- the work-order compatibility check but not built directly: their item needs (bags,
-- animals, containers of liquid) could not be confirmed.
--@ module = true

local materials = reqscript('internal/claude-bridge/materials')

MAX_JOBS = 10  -- dfhack.job.assignToWorkshop refuses past ten (Lua API, Job module)

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function enum_name(enum, value)
    local name = safe(function() return enum[value] end)
    if type(name) == 'string' then return name end
    return nil
end

----------------------------------------------------------------------------------------------
-- material modes

-- Plain words each mode accepts, for messages and the tasks listing.
local MODE_WORDS = {
    wood = {'wood'},
    stone = {'stone'},
    metal = {'a metal such as iron, copper, or steel'},
    ore = {'an ore such as hematite or native copper'},
    gem = {'a gem such as amethyst'},
    glass = {'green glass', 'clear glass', 'crystal glass'},
    leather = {'leather'},
    soft = {'cloth', 'silk', 'yarn'},
    bowyer = {'wood', 'bone'},
}

-- Craft materials and the job_item each needs (idle-crafting.lua, 53.16-r2).
local CRAFT_ITEMS = {
    wood = {item = {item_type = 'WOOD'}, category = 'wood'},
    bone = {item = {vector = 'ANY_REFUSE', flags1 = {unrotten = true},
                    flags2 = {bone = true, body_part = true}}, category = 'bone'},
    horn = {item = {vector = 'ANY_REFUSE', flags1 = {unrotten = true},
                    flags2 = {horn = true, body_part = true}}, category = 'horn'},
    shell = {item = {vector = 'ANY_REFUSE', flags1 = {unrotten = true},
                     flags2 = {shell = true, body_part = true}}, category = 'shell'},
    tooth = {item = {vector = 'ANY_REFUSE', flags1 = {unrotten = true},
                     flags2 = {ivory_tooth = true, body_part = true}}, category = 'tooth',
             unverified = true},
    pearl = {item = {vector = 'ANY_REFUSE', flags2 = {pearl = true}}, category = 'pearl',
             unverified = true},
    cloth = {item = {item_type = 'CLOTH', flags2 = {plant = true}}, category = 'cloth'},
    silk = {item = {item_type = 'CLOTH', flags2 = {silk = true}}, category = 'silk'},
    yarn = {item = {item_type = 'CLOTH', flags2 = {yarn = true}}, category = 'yarn'},
    leather = {item = {item_type = 'SKIN_TANNED'}, category = 'leather'},
}
local CRAFT_ORDER = {'stone', 'wood', 'bone', 'horn', 'shell', 'tooth', 'pearl', 'cloth',
                     'silk', 'yarn', 'leather'}

local STONE_ITEM = {item_type = 'BOULDER', mat_type = 0, flags3 = {hard = true},
                    flags2 = {non_economic = true}}
local FUEL_ITEM = {item_type = 'BAR', mat_type = 'COAL'}

----------------------------------------------------------------------------------------------
-- the table

-- A job entry: label, job token, mode (material handling), items (fixed filters for mode
-- 'fixed'), fields (extra job fields), kind (an item type whose subtypes become rows),
-- filter (picks subtypes), craft (allowed craft materials), unverified, order_only.
local function j(label, job, extra)
    local entry = {label = label, job = job}
    for k, v in pairs(extra or {}) do entry[k] = v end
    return entry
end

local function has_flag(def, flag)
    return safe(function() return def.flags[flag] end) == true
end

local function armor_flag(def, flag)
    return safe(function() return def.props.flags[flag] end) == true
end

local ARMOR_KINDS = {
    {job = 'MakeArmor', kind = 'ARMOR'}, {job = 'MakeHelm', kind = 'HELM'},
    {job = 'MakeGloves', kind = 'GLOVES'}, {job = 'MakeShoes', kind = 'SHOES'},
    {job = 'MakePants', kind = 'PANTS'},
}

local function armor_rows(flag, mode, extra)
    local rows = {}
    for _, a in ipairs(ARMOR_KINDS) do
        local row = j(nil, a.job, {kind = a.kind, mode = mode, unverified = true,
            filter = function(def) return armor_flag(def, flag) end})
        for k, v in pairs(extra or {}) do row[k] = v end
        table.insert(rows, row)
    end
    return rows
end

local function concat(...)
    local out = {}
    for _, list in ipairs({...}) do
        for _, v in ipairs(list) do table.insert(out, v) end
    end
    return out
end

local WOOD_FURNITURE = {
    j('bed', 'ConstructBed'), j('barrel', 'MakeBarrel'), j('bucket', 'MakeBucket'),
    j('animal trap', 'MakeAnimalTrap'), j('cage', 'MakeCage'), j('bin', 'ConstructBin'),
    j('armor stand', 'ConstructArmorStand'), j('blocks', 'ConstructBlocks'),
    j('chair', 'ConstructThrone'), j('coffin', 'ConstructCoffin'), j('door', 'ConstructDoor'),
    j('floodgate', 'ConstructFloodgate'), j('hatch cover', 'ConstructHatchCover'),
    j('grate', 'ConstructGrate'), j('cabinet', 'ConstructCabinet'), j('chest', 'ConstructChest'),
    j('table', 'ConstructTable'), j('weapon rack', 'ConstructWeaponRack'),
    j('splint', 'ConstructSplint'), j('crutch', 'ConstructCrutch'),
    j('pipe section', 'MakePipeSection', {unverified = true}),
}

local STONE_FURNITURE = {
    j('armor stand', 'ConstructArmorStand'), j('blocks', 'ConstructBlocks'),
    j('chair', 'ConstructThrone'), j('coffin', 'ConstructCoffin'), j('door', 'ConstructDoor'),
    j('floodgate', 'ConstructFloodgate'), j('hatch cover', 'ConstructHatchCover'),
    j('grate', 'ConstructGrate'), j('cabinet', 'ConstructCabinet'), j('chest', 'ConstructChest'),
    j('statue', 'ConstructStatue'), j('slab', 'ConstructSlab'), j('table', 'ConstructTable'),
    j('weapon rack', 'ConstructWeaponRack'), j('quern', 'ConstructQuern'),
    j('millstone', 'ConstructMillstone'),
}

local METAL_GOODS = {
    j('anvil', 'ForgeAnvil', {check = 'ITEMS_ANVIL'}), j('chain', 'MakeChain'),
    j('cage', 'MakeCage'), j('animal trap', 'MakeAnimalTrap'), j('bucket', 'MakeBucket'),
    j('barrel', 'MakeBarrel'), j('flask', 'MakeFlask'), j('goblet', 'MakeGoblet'),
    j('crafts', 'MakeCrafts'), j('coins', 'MintCoins'), j('pipe section', 'MakePipeSection'),
    j('ballista arrowhead', 'MakeBallistaArrowHead'), j('bed', 'ConstructBed'),
    j('chair', 'ConstructThrone'), j('door', 'ConstructDoor'),
    j('floodgate', 'ConstructFloodgate'), j('hatch cover', 'ConstructHatchCover'),
    j('grate', 'ConstructGrate'), j('cabinet', 'ConstructCabinet'), j('chest', 'ConstructChest'),
    j('table', 'ConstructTable'), j('statue', 'ConstructStatue'), j('blocks', 'ConstructBlocks'),
    j('armor stand', 'ConstructArmorStand'), j('weapon rack', 'ConstructWeaponRack'),
    j('coffin', 'ConstructCoffin'), j('splint', 'ConstructSplint'),
    j('crutch', 'ConstructCrutch'), j('bin', 'ConstructBin'),
    j(nil, 'MakeWeapon', {kind = 'WEAPON', check = 'weapon',
        filter = function(def) return not has_flag(def, 'TRAINING') end}),
    j(nil, 'MakeAmmo', {kind = 'AMMO', check = 'ITEMS_AMMO'}),
    j(nil, 'MakeShield', {kind = 'SHIELD', check = 'ITEMS_ARMOR'}),
    j(nil, 'MakeTrapComponent', {kind = 'TRAPCOMP', check = 'ITEMS_WEAPON',
        filter = function(def) return has_flag(def, 'METAL') end}),
    j(nil, 'MakeTool', {kind = 'TOOL', unverified = true,
        filter = function(def) return has_flag(def, 'METAL_MAT') end}),
    j(nil, 'MakeToy', {kind = 'TOY', unverified = true}),
    j('stud with metal', 'StudWith', {order_only = true}),
}

local function forge_jobs()
    local rows = {}
    for _, row in ipairs(METAL_GOODS) do
        local copy = {}
        for k, v in pairs(row) do copy[k] = v end
        copy.mode = 'metal'
        copy.unverified = true  -- bar counts and fuel are derived, not from a template
        table.insert(rows, copy)
    end
    for _, row in ipairs(armor_rows('METAL', 'metal', {check = 'ITEMS_ARMOR'})) do
        table.insert(rows, row)
    end
    return rows
end

local GLASS_GOODS = {
    j('crafts', 'MakeCrafts'), j('goblet', 'MakeGoblet'), j('vial', 'MakeFlask'),
    j('window', 'MakeWindow'), j('blocks', 'ConstructBlocks'), j('large gem', 'MakeGem'),
    j('pipe section', 'MakePipeSection'), j('terrarium', 'MakeCage'), j(nil, 'MakeToy', {kind = 'TOY'}),
    j(nil, 'MakeTool', {kind = 'TOOL',
        filter = function(def) return has_flag(def, 'GLASS_MAT') end}),
}

local function glass_jobs()
    local rows = {j('collect sand', 'CollectSand', {order_only = true}),
                  j('make raw glass', 'MakeRawGlass', {order_only = true})}
    for _, row in ipairs(GLASS_GOODS) do
        local copy = {}
        for k, v in pairs(row) do copy[k] = v end
        copy.mode = 'glass'
        copy.unverified = true
        table.insert(rows, copy)
    end
    return rows
end

local SHOPS = {}

SHOPS.Carpenters = {mode = 'wood', jobs = concat(WOOD_FURNITURE, {
    j(nil, 'MakeShield', {kind = 'SHIELD', unverified = true}),
    j(nil, 'MakeWeapon', {kind = 'WEAPON', unverified = true,
        filter = function(def) return has_flag(def, 'TRAINING') end}),
    j(nil, 'MakeTrapComponent', {kind = 'TRAPCOMP', unverified = true,
        filter = function(def) return has_flag(def, 'WOOD') end}),
    j(nil, 'MakeTool', {kind = 'TOOL', unverified = true,
        filter = function(def) return has_flag(def, 'WOOD_MAT') end}),
})}

SHOPS.Masons = {mode = 'stone', jobs = concat(STONE_FURNITURE, {
    j(nil, 'MakeTool', {kind = 'TOOL', unverified = true, filter = function(def)
        return has_flag(def, 'FURNITURE')
            and (has_flag(def, 'STONE_MAT') or has_flag(def, 'HARD_MAT'))
    end}),
})}

SHOPS.Mechanics = {mode = 'fixed', jobs = {
    j('mechanisms', 'ConstructMechanisms', {mode = 'stone'}),
    j('traction bench', 'ConstructTractionBench', {items = {
        {item_type = 'TABLE'}, {item_type = 'MECHANISM'}, {item_type = 'CHAIN'}}}),
}}

local function tool_crafts(def)
    local out = {}
    local function add(...) for _, w in ipairs({...}) do out[w] = true end end
    if has_flag(def, 'HARD_MAT') then add('stone', 'wood', 'bone', 'shell') end
    if has_flag(def, 'STONE_MAT') then add('stone') end
    if has_flag(def, 'WOOD_MAT') then add('wood') end
    if has_flag(def, 'BONE_MAT') then add('bone') end
    if has_flag(def, 'SHELL_MAT') then add('shell') end
    if has_flag(def, 'LEATHER_MAT') then add('leather') end
    if has_flag(def, 'SILK_MAT') then add('silk') end
    if has_flag(def, 'THREAD_PLANT_MAT') then add('cloth') end
    if has_flag(def, 'SOFT_MAT') then add('cloth', 'silk', 'yarn', 'leather') end
    return out
end

local ALL_CRAFTS = {}
for _, w in ipairs(CRAFT_ORDER) do ALL_CRAFTS[w] = true end

SHOPS.Craftsdwarfs = {mode = 'craft', jobs = {
    j('crafts', 'MakeCrafts', {craft = ALL_CRAFTS}),
    j('mug', 'MakeGoblet', {craft = {stone = true, wood = true}}),
    j(nil, 'MakeToy', {kind = 'TOY', unverified = true,
        craft = {stone = true, wood = true, bone = true, shell = true}}),
    j(nil, 'MakeTool', {kind = 'TOOL', unverified = true, craft_fn = tool_crafts,
        filter = function(def)
            if has_flag(def, 'FURNITURE') then return false end
            return next(tool_crafts(def)) ~= nil
        end}),
    j(nil, 'MakeAmmo', {kind = 'AMMO', unverified = true, craft = {bone = true}}),
    j('totem', 'MakeTotem', {mode = 'fixed', items = {
        {vector = 'ANY_REFUSE', flags1 = {unrotten = true},
         flags2 = {totemable = true, body_part = true}}}}),
    j('decorate with bone, shell, or horn', 'DecorateWith', {order_only = true}),
    j('engrave memorial slab', 'EngraveSlab', {order_only = true}),
}}

SHOPS.Jewelers = {mode = 'gem', jobs = {
    j('cut gems', 'CutGems', {item = {item_type = 'ROUGH', flags1 = {unrotten = true}}}),
    j('cut glass', 'CutGlass', {mode = 'glass', unverified = true}),
    j('encrust finished goods with gems', 'EncrustWithGems', {item = {item_type = 'SMALLGEM'},
        target = {flags1 = {improvable = true, finished_goods = true}}}),
    j('encrust ammo with gems', 'EncrustWithGems', {item = {item_type = 'SMALLGEM'},
        target = {flags1 = {improvable = true, ammo = true}}}),
    j('encrust furniture with gems', 'EncrustWithGems', {item = {item_type = 'SMALLGEM'},
        target = {flags1 = {improvable = true, furniture = true}}}),
}}

SHOPS.Fishery = {mode = 'fixed', jobs = {
    j('prepare raw fish', 'PrepareRawFish', {items = {
        {item_type = 'FISH_RAW', flags1 = {unrotten = true}}}}),
    j('extract from raw fish', 'ExtractFromRawFish', {items = {
        {flags1 = {unrotten = true, extract_bearing_fish = true}},
        {item_type = 'FLASK', flags1 = {empty = true, glass = true}}}}),
    j('catch live fish', 'CatchLiveFish', {order_only = true}),
}}

SHOPS.Butchers = {mode = 'fixed', jobs = {
    j('butcher an animal', 'ButcherAnimal', {items = {
        {flags1 = {butcherable = true, unrotten = true, nearby = true}}}}),
    j('extract from land animal', 'ExtractFromLandAnimal', {items = {
        {flags1 = {extract_bearing_vermin = true, unrotten = true}},
        {item_type = 'FLASK', flags1 = {empty = true, glass = true}}}}),
    j('catch live land animal', 'CatchLiveLandAnimal', {order_only = true}),
}}

local function thread(flag2, mat_type)
    return {item_type = 'THREAD', quantity = 15000, min_dimension = 15000,
            flags1 = {collected = true}, flags2 = flag2, mat_type = mat_type}
end

SHOPS.Loom = {mode = 'fixed', jobs = {
    j('weave plant thread cloth', 'WeaveCloth', {items = {thread({plant = true})}}),
    j('weave silk thread cloth', 'WeaveCloth', {items = {thread({silk = true})}}),
    j('weave yarn cloth', 'WeaveCloth', {items = {thread({yarn = true})}}),
    j('weave inorganic cloth', 'WeaveCloth', {items = {thread(nil, 0)}}),
    j('collect webs', 'CollectWebs', {items = {
        {item_type = 'THREAD', quantity = 10, min_dimension = 10, flags1 = {undisturbed = true}}}}),
}}

SHOPS.Leatherworks = {mode = 'leather', jobs = concat({
    j('leather bag', 'ConstructChest'), j('waterskin', 'MakeFlask'),
    j('backpack', 'MakeBackpack'), j('quiver', 'MakeQuiver'),
    j('sew leather image', 'SewImage', {order_only = true}),
}, armor_rows('LEATHER', 'leather'))}

SHOPS.Clothiers = {mode = 'soft', jobs = concat({
    j('cloth bag', 'ConstructChest', {unverified = true}),
    j('sew cloth image', 'SewImage', {order_only = true}),
}, armor_rows('SOFT', 'soft'))}

SHOPS.Dyers = {mode = 'fixed', jobs = {
    j('dye thread', 'DyeThread', {items = {
        {item_type = 'THREAD', quantity = 15000, min_dimension = 15000,
         flags1 = {collected = true}, flags2 = {dyeable = true}},
        {flags1 = {unrotten = true}, flags2 = {dye = true}}}}),
    -- getJobs gives this one the DyeThread job type; the job enum has DyeCloth for it.
    j('dye cloth', 'DyeCloth', {unverified = true, items = {
        {item_type = 'CLOTH', quantity = 10000, min_dimension = 10000, flags2 = {dyeable = true}},
        {flags1 = {unrotten = true}, flags2 = {dye = true}}}}),
}}

SHOPS.Siege = {mode = 'fixed', jobs = {
    j('ballista parts', 'ConstructBallistaParts', {items = {{item_type = 'WOOD'}}}),
    j('catapult parts', 'ConstructCatapultParts', {items = {{item_type = 'WOOD'}}}),
    j('ballista arrow', 'AssembleSiegeAmmo', {items = {{item_type = 'WOOD'}}}),
    j('tipped ballista arrow', 'AssembleSiegeAmmo', {items = {
        {item_type = 'WOOD'}, {item_type = 'BALLISTAARROWHEAD'}}}),
    j('bolt thrower parts', 'ConstructBoltThrowerParts', {order_only = true}),
}}

SHOPS.Kitchen = {mode = 'fixed', jobs = {
    j('prepare easy meal', 'PrepareMeal', {fields = {mat_type = 2}, items = {
        {flags1 = {unrotten = true, solid = true, cookable = true}},
        {flags1 = {unrotten = true, cookable = true}}}}),
    j('prepare fine meal', 'PrepareMeal', {fields = {mat_type = 3}, items = {
        {flags1 = {unrotten = true, solid = true, cookable = true}},
        {flags1 = {unrotten = true, cookable = true}},
        {flags1 = {unrotten = true, cookable = true}}}}),
    j('prepare lavish meal', 'PrepareMeal', {fields = {mat_type = 4}, items = {
        {flags1 = {unrotten = true, solid = true, cookable = true}},
        {flags1 = {unrotten = true, cookable = true}},
        {flags1 = {unrotten = true, cookable = true}},
        {flags1 = {unrotten = true, cookable = true}}}}),
}}

SHOPS.Bowyers = {mode = 'bowyer', jobs = {
    j(nil, 'MakeWeapon', {kind = 'WEAPON', unverified = true, filter = function(def)
        return safe(function() return def.ranged_ammo ~= '' end) == true
            and not has_flag(def, 'TRAINING')
    end}),
    j(nil, 'MakeAmmo', {kind = 'AMMO', unverified = true}),
}}

SHOPS.Still = {mode = 'fixed', jobs = {
    j('extract from plants', 'ExtractFromPlants', {order_only = true}),
}}

SHOPS.Farmers = {mode = 'fixed', jobs = {
    j('process plants', 'ProcessPlants', {unverified = true, items = {
        {item_type = 'PLANT', flags1 = {unrotten = true, processable = true}}}}),
    j('process plants to vial', 'ProcessPlantsVial', {order_only = true}),
    j('process plants to barrel', 'ProcessPlantsBarrel', {order_only = true}),
    j('make cheese', 'MakeCheese', {order_only = true}),
    j('milk animal', 'MilkCreature', {order_only = true}),
    j('shear animal', 'ShearCreature', {order_only = true}),
    j('spin thread', 'SpinThread', {order_only = true}),
}}

SHOPS.Quern = {mode = 'fixed', jobs = {j('mill plants', 'MillPlants', {order_only = true})}}
SHOPS.Millstone = SHOPS.Quern

SHOPS.Ashery = {mode = 'fixed', jobs = {
    j('make lye', 'MakeLye', {order_only = true}),
    j('make potash from lye', 'MakePotashFromLye', {order_only = true}),
    j('make potash from ash', 'MakePotashFromAsh', {order_only = true}),
}}

SHOPS.Kennels = {mode = 'fixed', jobs = {
    j('train hunting animal', 'TrainHuntingAnimal', {order_only = true}),
    j('train war animal', 'TrainWarAnimal', {order_only = true}),
}}

SHOPS.Tanners = {mode = 'fixed', jobs = {}}  -- tanning is a reaction (TAN_A_HIDE)

SHOPS.MetalsmithsForge = {mode = 'metal', fuel = true, jobs = forge_jobs()}
SHOPS.MagmaForge = {mode = 'metal', jobs = forge_jobs()}

local MELT_ITEM = {flags2 = {allow_melt_dump = true}}
local function smelter(fuel)
    return {mode = 'fixed', fuel = fuel, jobs = {
        j('melt metal object', 'MeltMetalObject', {items = {MELT_ITEM}, uses_fuel = true}),
        j('smelt ore', 'SmeltOre', {mode = 'ore'}),
    }}
end
SHOPS.Smelter = smelter(true)
SHOPS.MagmaSmelter = smelter(false)

SHOPS.WoodFurnace = {mode = 'fixed', jobs = {
    j('make charcoal', 'MakeCharcoal', {items = {{item_type = 'WOOD'}}}),
    j('make ash', 'MakeAsh', {items = {{item_type = 'WOOD'}}}),
}}

SHOPS.GlassFurnace = {mode = 'glass', fuel = true, jobs = glass_jobs()}
SHOPS.MagmaGlassFurnace = {mode = 'glass', jobs = glass_jobs()}

SHOPS.Kiln = {mode = 'fixed', fuel = true, jobs = {
    j('collect clay', 'CollectClay', {order_only = true}),
}}
SHOPS.MagmaKiln = {mode = 'fixed', jobs = SHOPS.Kiln.jobs}

----------------------------------------------------------------------------------------------
-- the fort's civ: permitted reactions and equipment

local function civ_raw()
    return safe(function()
        return df.historical_entity.find(df.global.plotinfo.civ_id).entity_raw
    end)
end

local EQUIPMENT_FIELDS = {
    WEAPON = {'weapon_id', 'digger_id'}, ARMOR = {'armor_id'}, HELM = {'helm_id'},
    GLOVES = {'gloves_id'}, SHOES = {'shoes_id'}, PANTS = {'pants_id'}, SHIELD = {'shield_id'},
    AMMO = {'ammo_id'}, TRAPCOMP = {'trapcomp_id'}, TOY = {'toy_id'}, TOOL = {'tool_id'},
}

-- Set of subtype indices the civ may make for this item kind, or nil when unreadable.
local function permitted_subtypes(raw, kind)
    if not raw then return nil end
    local set, any = {}, false
    for _, field in ipairs(EQUIPMENT_FIELDS[kind] or {}) do
        pcall(function()
            for _, st in ipairs(raw.equipment[field]) do
                set[st] = true
                any = true
            end
        end)
    end
    if not any then return nil end
    return set
end

local function permitted_reactions(raw)
    if not raw then return nil end
    local set, any = {}, false
    pcall(function()
        for _, idx in ipairs(raw.workshops.permitted_reaction_id) do
            set[idx] = true
            any = true
        end
    end)
    if not any then return nil end
    return set
end

local KIND_VECTORS = {
    WEAPON = 'weapons', ARMOR = 'armor', HELM = 'helms', GLOVES = 'gloves', SHOES = 'shoes',
    PANTS = 'pants', SHIELD = 'shields', AMMO = 'ammo', TRAPCOMP = 'trapcomps', TOY = 'toys',
    TOOL = 'tools',
}

----------------------------------------------------------------------------------------------
-- building identity

-- Key into SHOPS and the description of a building, or nil when not a workshop or furnace.
function shop_key(b)
    if df.building_workshopst:is_instance(b) then
        local t = enum_name(df.workshop_type, b.type)
        return t, df.building_type.Workshop
    elseif df.building_furnacest:is_instance(b) then
        local t = enum_name(df.furnace_type, b.type)
        return t, df.building_type.Furnace
    end
    return nil
end

local function is_magma(key)
    return type(key) == 'string' and key:match('^Magma') ~= nil
end

local function reaction_buildings(reaction)
    local types = safe(function() return reaction.building.type end)
    local subtypes = safe(function() return reaction.building.subtype end)
    local customs = safe(function() return reaction.building.custom end)
    return types, subtypes, customs
end

-- Reactions this building runs, as {index, reaction}.
local function reactions_for(b, btype)
    local out = {}
    local permitted = permitted_reactions(civ_raw())
    local custom = safe(function() return b.custom_type end) or -1
    pcall(function()
        for idx, reaction in ipairs(df.global.world.raws.reactions.reactions) do
            local types, subtypes, customs = reaction_buildings(reaction)
            local match = false
            if types then
                for k = 0, #types - 1 do
                    local st = subtypes and subtypes[k] or -1
                    local cu = customs and customs[k] or -1
                    if types[k] == btype and (st == -1 or st == b.type)
                        and (cu == -1 or cu == custom) then
                        match = true
                        break
                    end
                end
            end
            if match and (permitted == nil or permitted[idx]) then
                table.insert(out, {index = idx, reaction = reaction})
            end
        end
    end)
    return out
end

----------------------------------------------------------------------------------------------
-- task rows

local function mode_of(shop, entry)
    return entry.mode or (shop and shop.mode) or 'fixed'
end

local function craft_words(entry, def)
    local set = entry.craft_fn and def and entry.craft_fn(def) or entry.craft
    if not set then return nil end
    local out = {}
    for _, w in ipairs(CRAFT_ORDER) do
        if set[w] then table.insert(out, w) end
    end
    return out
end

local function material_words(mode, entry, def)
    if mode == 'craft' then return craft_words(entry, def) end
    if mode == 'fixed' then return nil end
    return MODE_WORDS[mode]
end

local function needs_material(mode)
    return mode == 'craft' or mode == 'metal' or mode == 'ore' or mode == 'gem'
        or mode == 'glass' or mode == 'soft' or mode == 'bowyer'
end

-- Every task this building offers. Each task: label, job (token), job_type, item {id,
-- name, subtype} for subtype rows, reaction {code, name, index}, mode, materials (words),
-- needs_material, direct (add_job builds it), unverified, plus the private `entry`/`def`.
function tasks(b)
    local key, btype = shop_key(b)
    if not key then return nil end
    local shop = SHOPS[key]
    local out = {}
    if shop then
        local raw = civ_raw()
        for _, entry in ipairs(shop.jobs) do
            local job_type = safe(function() return df.job_type[entry.job] end)
            if type(job_type) == 'number' then
                local mode = mode_of(shop, entry)
                if entry.kind then
                    local defs = safe(function()
                        return df.global.world.raws.itemdefs[KIND_VECTORS[entry.kind]]
                    end)
                    local allowed = permitted_subtypes(raw, entry.kind)
                    if defs then
                        for _, def in ipairs(defs) do
                            local ok = (allowed == nil or allowed[def.subtype])
                                and not has_flag(def, 'NO_DEFAULT_JOB')
                                and not has_flag(def, 'INCOMPLETE_ITEM')
                                and (entry.filter == nil or entry.filter(def))
                            if ok then
                                local words = material_words(mode, entry, def)
                                table.insert(out, {
                                    label = safe(function() return def.name end) or def.id,
                                    job = entry.job, job_type = job_type,
                                    item = {id = def.id, name = safe(function() return def.name end),
                                            subtype = def.subtype, kind = entry.kind},
                                    mode = mode, materials = words,
                                    needs_material = needs_material(mode),
                                    direct = not entry.order_only,
                                    unverified = entry.unverified or nil,
                                    entry = entry, def = def,
                                })
                            end
                        end
                    end
                else
                    table.insert(out, {
                        label = entry.label, job = entry.job, job_type = job_type,
                        mode = mode, materials = material_words(mode, entry),
                        needs_material = needs_material(mode) and not entry.order_only,
                        direct = not entry.order_only,
                        unverified = entry.unverified or nil,
                        entry = entry,
                    })
                end
            end
        end
    end
    for _, r in ipairs(reactions_for(b, btype)) do
        table.insert(out, {
            label = r.reaction.name, job = 'CustomReaction',
            job_type = df.job_type.CustomReaction,
            reaction = {code = r.reaction.code, name = r.reaction.name, index = r.index},
            mode = 'reaction', needs_material = false, direct = true,
        })
    end
    return out, key
end

-- Public view of a task row (no private fields).
function row(task)
    return {
        label = task.label,
        job = task.job,
        item = task.item and {id = task.item.id, name = task.item.name} or nil,
        reaction = task.reaction and {code = task.reaction.code, name = task.reaction.name} or nil,
        needs_material = task.needs_material,
        materials = task.materials,
        direct = task.direct,
        unverified = task.unverified,
    }
end

function labels(list, max)
    local out, seen = {}, {}
    for _, t in ipairs(list) do
        local l = t.label or t.job
        if not seen[l] then
            seen[l] = true
            table.insert(out, l)
        end
    end
    local more = 0
    if max and #out > max then
        more = #out - max
        local kept = {}
        for i = 1, max do kept[i] = out[i] end
        out = kept
    end
    return out, more
end

-- Whether a building offers a work order's job (or reaction). Returns ok, building key,
-- and the task list for the refusal message.
function offers(b, job_type, reaction_code)
    local list, key = tasks(b)
    if not list then return false, nil, {} end
    for _, t in ipairs(list) do
        if reaction_code then
            if t.reaction and t.reaction.code == reaction_code then return true, key, list end
        elseif t.job_type == job_type then
            return true, key, list
        end
    end
    return false, key, list
end

-- Find the task a request names: a reaction code or name, or a job word matched against
-- labels, item names and ids, captions, and job tokens. Returns the task or nil and the
-- list of candidates when the word is ambiguous.
function find(list, job, reaction, item)
    local function lower(s) return type(s) == 'string' and s:lower() or nil end
    if reaction ~= nil then
        local want = lower(tostring(reaction))
        for _, t in ipairs(list) do
            if t.reaction and (lower(t.reaction.code) == want or lower(t.reaction.name) == want) then
                return t
            end
        end
        return nil
    end
    local want = lower(tostring(job or ''))
    local want_item = item ~= nil and lower(tostring(item)) or nil
    local by_label, by_token = {}, {}
    for _, t in ipairs(list) do
        local caption = lower(safe(function() return df.job_type.attrs[t.job_type].caption end))
        local item_hit = t.item and (lower(t.item.id) == want_item or lower(t.item.name) == want_item)
        if lower(t.label) == want or (t.item and (lower(t.item.id) == want or lower(t.item.name) == want))
            or (t.reaction and lower(t.reaction.code) == want) then
            table.insert(by_label, t)
        elseif lower(t.job) == want or caption == want then
            if want_item == nil or item_hit then table.insert(by_token, t) end
        end
    end
    local hits = #by_label > 0 and by_label or by_token
    if #hits == 1 then return hits[1] end
    if #hits > 1 then return nil, hits end
    return nil
end

----------------------------------------------------------------------------------------------
-- building a job

local function set_flags(bitfield, names)
    for name, value in pairs(names or {}) do
        bitfield[name] = value
    end
end

local function builtin_mat(name)
    if type(name) == 'string' then return df.builtin_mats[name] end
    return name
end

-- A df.job_item from a plain filter table. Every field the struct leaves without an
-- init-value is set here (df.job.xml): item_subtype, mat_type, metal_ore, reaction_id.
local function new_job_item(spec)
    local ji = df.job_item:new()
    local ok, err = pcall(function()
        local item_type = spec.item_type and df.item_type[spec.item_type] or -1
        ji.item_type = item_type
        ji.item_subtype = spec.item_subtype or -1
        ji.mat_type = builtin_mat(spec.mat_type) or -1
        ji.mat_index = spec.mat_index or -1
        ji.quantity = spec.quantity or 1
        ji.min_dimension = spec.min_dimension or -1
        ji.metal_ore = -1
        ji.reaction_id = -1
        ji.reagent_index = -1
        pcall(function() ji.has_tool_use = -1 end)
        pcall(function() ji.dye_color = -1 end)
        local vector = spec.vector or spec.item_type
        local vid = vector and safe(function() return df.job_item_vector_id[vector] end)
        if type(vid) == 'number' then ji.vector_id = vid end
        set_flags(ji.flags1, spec.flags1)
        set_flags(ji.flags2, spec.flags2)
        set_flags(ji.flags3, spec.flags3)
    end)
    if not ok then
        pcall(function() ji:delete() end)
        error(err)
    end
    return ji
end

local function merge(base, extra)
    local out = {}
    for k, v in pairs(base or {}) do out[k] = v end
    for k, v in pairs(extra or {}) do out[k] = v end
    return out
end

local function material_flag(info, flag)
    return safe(function() return info.material.flags[flag] end) == true
end

local function mat_label(spec)
    return spec and spec.label or 'that material'
end

local function words_text(words)
    return table.concat(words or {}, ', ')
end

-- Resolve the request's material for a task. Returns plan {fields, items, category} or
-- nil, message. `fields` are job fields (mat_type, mat_index); `items` the job_items.
local function plan_material(task, material, shop)
    local mode = task.mode
    local entry = task.entry
    local spec, why = materials.resolve(material)
    if why then return nil, why end
    if spec and spec.form then
        return nil, ('"material" %s names an item form; workshop jobs take a material such as '
            .. '"any stone", "any wood", or "granite"'):format(tostring(material))
    end
    local info = spec and spec.mat_type ~= nil
        and safe(dfhack.matinfo.decode, spec.mat_type, spec.mat_index) or nil
    local class = info and materials.class_of(info) or nil
    local unknown = ('the game would list this task as "unknown material"; pass "material": %s')
        :format(words_text(task.materials))

    if mode == 'fixed' or mode == 'reaction' then
        if spec then
            return nil, ('"%s" takes no material; its items come from the task itself')
                :format(task.label or task.job)
        end
        local items = {}
        for _, it in ipairs(entry and entry.items or {}) do table.insert(items, it) end
        return {fields = merge({mat_type = -1}, entry and entry.fields), items = items,
                fuel = entry and entry.uses_fuel}
    end

    if mode == 'wood' then
        if spec and not (spec.category == 'wood' or spec.class == 'wood' or class == 'wood') then
            return nil, ('%s is not wood; the %s works wood only'):format(mat_label(spec), shop)
        end
        if info then
            return {fields = {mat_type = info.type, mat_index = info.index},
                    items = {{item_type = 'WOOD', mat_type = info.type, mat_index = info.index}}}
        end
        return {fields = {mat_type = -1}, category = 'wood', items = {{item_type = 'WOOD'}}}
    end

    if mode == 'stone' then
        if spec and not (spec.generic_inorganic or class == 'stone') then
            return nil, ('%s is not stone; this task takes "any stone" or a stone such as '
                .. '"granite"'):format(mat_label(spec))
        end
        if info then
            return {fields = {mat_type = 0, mat_index = info.index},
                    items = {merge(STONE_ITEM, {mat_index = info.index, flags2 = {}})}}
        end
        return {fields = {mat_type = 0, mat_index = -1}, items = {STONE_ITEM}}
    end

    if mode == 'metal' then
        if not info then return nil, unknown end
        if class ~= 'metal' then
            return nil, ('%s is not a metal; the %s works metal bars'):format(mat_label(spec), shop)
        end
        local check = entry and entry.check
        if check == 'weapon' then
            if not (material_flag(info, 'ITEMS_WEAPON') or material_flag(info, 'ITEMS_WEAPON_RANGED')
                    or material_flag(info, 'ITEMS_DIGGER')) then
                return nil, ('%s cannot be made into weapons'):format(mat_label(spec))
            end
        elseif check and not material_flag(info, check) then
            return nil, ('%s cannot be used for this item (needs %s)'):format(mat_label(spec), check)
        end
        local bars = 1
        local size = task.def and safe(function() return task.def.material_size end)
        if type(size) == 'number' and size > 3 then bars = math.floor(size / 3) end
        -- A metal bar is 150 units in reagent quantities ([REAGENT:A:150:BAR:...]).
        return {fields = {mat_type = 0, mat_index = info.index}, fuel = true,
                items = {{item_type = 'BAR', mat_type = 0, mat_index = info.index,
                          quantity = 150 * bars}}}
    end

    if mode == 'ore' then
        if not info then return nil, unknown end
        local ore = info.type == 0 and safe(function() return #info.inorganic.metal_ore.mat_index end)
        if not ore or ore == 0 then
            return nil, ('%s is not a metal ore'):format(mat_label(spec))
        end
        return {fields = {mat_type = 0, mat_index = info.index}, fuel = true,
                items = {{item_type = 'BOULDER', mat_type = 0, mat_index = info.index}}}
    end

    if mode == 'gem' then
        if not info then return nil, unknown end
        if class ~= 'gem' then return nil, ('%s is not a gem'):format(mat_label(spec)) end
        local items = {merge(entry.item, {mat_type = info.type, mat_index = info.index})}
        if entry.target then table.insert(items, entry.target) end
        return {fields = {mat_type = info.type, mat_index = info.index}, items = items}
    end

    if mode == 'glass' then
        if not info then return nil, unknown end
        if class ~= 'glass' then
            return nil, ('%s is not glass; pass green, clear, or crystal glass'):format(mat_label(spec))
        end
        return {fields = {mat_type = info.type, mat_index = info.index}, fuel = true,
                items = {{item_type = 'ROUGH', mat_type = info.type, mat_index = info.index}}}
    end

    if mode == 'leather' then
        if spec and not (spec.category == 'leather' or material_flag(info, 'LEATHER')) then
            return nil, ('%s is not leather'):format(mat_label(spec))
        end
        if info then
            return {fields = {mat_type = info.type, mat_index = info.index},
                    items = {{item_type = 'SKIN_TANNED', mat_type = info.type, mat_index = info.index}}}
        end
        return {fields = {mat_type = -1}, category = 'leather', items = {{item_type = 'SKIN_TANNED'}}}
    end

    if mode == 'soft' or mode == 'bowyer' or mode == 'craft' then
        local allowed = {}
        for _, w in ipairs(task.materials or {}) do allowed[w] = true end
        if not spec then return nil, unknown end
        local word = spec.category
        if spec.generic_inorganic or class == 'stone' then word = 'stone' end
        if class == 'wood' then word = 'wood' end
        if mode == 'soft' and word == 'plant' then word = 'cloth' end
        if not word or not allowed[word] then
            return nil, ('%s cannot be used here; this task takes %s')
                :format(mat_label(spec), words_text(task.materials))
        end
        if word == 'stone' then
            if info then
                return {fields = {mat_type = 0, mat_index = info.index},
                        items = {merge(STONE_ITEM, {mat_index = info.index, flags2 = {}})}}
            end
            return {fields = {mat_type = 0, mat_index = -1}, items = {STONE_ITEM}}
        end
        local craft = CRAFT_ITEMS[word]
        local item = craft.item
        if info then
            item = merge(item, {mat_type = info.type, mat_index = info.index})
            return {fields = {mat_type = info.type, mat_index = info.index}, items = {item}}
        end
        return {fields = {mat_type = -1}, category = craft.category, items = {item},
                unverified = craft.unverified}
    end

    return nil, 'this task cannot be built directly'
end

local function add_reaction_items(job, task)
    local reaction = df.global.world.raws.reactions.reactions[task.reaction.index]
    local before = #job.job_items.elements
    local ok = pcall(function()
        for i, reagent in ipairs(reaction.reagents) do
            reagent:contribute_to_job_req(job.job_items, i, task.reaction.index)
        end
    end)
    if ok and #job.job_items.elements > before then return true end
    -- Fallback: getJobs' reagentToJobItem, a field copy of each item reagent.
    for i, reagent in ipairs(reaction.reagents) do
        if df.reaction_reagent_itemst:is_instance(reagent) then
            local ji = new_job_item({quantity = reagent.quantity})
            ji.item_type = reagent.item_type
            ji.item_subtype = reagent.item_subtype
            ji.mat_type = reagent.mat_type
            ji.mat_index = reagent.mat_index
            ji.flags1.whole = reagent.flags1.whole
            ji.flags2.whole = reagent.flags2.whole
            ji.flags3.whole = reagent.flags3.whole
            ji.flags4 = reagent.flags4
            ji.flags5 = reagent.flags5
            ji.reaction_class = reagent.reaction_class
            ji.has_material_reaction_product = reagent.has_material_reaction_product
            ji.metal_ore = reagent.metal_ore
            ji.min_dimension = reagent.min_dimension
            pcall(function() ji.has_tool_use = reagent.has_tool_use end)
            ji.reaction_id = task.reaction.index
            ji.reagent_index = i
            job.job_items.elements:insert('#', ji)
        end
    end
    return false
end

-- Build and queue one job of `task` at building `b`. opts: material, repeat, do_now.
-- Returns the job, plus a list of notes; or nil, message.
function create_job(b, task, opts)
    local key = shop_key(b)
    local shop = SHOPS[key]
    if not task.direct then
        return nil, ('"%s" cannot be added directly yet (its item needs are not confirmed); '
            .. 'use create_work_order with workshop_id %d, which needs a manager'):format(
            task.label or task.job, b.id)
    end
    local plan, why = plan_material(task, opts.material, key)
    if not plan then return nil, why end
    local notes = {}
    local templates = {}
    for _, it in ipairs(plan.items) do table.insert(templates, it) end
    local wants_fuel = (plan.fuel or task.mode == 'reaction') and shop ~= nil and shop.fuel
        and not is_magma(key)
    if task.mode == 'reaction' then
        local reaction = df.global.world.raws.reactions.reactions[task.reaction.index]
        wants_fuel = safe(function() return reaction.flags.FUEL end) == true and not is_magma(key)
    end
    if wants_fuel then table.insert(templates, FUEL_ITEM) end

    -- Build the item filters first so a bad template fails before anything is linked.
    local built = {}
    local ok, err = pcall(function()
        for _, spec in ipairs(templates) do table.insert(built, new_job_item(spec)) end
    end)
    if not ok then
        for _, ji in ipairs(built) do pcall(function() ji:delete() end) end
        return nil, 'could not build the item filters: ' .. tostring(err)
    end

    -- createLinked then assignToWorkshop, as DFHack's autocheese and idle-crafting do.
    local job = dfhack.job.createLinked()
    job.job_type = task.job_type
    job.mat_type = -1
    job.mat_index = -1
    for field, value in pairs(plan.fields or {}) do job[field] = value end
    if plan.category then job.material_category[plan.category] = true end
    if task.item then job.item_subtype = task.item.subtype end
    if task.reaction then job.reaction_name = task.reaction.code end
    for _, ji in ipairs(built) do job.job_items.elements:insert('#', ji) end
    if task.reaction then
        if not add_reaction_items(job, task) then
            table.insert(notes, 'reagent filters were copied field by field; the game\'s own '
                .. 'contribute_to_job_req call failed')
        end
    end
    if opts['repeat'] then job.flags['repeat'] = true end
    if opts.do_now then job.flags.do_now = true end
    if not dfhack.job.assignToWorkshop(job, b) then
        dfhack.job.removeJob(job)
        return nil, ('workshop %d already holds %d jobs'):format(b.id, MAX_JOBS)
    end
    dfhack.job.checkBuildingsNow()
    if task.unverified or plan.unverified then
        table.insert(notes, 'this task\'s item filters are not yet confirmed in play; check '
            .. 'that a dwarf starts it')
    end
    return job, notes
end
