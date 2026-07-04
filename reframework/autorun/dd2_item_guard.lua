-- Dragon's Dogma 2 Item Guard - guarded item min/fixed counts
-- Place this file at: reframework/autorun/dd2_item_guard.lua
--
-- Defaults are safe: enforcement is disabled until explicitly enabled in UI.
-- Configured shortages are restored by calling ItemManager:getItem() with the
-- current player CharaID.

local MOD = "DD2 Item Guard"
local TAG = "[DD2IG] "
local CONFIG_FILE = "dd2_item_guard.json"
local DUMP_FILE = "dd2_item_guard_probe_dump.json"

local DEFAULT_CONFIG = {
    config_version = 5,
    enabled = false,
    read_only = false,
    max_collection_items = 200,
    max_reflection_members = 300,
    max_nested_collection_items = 80,
    max_observed_ui_events = 300,
    grant_character_id = -2,
    grant_event_type = 1,
    block_on_min = false,
    restore_shortage = true,
    method_probe_enabled = false,
    max_method_probe_events = 120,
    dump_file = DUMP_FILE,
    extra_type_names = {},
    items = {},
}

local KEYWORDS = {
    "item",
    "inventory",
    "storage",
    "stock",
    "container",
    "warehouse",
    "box",
    "pouch",
    "bag",
    "save",
}

local VALUE_KEYWORDS = {
    "item",
    "id",
    "name",
    "num",
    "count",
    "quantity",
    "stock",
    "amount",
    "possession",
    "storage",
    "inventory",
    "category",
    "kind",
    "type",
    "data",
}

local DIRECT_FIELD_NAMES = {
    "_ItemDataDict",
    "_WeaponEnhanceDict",
    "_ArmorEnhanceDict",
    "_EquipDataDict",
    "_WeaponAdditionalDataDict",
    "WeaponSpecialEfficacyParam",
    "ItemMixData",
    "_MaterialList",
    "_Params",
    "Storage",
    "_Storage",
    "Inventory",
    "_Inventory",
    "ItemStorage",
    "_ItemStorage",
    "ItemBox",
    "_ItemBox",
    "ItemBag",
    "_ItemBag",
    "Pouch",
    "_Pouch",
    "Warehouse",
    "_Warehouse",
    "ItemList",
    "_ItemList",
    "Items",
    "_Items",
    "Item",
    "_Item",
    "ItemData",
    "_ItemData",
    "ItemID",
    "_ItemID",
    "ItemId",
    "_ItemId",
    "Id",
    "_Id",
    "ID",
    "_ID",
    "Num",
    "_Num",
    "Count",
    "_Count",
    "Amount",
    "_Amount",
    "Quantity",
    "_Quantity",
    "Stock",
    "_Stock",
    "PossessionNum",
    "_PossessionNum",
    "ItemNum",
    "_ItemNum",
}

local DIRECT_METHOD_NAMES = {
    "getItem(System.Int32, System.Int32, app.CharacterID, System.Boolean, System.Boolean, System.Boolean, app.ItemManager.GetItemEventType)",
    "getItemData(System.Int32)",
    "getItemData(app.WeaponID)",
    "isValidItem",
    "isValidItem(System.Int32)",
    "isUseEnable(System.Int32)",
    "getEquipData",
}

local ITEM_MANAGER_HOOK_CANDIDATES = {
    "useItemSub",
    "useItem",
    "useItem(System.Int32)",
    "useItem(app.ItemCommonParam)",
    "getItem(System.Int32, System.Int32, app.CharacterID, System.Boolean, System.Boolean, System.Boolean, app.ItemManager.GetItemEventType)",
    "subItem",
    "subItemNum",
    "removeItem",
    "removeItemNum",
    "deleteItem",
    "lostItem",
    "discardItem",
    "setItemNum",
    "changeItemNum",
    "updateItemNum",
    "consumeItem",
    "consumeItemNum",
    "useConsumeItem",
}

local BASE_TYPE_NAMES = {
    "app.ItemManager",
    "app.ItemDataManager",
    "app.ItemData",
    "app.ItemParam",
    "app.ItemCommonParam",
    "app.ItemDataParam",
    "app.ItemWeaponParam",
    "app.ItemArmorParam",
    "app.ItemMixData",
    "app.ItemMixParam",
    "app.ItemMixMaterialParam",
    "app.ItemUserData",
    "app.ItemDataBase",
    "app.ItemInfo",
    "app.ItemList",
    "app.ItemStorage",
    "app.ItemBox",
    "app.Inventory",
    "app.InventoryData",
    "app.InventoryManager",
    "app.PlayerInventory",
    "app.Storage",
    "app.StorageData",
    "app.StorageManager",
    "app.Warehouse",
    "app.WarehouseManager",
    "app.SaveData",
    "app.SaveDataManager",
    "app.SaveManager",
    "app.GameDataManager",
    "app.PlayerManager",
    "app.CharacterManager",
    "app.PawnManager",
    "app.EquipmentManager",
    "app.GuiManager",
    "app.GUIBase",
}

local config = nil
local last_dump = nil
local last_status = "Loaded. Open inventory, add observed items, then enable enforcement."
local last_summary = {
    type_count = 0,
    singleton_count = 0,
    collection_count = 0,
    item_count = 0,
}

local collect_getter_objects
local read_candidate_fields
local read_number_field
local cached_get_item_name_method = false
local observed_ui_events = {}
local hooks_installed = false
local hook_status = {}
local known_observed_items = {}
local restore_log = {}
local block_log = {}
local method_probe_log = {}
local block_next_use = {}
local last_restore_time = {}
local cached_item_manager = false
local cached_get_item_method = false
local cached_have_num_method = false

local function safe_log(level, message)
    local text = TAG .. tostring(message)
    if log and log[level] then
        log[level](text)
    elseif log and log.info then
        log.info(text)
    else
        print(text)
    end
end

local function info(message)
    safe_log("info", message)
end

local function warn(message)
    safe_log("warn", message)
end

local function safe(label, fn)
    local ok, result = pcall(fn)
    if not ok then
        return nil, tostring(result or label)
    end
    return result, nil
end

local function sequence_count(seq)
    if seq == nil then
        return nil
    end

    if type(seq) == "table" then
        return #seq
    end

    local candidates = {
        "get_size",
        "get_Count",
        "get_count",
        "get_Length",
        "get_length",
    }

    for _, name in ipairs(candidates) do
        local value = safe("sequence_count." .. name, function()
            return seq:call(name)
        end)
        if type(value) == "number" then
            return math.floor(value)
        end
    end

    return nil
end

local function sequence_item(seq, index)
    if seq == nil then
        return nil
    end

    if type(seq) == "table" then
        return seq[index + 1] or seq[index]
    end

    local value = safe("sequence_index", function()
        return seq[index]
    end)
    if value ~= nil then
        return value
    end

    value = safe("sequence_get_Item", function()
        return seq:call("get_Item", index)
    end)
    return value
end

local function sequence_enumerator(seq)
    if seq == nil or type(seq) == "table" then
        return nil
    end

    local value = safe("sequence_get_enumerator", function()
        return seq:call("GetEnumerator")
    end)
    if value ~= nil then
        return value
    end

    return safe("sequence_get_Enumerator", function()
        return seq:call("get_Enumerator")
    end)
end

local function enumerator_move_next(enumerator)
    local value = safe("enumerator_MoveNext", function()
        return enumerator:call("MoveNext")
    end)
    return value == true
end

local function enumerator_current(enumerator)
    local current = safe("enumerator_get_Current", function()
        return enumerator:call("get_Current")
    end)
    if current ~= nil then
        return current
    end

    return safe("enumerator_current_field", function()
        return enumerator._current
    end)
end

local function for_each_sequence(seq, limit, callback)
    if seq == nil then
        return 0
    end

    limit = limit or 1000
    local count = sequence_count(seq)
    local visited = 0

    if count ~= nil then
        local stop = math.min(count, limit)
        for i = 0, stop - 1 do
            local item = sequence_item(seq, i)
            if item ~= nil then
                callback(item, i)
                visited = visited + 1
            end
        end
        return visited
    end

    if type(seq) == "table" then
        for key, item in pairs(seq) do
            if visited >= limit then
                break
            end
            callback(item, key)
            visited = visited + 1
        end
        return visited
    end

    local enumerator = sequence_enumerator(seq)
    if enumerator ~= nil then
        while visited < limit and enumerator_move_next(enumerator) do
            callback(enumerator_current(enumerator), visited)
            visited = visited + 1
        end
    end

    return visited
end

local function copy_defaults(src)
    local out = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            out[k] = copy_defaults(v)
        else
            out[k] = v
        end
    end
    return out
end

local function merge_defaults(target, defaults)
    if type(target) ~= "table" then
        target = {}
    end

    for key, value in pairs(defaults) do
        if type(value) == "table" then
            target[key] = merge_defaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end

    return target
end

local function load_config()
    local loaded = nil
    if json and json.load_file then
        loaded = json.load_file(CONFIG_FILE)
    end

    local merged = copy_defaults(DEFAULT_CONFIG)
    local loaded_version = 0
    if type(loaded) == "table" then
        loaded_version = tonumber(loaded.config_version) or 0
        for k, v in pairs(loaded) do
            merged[k] = v
        end
        if type(merged.items) ~= "table" then
            merged.items = {}
        end
        if type(merged.extra_type_names) ~= "table" then
            merged.extra_type_names = {}
        end
    end

    if loaded_version < 5 then
        merged.config_version = DEFAULT_CONFIG.config_version
        merged.restore_shortage = true
        merged.block_on_min = false
        merged.method_probe_enabled = false
        merged.grant_character_id = -2
        merged.grant_event_type = 1
    end
    merged = merge_defaults(merged, DEFAULT_CONFIG)
    if loaded_version < DEFAULT_CONFIG.config_version then
        merged.config_version = DEFAULT_CONFIG.config_version
    end

    if type(merged.enabled) ~= "boolean" then
        merged.enabled = false
    end
    if type(merged.read_only) ~= "boolean" then
        merged.read_only = false
    end
    if type(merged.restore_shortage) ~= "boolean" then
        merged.restore_shortage = DEFAULT_CONFIG.restore_shortage
    end
    if type(merged.block_on_min) ~= "boolean" then
        merged.block_on_min = DEFAULT_CONFIG.block_on_min
    end
    if type(merged.method_probe_enabled) ~= "boolean" then
        merged.method_probe_enabled = DEFAULT_CONFIG.method_probe_enabled
    end
    return merged
end

local function save_config()
    if json and json.dump_file then
        json.dump_file(CONFIG_FILE, config)
        info("Saved config to reframework/data/" .. CONFIG_FILE)
    else
        warn("json.dump_file is unavailable; config not saved")
    end
end

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function contains_any(value, keywords)
    local text = lower(value)
    for _, keyword in ipairs(keywords) do
        if string.find(text, keyword, 1, true) then
            return true
        end
    end
    return false
end

local function starts_with(value, prefix)
    value = tostring(value or "")
    return string.sub(value, 1, string.len(prefix)) == prefix
end

local function member_name(member)
    if member == nil then
        return "<nil>"
    end
    local name = safe("get_name", function()
        return member:get_name()
    end)
    return tostring(name or member)
end

local function type_full_name(type_def)
    if type_def == nil then
        return nil
    end

    local full_name = safe("get_full_name", function()
        return type_def:get_full_name()
    end)
    if full_name ~= nil then
        return tostring(full_name)
    end

    local name = safe("get_name", function()
        return type_def:get_name()
    end)
    return tostring(name or type_def)
end

local function object_type_name(obj)
    if obj == nil then
        return nil
    end

    local type_def = safe("get_type_definition", function()
        return obj:get_type_definition()
    end)

    return type_full_name(type_def)
end

local function scalar_or_string(value, depth)
    depth = depth or 0
    local value_type = type(value)

    if value == nil or value_type == "boolean" or value_type == "number" or value_type == "string" then
        return value
    end

    if value_type == "table" then
        if depth > 1 then
            return tostring(value)
        end

        local out = {}
        local count = 0
        for k, v in pairs(value) do
            count = count + 1
            if count > 20 then
                out["..."] = "truncated"
                break
            end
            out[tostring(k)] = scalar_or_string(v, depth + 1)
        end
        return out
    end

    local type_name = object_type_name(value)
    local text = safe("ToString", function()
        return value:call("ToString")
    end)

    return {
        kind = value_type,
        type = type_name,
        text = tostring(text or value),
    }
end

local function get_item_name_method()
    if cached_get_item_name_method ~= false then
        return cached_get_item_name_method
    end

    cached_get_item_name_method = nil
    local gui_type = safe("GUIBase type", function()
        return sdk.find_type_definition("app.GUIBase")
    end)
    if gui_type ~= nil then
        cached_get_item_name_method = safe("getElfItemName", function()
            return gui_type:get_method("getElfItemName(System.Int32, System.Boolean)")
        end)
    end

    return cached_get_item_name_method
end

local function try_item_display_name(item_id)
    if type(item_id) ~= "number" then
        return nil
    end

    local method = get_item_name_method()
    if method == nil then
        return nil
    end

    local value = safe("getElfItemName", function()
        return method:call(nil, item_id, true)
    end)
    return scalar_or_string(value)
end

local function ptr_to_int(value)
    if value == nil then
        return nil
    end

    local number = safe("to_int64", function()
        return sdk.to_int64(value)
    end)
    if type(number) == "number" then
        return number
    end

    number = safe("to_int64_masked", function()
        return sdk.to_int64(value) & 0xffffffff
    end)
    if type(number) == "number" then
        return number
    end

    return nil
end

local function arg_snapshot(args, max_args)
    local out = {}
    max_args = max_args or 8
    for i = 2, max_args do
        local raw = args[i]
        if raw == nil then
            out[tostring(i)] = nil
        else
            local as_int = ptr_to_int(raw)
            local managed = safe("arg managed", function()
                return sdk.to_managed_object(raw)
            end)
            local managed_type = object_type_name(managed)
            local item_id = nil
            if managed ~= nil then
                item_id = read_number_field(managed, { "_Id", "Id", "ID", "_ID", "_ItemID", "_ItemId", "ItemID", "ItemId" })
            end
            out[tostring(i)] = {
                int = as_int,
                managed_type = managed_type,
                item_id = item_id,
                text = managed ~= nil and scalar_or_string(managed) or nil,
            }
        end
    end
    return out
end

local function push_method_probe(entry)
    if config ~= nil and config.method_probe_enabled ~= true then
        return
    end

    entry.time = os.date("%Y-%m-%d %H:%M:%S")
    table.insert(method_probe_log, entry)
    local max_events = config and config.max_method_probe_events or DEFAULT_CONFIG.max_method_probe_events
    while #method_probe_log > max_events do
        table.remove(method_probe_log, 1)
    end
end

read_number_field = function(obj, names)
    if obj == nil then
        return nil, nil
    end

    for _, name in ipairs(names) do
        local value = safe("read_number_field." .. name, function()
            return obj[name]
        end)
        if type(value) == "number" then
            return value, name
        end
    end

    return nil, nil
end

local function get_item_manager()
    if cached_item_manager ~= false then
        return cached_item_manager
    end

    cached_item_manager = safe("get ItemManager singleton", function()
        return sdk.get_managed_singleton("app.ItemManager")
    end)
    return cached_item_manager
end

local function get_give_item_method()
    if cached_get_item_method ~= false then
        return cached_get_item_method
    end

    cached_get_item_method = nil
    local manager = get_item_manager()
    local type_def = nil
    if manager ~= nil then
        type_def = safe("get ItemManager runtime type", function()
            return manager:get_type_definition()
        end)
    end
    if type_def == nil then
        type_def = safe("find ItemManager type", function()
            return sdk.find_type_definition("app.ItemManager")
        end)
    end
    if type_def ~= nil then
        cached_get_item_method = safe("find getItem method", function()
            return type_def:get_method("getItem(System.Int32, System.Int32, app.CharacterID, System.Boolean, System.Boolean, System.Boolean, app.ItemManager.GetItemEventType)")
        end)
    end

    return cached_get_item_method
end

local function get_have_num_method()
    if cached_have_num_method ~= false then
        return cached_have_num_method
    end

    cached_have_num_method = nil
    local manager = get_item_manager()
    local type_def = nil
    if manager ~= nil then
        type_def = safe("get ItemManager runtime type", function()
            return manager:get_type_definition()
        end)
    end
    if type_def ~= nil then
        cached_have_num_method = safe("find getHaveNum method", function()
            return type_def:get_method("getHaveNum(System.Int32, app.CharacterID)")
        end)
    end

    return cached_have_num_method
end

local function get_player_chara_id()
    local character_manager = safe("get CharacterManager", function()
        return sdk.get_managed_singleton("app.CharacterManager")
    end)
    if character_manager == nil then
        return nil, "CharacterManager unavailable"
    end

    local player = safe("get ManualPlayer", function()
        return character_manager:get_ManualPlayer()
    end)
    if player == nil then
        return nil, "ManualPlayer unavailable"
    end

    local chara_id = safe("get CharaID", function()
        return player:get_CharaID()
    end)
    if chara_id == nil then
        return nil, "player CharaID unavailable"
    end

    return chara_id, nil
end

local function get_have_num(item_id, character_id)
    if character_id == "__player" then
        character_id = get_player_chara_id()
    end

    local manager = get_item_manager()
    local method = get_have_num_method()
    if manager == nil or method == nil or character_id == nil then
        return nil
    end

    return safe("getHaveNum", function()
        return method:call(manager, item_id, character_id)
    end)
end

local function push_restore_log(entry)
    entry.time = os.date("%Y-%m-%d %H:%M:%S")
    table.insert(restore_log, entry)
    while #restore_log > 80 do
        table.remove(restore_log, 1)
    end
end

local function call_get_item(item_id, amount, character_id, event_type, reason)
    item_id = tonumber(item_id)
    amount = math.floor(tonumber(amount) or 0)
    if item_id == nil or amount <= 0 then
        return false, "invalid item/count"
    end

    local manager = get_item_manager()
    local method = get_give_item_method()
    if manager == nil or method == nil then
        return false, "ItemManager/getItem unavailable"
    end

    local character_error = nil
    if character_id == "__player" then
        character_id, character_error = get_player_chara_id()
    elseif character_id ~= nil then
        character_id = math.floor(tonumber(character_id) or 0)
    end
    event_type = math.floor(tonumber(event_type) or 1)
    local result = nil
    local before_count = get_have_num(item_id, character_id)

    local ok, err = pcall(function()
        result = method:call(manager, item_id, amount, character_id, true, false, false, event_type)
    end)
    local after_count = get_have_num(item_id, character_id)

    push_restore_log({
        item_id = item_id,
        amount = amount,
        reason = reason,
        character_id = character_id,
        character_error = character_error,
        event_type = event_type,
        before_count = before_count,
        after_count = after_count,
        result = scalar_or_string(result),
        ok = ok,
        error = ok and nil or tostring(err),
    })

    if not ok then
        return false, tostring(err)
    end

    return true, nil
end

local function configured_character_id()
    local character_id = tonumber(config.grant_character_id)
    if character_id == nil then
        return nil
    end
    if character_id == -2 then
        return "__player"
    end
    if character_id == -1 then
        return nil
    end
    return math.floor(character_id)
end

local function give_item(item_id, amount, reason)
    return call_get_item(item_id, amount, configured_character_id(), config.grant_event_type, reason)
end

local function item_rule(item_id)
    if config == nil or type(config.items) ~= "table" then
        return nil
    end
    return config.items[tostring(item_id)]
end

local function maybe_restore_observed_item(event)
    if config == nil or config.enabled ~= true or config.read_only == true or config.restore_shortage ~= true then
        return
    end

    local item_id = tonumber(event.item_id)
    if item_id == nil then
        return
    end

    local rule = item_rule(item_id)
    if type(rule) ~= "table" or rule.enabled == false then
        return
    end

    local mode = tostring(rule.mode or "min")
    local target = math.floor(tonumber(rule.count) or 0)
    if target <= 0 then
        return
    end

    if mode ~= "min" and mode ~= "fixed" then
        return
    end

    local target_character_id = configured_character_id()
    local count = tonumber(get_have_num(item_id, target_character_id))
    local count_source = "getHaveNum"
    if count == nil then
        push_restore_log({
            item_id = item_id,
            amount = 0,
            reason = "skip restore; target character count unavailable",
            character_id = target_character_id,
            observed_count = event.count,
            count_source = "unavailable",
            ok = false,
            error = "getHaveNum failed",
        })
        return
    end

    if count >= target then
        return
    end

    local now = os.clock()
    local key = tostring(item_id) .. ":" .. tostring(target_character_id) .. ":" .. tostring(target)
    if last_restore_time[key] ~= nil and now - last_restore_time[key] < 1.0 then
        return
    end
    last_restore_time[key] = now

    local missing = target - count
    local ok, err = give_item(item_id, missing, mode .. " restore from " .. count_source .. " count " .. tostring(count) .. " to " .. tostring(target))
    if ok then
        last_status = "Restored item " .. tostring(item_id) .. " by +" .. tostring(missing)
        info(last_status)
    else
        last_status = "Restore failed for item " .. tostring(item_id) .. ": " .. tostring(err)
        warn(last_status)
    end
end

local function push_block_log(entry)
    entry.time = os.date("%Y-%m-%d %H:%M:%S")
    table.insert(block_log, entry)
    while #block_log > 80 do
        table.remove(block_log, 1)
    end
end

local function should_block_use_item(item_data)
    if config == nil or config.enabled ~= true or config.read_only == true or config.block_on_min ~= true then
        return false
    end

    local item_id = read_number_field(item_data, {
        "_Id",
        "Id",
        "ID",
        "_ID",
        "_ItemID",
        "_ItemId",
        "ItemID",
        "ItemId",
    })
    item_id = tonumber(item_id)
    if item_id == nil then
        return false
    end

    local rule = item_rule(item_id)
    if type(rule) ~= "table" or rule.enabled == false then
        return false
    end

    local mode = tostring(rule.mode or "min")
    if mode ~= "min" and mode ~= "fixed" then
        return false
    end

    local target = math.floor(tonumber(rule.count) or 0)
    if target <= 0 then
        return false
    end

    local observed = known_observed_items[tostring(item_id)]
    local target_character_id = configured_character_id()
    local count = tonumber(get_have_num(item_id, target_character_id))
    if count == nil then
        push_block_log({
            item_id = item_id,
            name = rule.name,
            blocked = false,
            reason = "target character count unavailable",
            character_id = target_character_id,
            observed_count = observed and observed.count or nil,
        })
        return false
    end

    if count <= target then
        push_block_log({
            item_id = item_id,
            name = rule.name or (observed and observed.display_name),
            count = count,
            target = target,
            character_id = target_character_id,
            mode = mode,
            blocked = true,
            reason = "count <= target",
        })
        last_status = "Blocked use of item " .. tostring(item_id) .. " at " .. tostring(count) .. "/" .. tostring(target)
        info(last_status)
        return true
    end

    push_block_log({
        item_id = item_id,
        name = rule.name or (observed and observed.display_name),
        count = count,
        target = target,
        character_id = target_character_id,
        mode = mode,
        blocked = false,
        reason = "count > target",
    })
    return false
end

local function should_block_next_use(item_data)
    local item_id = read_number_field(item_data, {
        "_Id",
        "Id",
        "ID",
        "_ID",
        "_ItemID",
        "_ItemId",
        "ItemID",
        "ItemId",
    })
    item_id = tonumber(item_id)
    if item_id == nil then
        return false
    end

    local key = tostring(item_id)
    if block_next_use[key] ~= true then
        return false
    end

    block_next_use[key] = nil
    push_block_log({
        item_id = item_id,
        blocked = true,
        reason = "manual block next use",
    })
    last_status = "Manually blocked next use of item " .. tostring(item_id)
    info(last_status)
    return true
end

local function remember_observed_item(event)
    local item_id = tonumber(event.item_id)
    if item_id == nil then
        return
    end

    known_observed_items[tostring(item_id)] = {
        item_id = item_id,
        display_name = event.display_name,
        count = event.count,
        item_type = event.item_type,
        last_seen = event.time,
    }
end

local function add_or_update_min_rule(item_id, count, display_name)
    item_id = tonumber(item_id)
    count = math.max(1, math.floor(tonumber(count) or 1))
    if item_id == nil then
        return
    end

    config.items = config.items or {}
    config.items[tostring(item_id)] = {
        enabled = true,
        mode = "min",
        count = count,
        name = display_name,
    }
    last_status = "Set min rule: " .. tostring(display_name or item_id) .. " >= " .. tostring(count)
    info(last_status)
end

local function record_observed_ui_item(source, item_data, count, extra)
    local id, id_source = read_number_field(item_data, {
        "_Id",
        "Id",
        "ID",
        "_ID",
        "_ItemID",
        "_ItemId",
        "ItemID",
        "ItemId",
        "_IconNo",
        "IconNo",
    })

    local event = {
        source = source,
        time = os.date("%Y-%m-%d %H:%M:%S"),
        item_id = id,
        item_id_source = id_source,
        display_name = try_item_display_name(id),
        count = count,
        item_type = object_type_name(item_data),
        item_text = scalar_or_string(item_data),
        fields = read_candidate_fields and read_candidate_fields(item_data) or nil,
        extra = extra,
    }

    table.insert(observed_ui_events, event)
    remember_observed_item(event)
    maybe_restore_observed_item(event)
    local max_events = config and config.max_observed_ui_events or DEFAULT_CONFIG.max_observed_ui_events
    while #observed_ui_events > max_events do
        table.remove(observed_ui_events, 1)
    end
end

local function install_observation_hooks()
    if hooks_installed then
        return
    end
    hooks_installed = true

    local gui_item_window_type = safe("find ItemWindowRef", function()
        return sdk.find_type_definition("app.GUIBase.ItemWindowRef")
    end)
    local setup_method = nil
    if gui_item_window_type ~= nil then
        setup_method = safe("find ItemWindowRef setup", function()
            return gui_item_window_type:get_method("setup(app.ItemCommonParam, System.Int32, System.Boolean)")
        end)
    end

    if setup_method ~= nil then
        local ok, err = pcall(function()
            sdk.hook(setup_method, function(args)
                pcall(function()
                    local item_data = sdk.to_managed_object(args[3])
                    local count = ptr_to_int(args[4])
                    record_observed_ui_item("app.GUIBase.ItemWindowRef.setup", item_data, count, {
                        bool_arg = ptr_to_int(args[5]),
                    })
                end)
            end, function(ret)
                return ret
            end)
        end)
        hook_status.item_window_setup = ok and "installed" or tostring(err)
    else
        hook_status.item_window_setup = "method not found"
    end

    local item_manager_type = safe("find ItemManager", function()
        return sdk.find_type_definition("app.ItemManager")
    end)
    local use_item_sub = nil
    if item_manager_type ~= nil then
        use_item_sub = safe("find useItemSub", function()
            return item_manager_type:get_method("useItemSub")
        end)
    end

    if use_item_sub ~= nil then
        local ok, err = pcall(function()
            sdk.hook(use_item_sub, function(args)
                local block_original = false
                pcall(function()
                    local item_data = sdk.to_managed_object(args[5])
                    push_method_probe({
                        method = "app.ItemManager.useItemSub",
                        phase = "pre",
                        args = arg_snapshot(args, 8),
                    })
                    record_observed_ui_item("app.ItemManager.useItemSub", item_data, nil, {
                        from_type = object_type_name(sdk.to_managed_object(args[3])),
                        to_type = object_type_name(sdk.to_managed_object(args[4])),
                    })
                    block_original = should_block_next_use(item_data) or should_block_use_item(item_data)
                end)
                if block_original and sdk.PreHookResult and sdk.PreHookResult.SKIP_ORIGINAL then
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
            end, function(ret)
                push_method_probe({
                    method = "app.ItemManager.useItemSub",
                    phase = "post",
                    ret = scalar_or_string(ret),
                })
                return ret
            end)
        end)
        hook_status.use_item_sub = ok and "installed" or tostring(err)
    else
        hook_status.use_item_sub = "method not found"
    end

    local installed_probe_count = 0
    if item_manager_type ~= nil then
        for _, method_name in ipairs(ITEM_MANAGER_HOOK_CANDIDATES) do
            if method_name ~= "useItemSub" then
                local method = safe("find probe " .. method_name, function()
                    return item_manager_type:get_method(method_name)
                end)
                if method ~= nil then
                    local ok = pcall(function()
                        sdk.hook(method, function(args)
                            push_method_probe({
                                method = "app.ItemManager." .. method_name,
                                phase = "pre",
                                args = arg_snapshot(args, 8),
                            })
                        end, function(ret)
                            push_method_probe({
                                method = "app.ItemManager." .. method_name,
                                phase = "post",
                                ret = scalar_or_string(ret),
                            })
                            return ret
                        end)
                    end)
                    if ok then
                        installed_probe_count = installed_probe_count + 1
                    end
                end
            end
        end
    end
    hook_status.item_manager_method_probes = "installed " .. tostring(installed_probe_count)

    info("Observation hooks: ItemWindowRef.setup=" .. tostring(hook_status.item_window_setup) .. ", useItemSub=" .. tostring(hook_status.use_item_sub) .. ", probes=" .. tostring(hook_status.item_manager_method_probes))
end

local function method_param_count(method)
    local params = safe("get_params", function()
        return method:get_params()
    end)
    local count = sequence_count(params)
    if count ~= nil then
        return count
    end

    params = safe("get_param_types", function()
        return method:get_param_types()
    end)
    return sequence_count(params)
end

local function method_return_name(method)
    local return_type = safe("get_return_type", function()
        return method:get_return_type()
    end)
    return type_full_name(return_type)
end

local function field_type_name(field)
    local field_type = safe("get_type", function()
        return field:get_type()
    end)
    return type_full_name(field_type)
end

local function read_direct_field(obj, name)
    local value, err = safe("direct_field_read", function()
        return obj[name]
    end)
    if value ~= nil then
        return value, nil, "direct"
    end

    local type_def = safe("get_type_definition", function()
        return obj:get_type_definition()
    end)
    if type_def ~= nil then
        local field = safe("get_field", function()
            return type_def:get_field(name)
        end)
        if field ~= nil then
            local field_value, field_err = safe("named_field_get_data", function()
                return field:get_data(obj)
            end)
            if field_value ~= nil then
                return field_value, nil, "get_field"
            end
            err = field_err or err
        end
    end

    return nil, err, nil
end

local function inspect_direct_fields(obj)
    local out = {}
    for _, name in ipairs(DIRECT_FIELD_NAMES) do
        local value, err, source = read_direct_field(obj, name)
        if value ~= nil or err ~= nil then
            out[name] = {
                source = source,
                type = object_type_name(value),
                value = scalar_or_string(value),
                error = err,
            }
        end
    end
    return out
end

local function inspect_direct_methods(type_def)
    local out = {}
    if type_def == nil then
        return out
    end

    for _, name in ipairs(DIRECT_METHOD_NAMES) do
        local method, err = safe("get_method." .. name, function()
            return type_def:get_method(name)
        end)
        if method ~= nil or err ~= nil then
            out[name] = {
                found = method ~= nil,
                params = method ~= nil and method_param_count(method) or nil,
                returns = method ~= nil and method_return_name(method) or nil,
                error = err,
            }
        end
    end

    return out
end

local function inspect_type(type_name)
    local type_def = safe("find_type_definition", function()
        return sdk.find_type_definition(type_name)
    end)

    if type_def == nil then
        return nil
    end

    local result = {
        name = type_name,
        full_name = type_full_name(type_def),
        fields = {},
        methods = {},
        matched_fields = {},
        matched_methods = {},
        direct_methods = inspect_direct_methods(type_def),
    }

    local fields = safe("get_fields", function()
        return type_def:get_fields()
    end)
    local field_count = sequence_count(fields)
    for_each_sequence(fields, config.max_reflection_members, function(field)
        local name = member_name(field)
        local entry = {
            name = name,
            type = field_type_name(field),
        }
        table.insert(result.fields, entry)

        if contains_any(name, VALUE_KEYWORDS) or contains_any(entry.type, VALUE_KEYWORDS) then
            table.insert(result.matched_fields, entry)
        end
    end)
    if field_count ~= nil and field_count > config.max_reflection_members then
        table.insert(result.fields, { name = "...", note = "truncated", total = field_count })
    end

    local methods = safe("get_methods", function()
        return type_def:get_methods()
    end)
    local method_count = sequence_count(methods)
    for_each_sequence(methods, config.max_reflection_members, function(method)
        local name = member_name(method)
        local entry = {
            name = name,
            params = method_param_count(method),
            returns = method_return_name(method),
        }
        table.insert(result.methods, entry)

        if contains_any(name, VALUE_KEYWORDS) or contains_any(entry.returns, VALUE_KEYWORDS) then
            table.insert(result.matched_methods, entry)
        end
    end)
    if method_count ~= nil and method_count > config.max_reflection_members then
        table.insert(result.methods, { name = "...", note = "truncated", total = method_count })
    end

    return result
end

local function all_type_names()
    local names = {}
    local seen = {}

    local function add(name)
        if type(name) == "string" and name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end

    for _, name in ipairs(BASE_TYPE_NAMES) do
        add(name)
    end

    if type(config.extra_type_names) == "table" then
        for _, name in ipairs(config.extra_type_names) do
            add(name)
        end
    end

    return names
end

local function try_get_singleton(type_name)
    local singleton = safe("get_managed_singleton", function()
        return sdk.get_managed_singleton(type_name)
    end)

    if singleton ~= nil then
        return singleton, "managed"
    end

    singleton = safe("get_native_singleton", function()
        if sdk.get_native_singleton then
            return sdk.get_native_singleton(type_name)
        end
        return nil
    end)

    if singleton ~= nil then
        return singleton, "native"
    end

    return nil, nil
end

read_candidate_fields = function(obj)
    local out = {}
    local type_def = safe("get_type_definition", function()
        return obj:get_type_definition()
    end)
    if type_def == nil then
        return out
    end

    local fields = safe("get_fields", function()
        return type_def:get_fields()
    end)
    for_each_sequence(fields, config.max_reflection_members, function(field)
        local name = member_name(field)
        local field_type = field_type_name(field)
        if contains_any(name, VALUE_KEYWORDS) or contains_any(field_type, VALUE_KEYWORDS) then
            local value, err = safe("field_get_data", function()
                return field:get_data(obj)
            end)
            if value == nil then
                value = safe("direct_field_read", function()
                    return obj[name]
                end)
            end

            out[name] = {
                type = field_type,
                value = scalar_or_string(value),
                error = err,
            }
        end
    end)

    return out
end

local function direct_field_value(obj, field)
    local name = member_name(field)
    local value = safe("direct_field_read", function()
        return obj[name]
    end)
    if value ~= nil then
        return value, name
    end

    value = safe("field_get_data", function()
        return field:get_data(obj)
    end)
    return value, name
end

local function read_candidate_getters(obj)
    local out = {}
    local type_def = safe("get_type_definition", function()
        return obj:get_type_definition()
    end)
    if type_def == nil then
        return out
    end

    local methods = safe("get_methods", function()
        return type_def:get_methods()
    end)
    for_each_sequence(methods, config.max_reflection_members, function(method)
        local name = member_name(method)
        local param_count = method_param_count(method)
        local looks_like_getter = starts_with(name, "get_") or starts_with(name, "is") or starts_with(name, "Is") or starts_with(name, "has") or starts_with(name, "Has")

        if looks_like_getter and contains_any(name, VALUE_KEYWORDS) and (param_count == nil or param_count == 0) then
            local value, err = safe("getter_call", function()
                return obj:call(name)
            end)

            out[name] = {
                returns = method_return_name(method),
                value = scalar_or_string(value),
                error = err,
            }
        end
    end)

    return out
end

local function get_count(obj)
    local candidates = {
        "get_Count",
        "get_count",
        "get_Size",
        "get_size",
        "get_Length",
        "get_length",
    }

    for _, name in ipairs(candidates) do
        local value = safe(name, function()
            return obj:call(name)
        end)
        if type(value) == "number" and value >= 0 then
            return math.floor(value), name
        end
    end

    return nil, nil
end

local function get_indexed_item(collection, index)
    local candidates = {
        "get_Item",
        "get_item",
        "get_Elements",
        "get_Value",
    }

    for _, name in ipairs(candidates) do
        local value = safe(name, function()
            return collection:call(name, index)
        end)
        if value ~= nil then
            return value, name
        end
    end

    local value = safe("direct_index", function()
        return collection[index]
    end)
    if value ~= nil then
        return value, "direct_index"
    end

    return nil, nil
end

local function get_enumerator(collection)
    local candidates = {
        "GetEnumerator",
        "get_Enumerator",
    }

    for _, name in ipairs(candidates) do
        local value = safe(name, function()
            return collection:call(name)
        end)
        if value ~= nil then
            return value, name
        end
    end

    return nil, nil
end

local function move_next(enumerator)
    local value = safe("MoveNext", function()
        return enumerator:call("MoveNext")
    end)
    if type(value) == "boolean" then
        return value
    end

    value = safe("MoveNext direct", function()
        return enumerator:MoveNext()
    end)
    return value == true
end

local function current_entry(enumerator)
    local current = safe("get_Current", function()
        return enumerator:call("get_Current")
    end)
    if current ~= nil then
        return current
    end

    current = safe("_current", function()
        return enumerator._current
    end)
    if current ~= nil then
        return current
    end

    return safe("Current", function()
        return enumerator.Current
    end)
end

local function entry_key_value(entry)
    if entry == nil then
        return nil, nil
    end

    local key = safe("key", function()
        return entry.key
    end)
    if key == nil then
        key = safe("Key", function()
            return entry.Key
        end)
    end

    local value = safe("value", function()
        return entry.value
    end)
    if value == nil then
        value = safe("Value", function()
            return entry.Value
        end)
    end

    if value == nil then
        return key, entry
    end

    return key, value
end

local function collect_item_id_candidates(snapshot)
    local candidates = {}
    local seen = {}

    local function add(name, value)
        if type(value) ~= "number" then
            return
        end

        local lowered = lower(name)
        local looks_like_id = string.find(lowered, "id", 1, true) ~= nil
            or string.find(lowered, "item", 1, true) ~= nil

        if looks_like_id and not seen[value] then
            seen[value] = true
            table.insert(candidates, {
                source = name,
                value = value,
                display_name = try_item_display_name(value),
            })
        end
    end

    for name, entry in pairs(snapshot.fields or {}) do
        if type(entry) == "table" then
            add("field." .. name, entry.value)
        end
    end

    for name, entry in pairs(snapshot.getters or {}) do
        if type(entry) == "table" then
            add("getter." .. name, entry.value)
        end
    end

    return candidates
end

local function looks_like_collection(obj)
    if obj == nil then
        return false
    end

    local type_name = object_type_name(obj)
    if contains_any(type_name, KEYWORDS) then
        local count = get_count(obj)
        if count ~= nil then
            return true
        end
    end

    local count = get_count(obj)
    if count ~= nil then
        return true
    end

    local enumerator = get_enumerator(obj)
    return enumerator ~= nil
end

local function snapshot_item(obj, source, index)
    local snapshot = {
        source = source,
        index = index,
        type = object_type_name(obj),
        tostring = scalar_or_string(obj),
        fields = read_candidate_fields(obj),
        getters = read_candidate_getters(obj),
    }

    snapshot.item_id_candidates = collect_item_id_candidates(snapshot)
    return snapshot
end

local function scan_collection(collection, source, max_items)
    local count, count_method = get_count(collection)
    local entry = {
        source = source,
        type = object_type_name(collection),
        count = count,
        count_method = count_method,
        item_method = nil,
        enumerator_method = nil,
        items = {},
    }

    if count ~= nil then
        local limit = math.min(count, max_items or config.max_collection_items)
        for i = 0, limit - 1 do
            local item, item_method = get_indexed_item(collection, i)
            if item ~= nil then
                entry.item_method = entry.item_method or item_method
                table.insert(entry.items, snapshot_item(item, source, i))
            end
        end
    end

    if #entry.items == 0 then
        local enumerator, enumerator_method = get_enumerator(collection)
        if enumerator ~= nil then
            entry.enumerator_method = enumerator_method
            local limit = max_items or config.max_collection_items
            local index = 0
            while index < limit and move_next(enumerator) do
                local current = current_entry(enumerator)
                local key, value = entry_key_value(current)
                local item = snapshot_item(value, source, index)
                item.key = scalar_or_string(key)
                table.insert(entry.items, item)
                index = index + 1
            end
        end
    end

    if count == nil and #entry.items == 0 then
        return nil
    end

    return entry
end

local function collect_field_objects(obj, source)
    local collections = {}
    local type_def = safe("get_type_definition", function()
        return obj:get_type_definition()
    end)
    if type_def == nil then
        return collections
    end

    local fields = safe("get_fields", function()
        return type_def:get_fields()
    end)
    for_each_sequence(fields, config.max_reflection_members, function(field)
        local name = member_name(field)
        local field_type = field_type_name(field)
        if contains_any(name, KEYWORDS) or contains_any(field_type, KEYWORDS) then
            local value = direct_field_value(obj, field)
            if value ~= nil then
                local collection = scan_collection(value, source .. "." .. name, config.max_nested_collection_items)
                if collection ~= nil then
                    table.insert(collections, collection)
                end

                local nested = collect_getter_objects and collect_getter_objects(value, source .. "." .. name) or {}
                for _, nested_collection in ipairs(nested) do
                    table.insert(collections, nested_collection)
                end
            end
        end
    end)

    return collections
end

local function collect_direct_field_objects(obj, source)
    local collections = {}

    for _, name in ipairs(DIRECT_FIELD_NAMES) do
        local value = read_direct_field(obj, name)
        if value ~= nil then
            local collection = scan_collection(value, source .. "." .. name, config.max_nested_collection_items)
            if collection ~= nil then
                table.insert(collections, collection)
            end

            local nested = collect_getter_objects and collect_getter_objects(value, source .. "." .. name) or {}
            for _, nested_collection in ipairs(nested) do
                table.insert(collections, nested_collection)
            end

            local child_direct = nil
            if contains_any(object_type_name(value), KEYWORDS) then
                child_direct = inspect_direct_fields(value)
            end
            if child_direct ~= nil and next(child_direct) ~= nil then
                local direct_snapshot = {
                    source = source .. "." .. name,
                    type = object_type_name(value),
                    count = nil,
                    count_method = nil,
                    item_method = nil,
                    enumerator_method = "direct_fields",
                    items = {},
                    direct_fields = child_direct,
                }
                table.insert(collections, direct_snapshot)
            end
        end
    end

    return collections
end

collect_getter_objects = function(obj, source)
    local collections = {}
    local type_def = safe("get_type_definition", function()
        return obj:get_type_definition()
    end)
    if type_def == nil then
        return collections
    end

    local methods = safe("get_methods", function()
        return type_def:get_methods()
    end)
    for_each_sequence(methods, config.max_reflection_members, function(method)
        local name = member_name(method)
        local param_count = method_param_count(method)
        if starts_with(name, "get_") and contains_any(name, KEYWORDS) and (param_count == nil or param_count == 0) then
            local value = safe("getter_object", function()
                return obj:call(name)
            end)

            if value ~= nil and looks_like_collection(value) then
                local collection = scan_collection(value, source .. "." .. name, config.max_nested_collection_items)
                if collection ~= nil then
                    table.insert(collections, collection)
                end
            end
        end
    end)

    return collections
end

local function make_empty_dump()
    return {
        schema_version = 1,
        mod = MOD,
        generated_at = os.date("%Y-%m-%d %H:%M:%S"),
        enabled = config.enabled,
        read_only = config.read_only,
        config = {
            enabled = config.enabled,
            read_only = config.read_only,
            max_collection_items = config.max_collection_items,
            max_reflection_members = config.max_reflection_members,
            max_nested_collection_items = config.max_nested_collection_items,
            max_observed_ui_events = config.max_observed_ui_events,
            config_version = config.config_version,
            block_on_min = config.block_on_min,
            restore_shortage = config.restore_shortage,
            method_probe_enabled = config.method_probe_enabled,
            max_method_probe_events = config.max_method_probe_events,
            grant_character_id = config.grant_character_id,
            grant_event_type = config.grant_event_type,
            dump_file = config.dump_file,
            extra_type_names = config.extra_type_names,
            items = config.items,
        },
        notes = {
            "Rules are disabled unless enabled=true and read_only=false.",
            "Min/fixed rules restore shortages by calling ItemManager:getItem with the current player CharaID.",
            "If important DD2 types are missing, add exact type names to extra_type_names in reframework/data/dd2_item_guard.json.",
            "Use the JSON dump/probe controls only when inspecting DD2 internals.",
        },
        types = {},
        singletons = {},
        collections = {},
        items = {},
        observed_ui_events = observed_ui_events,
        known_observed_items = known_observed_items,
        restore_log = restore_log,
        block_log = block_log,
        method_probe_log = method_probe_log,
        hook_status = hook_status,
        errors = {},
    }
end

local function summarize_dump(dump)
    local collection_count = #dump.collections
    local item_count = 0
    for _, collection in ipairs(dump.collections) do
        item_count = item_count + #(collection.items or {})
    end

    last_summary = {
        type_count = #dump.types,
        singleton_count = #dump.singletons,
        collection_count = collection_count,
        item_count = item_count,
    }

    return string.format(
        "types=%d singletons=%d collections=%d sampled_items=%d",
        last_summary.type_count,
        last_summary.singleton_count,
        last_summary.collection_count,
        last_summary.item_count
    )
end

local function probe_types_and_singletons()
    local dump = make_empty_dump()
    local names = all_type_names()

    info("Starting read-only type/singleton probe")

    for _, type_name in ipairs(names) do
        local type_info = inspect_type(type_name)
        if type_info ~= nil then
            table.insert(dump.types, type_info)
            info("Found type: " .. type_name)
        end

        local singleton, singleton_kind = try_get_singleton(type_name)
        if singleton ~= nil then
            local singleton_entry = {
                name = type_name,
                kind = singleton_kind,
                type = object_type_name(singleton),
                tostring = scalar_or_string(singleton),
                fields = read_candidate_fields(singleton),
                getters = read_candidate_getters(singleton),
                direct_fields = inspect_direct_fields(singleton),
            }
            table.insert(dump.singletons, singleton_entry)
            info("Found " .. singleton_kind .. " singleton: " .. type_name)
        end
    end

    last_dump = dump
    last_status = "Probe complete: " .. summarize_dump(dump)
    info(last_status)
    return dump
end

local function dump_inventory_candidates()
    local dump = probe_types_and_singletons()

    info("Starting read-only inventory candidate scan")

    for _, singleton in ipairs(dump.singletons) do
        local obj = nil
        obj = safe("get_singleton_again", function()
            if singleton.kind == "native" and sdk.get_native_singleton then
                return sdk.get_native_singleton(singleton.name)
            end
            return sdk.get_managed_singleton(singleton.name)
        end)

        if obj ~= nil then
            if looks_like_collection(obj) then
                local collection = scan_collection(obj, singleton.name, config.max_collection_items)
                if collection ~= nil then
                    table.insert(dump.collections, collection)
                end
            end

            local nested = collect_getter_objects(obj, singleton.name)
            for _, collection in ipairs(nested) do
                table.insert(dump.collections, collection)
            end

            local field_collections = collect_field_objects(obj, singleton.name)
            for _, collection in ipairs(field_collections) do
                table.insert(dump.collections, collection)
            end

            local direct_field_collections = collect_direct_field_objects(obj, singleton.name)
            for _, collection in ipairs(direct_field_collections) do
                table.insert(dump.collections, collection)
            end
        end
    end

    for _, collection in ipairs(dump.collections) do
        for _, item in ipairs(collection.items or {}) do
            table.insert(dump.items, item)
        end
    end

    last_dump = dump
    last_status = "Inventory candidate scan complete: " .. summarize_dump(dump)
    info(last_status)
    return dump
end

local function refresh_runtime_dump_fields(dump)
    if dump == nil then
        return
    end

    dump.generated_at = os.date("%Y-%m-%d %H:%M:%S")
    dump.enabled = config.enabled
    dump.read_only = config.read_only
    dump.config = dump.config or {}
    dump.config.enabled = config.enabled
    dump.config.read_only = config.read_only
    dump.config.items = config.items
    dump.config.grant_character_id = config.grant_character_id
    dump.config.grant_event_type = config.grant_event_type
    dump.config.block_on_min = config.block_on_min
    dump.config.restore_shortage = config.restore_shortage
    dump.config.method_probe_enabled = config.method_probe_enabled
    dump.config.max_method_probe_events = config.max_method_probe_events
    dump.config.max_observed_ui_events = config.max_observed_ui_events
    dump.observed_ui_events = observed_ui_events
    dump.known_observed_items = known_observed_items
    dump.restore_log = restore_log
    dump.block_log = block_log
    dump.method_probe_log = method_probe_log
    dump.hook_status = hook_status
end

local function write_dump_file(file_name)
    if last_dump == nil then
        dump_inventory_candidates()
    end

    refresh_runtime_dump_fields(last_dump)

    if json and json.dump_file then
        json.dump_file(file_name, last_dump)
        last_status = "Wrote dump to reframework/data/" .. file_name
        info(last_status)
    else
        last_status = "json.dump_file is unavailable; dump not written"
        warn(last_status)
    end
end

local function write_last_dump()
    write_dump_file(config.dump_file or DUMP_FILE)
end

local function write_timestamped_dump()
    local file_name = "dd2_item_guard_probe_" .. os.date("%Y%m%d_%H%M%S") .. ".json"
    write_dump_file(file_name)
end

local function draw_int_stepper(label, value, min_value, small_step, large_step)
    min_value = min_value or 1
    small_step = small_step or 10
    large_step = large_step or 100

    imgui.text(label .. ": " .. tostring(value))

    if imgui.button("-" .. tostring(large_step) .. "##" .. label) then
        value = math.max(min_value, value - large_step)
    end
    imgui.same_line()
    if imgui.button("-" .. tostring(small_step) .. "##" .. label) then
        value = math.max(min_value, value - small_step)
    end
    imgui.same_line()
    if imgui.button("+" .. tostring(small_step) .. "##" .. label) then
        value = math.max(min_value, value + small_step)
    end
    imgui.same_line()
    if imgui.button("+" .. tostring(large_step) .. "##" .. label) then
        value = math.max(min_value, value + large_step)
    end

    return value
end

local function observed_items_list()
    local list = {}
    for _, item in pairs(known_observed_items) do
        table.insert(list, item)
    end
    table.sort(list, function(a, b)
        local an = tostring(a.display_name or a.item_id)
        local bn = tostring(b.display_name or b.item_id)
        if an == bn then
            return tonumber(a.item_id or 0) < tonumber(b.item_id or 0)
        end
        return an < bn
    end)
    return list
end

local function rule_items_list()
    local list = {}
    if type(config.items) == "table" then
        for key, rule in pairs(config.items) do
            if type(rule) == "table" then
                rule.key = key
                table.insert(list, rule)
            end
        end
    end
    table.sort(list, function(a, b)
        return tostring(a.name or a.key) < tostring(b.name or b.key)
    end)
    return list
end

local function draw_enforcement_controls()
    imgui.text("Enforcement enabled: " .. tostring(config.enabled == true))
    imgui.text("Read-only mode: " .. tostring(config.read_only == true))
    imgui.text("Restore shortage by getItem: " .. tostring(config.restore_shortage == true))

    if config.enabled then
        if imgui.button("Disable enforcement") then
            config.enabled = false
            last_status = "Enforcement disabled"
        end
    else
        if imgui.button("Enable enforcement") then
            config.enabled = true
            last_status = "Enforcement enabled"
        end
    end

    if config.read_only then
        if imgui.button("Disable read-only mode") then
            config.read_only = false
            last_status = "Read-only mode disabled"
        end
    else
        if imgui.button("Enable read-only mode") then
            config.read_only = true
            last_status = "Read-only mode enabled"
        end
    end

    if config.enabled and config.read_only then
        imgui.text("Enforcement is blocked while read-only mode is true.")
    end

    if config.restore_shortage then
        if imgui.button("Disable getItem restore") then
            config.restore_shortage = false
            last_status = "getItem restore disabled"
        end
    else
        if imgui.button("Enable getItem restore") then
            config.restore_shortage = true
            last_status = "getItem restore enabled"
        end
    end
end

local function draw_observed_items()
    if imgui.tree_node("Observed UI items") then
        local list = observed_items_list()
        if #list == 0 then
            imgui.text("No observed item rows yet. Open the inventory and hover/scroll items.")
        end

        for _, item in ipairs(list) do
            local label = tostring(item.display_name or "<unnamed>") .. " | id " .. tostring(item.item_id) .. " | count " .. tostring(item.count)
            imgui.text(label)
            imgui.same_line()
            if imgui.button("Add min##obs_" .. tostring(item.item_id)) then
                add_or_update_min_rule(item.item_id, item.count or 1, item.display_name)
            end
        end

        imgui.tree_pop()
    end
end

local function draw_rules()
    if imgui.tree_node("Item guard rules") then
        local list = rule_items_list()
        if #list == 0 then
            imgui.text("No rules. Add one from Observed UI items.")
        end

        local remove_key = nil
        for _, rule in ipairs(list) do
            local key = tostring(rule.key)
            local title = tostring(rule.name or key) .. " | id " .. key
            local target_character_id = configured_character_id()
            local actual_count = get_have_num(tonumber(key), target_character_id)
            imgui.text(title)
            imgui.text("Mode: " .. tostring(rule.mode or "min") .. " / Enabled: " .. tostring(rule.enabled ~= false))
            imgui.text("Target character count: " .. tostring(actual_count) .. " / char=" .. tostring(target_character_id))
            rule.count = draw_int_stepper("Target##rule_" .. key, tonumber(rule.count) or 1, 1, 1, 10)

            if rule.enabled == false then
                if imgui.button("Enable rule##" .. key) then
                    rule.enabled = true
                end
            else
                if imgui.button("Disable rule##" .. key) then
                    rule.enabled = false
                end
            end

            imgui.same_line()
            if imgui.button("Use min##" .. key) then
                rule.mode = "min"
            end

            imgui.same_line()
            if imgui.button("Use fixed##" .. key) then
                rule.mode = "fixed"
            end

            imgui.same_line()
            if imgui.button("Remove##" .. key) then
                remove_key = key
            end
        end

        if remove_key ~= nil then
            config.items[remove_key] = nil
            last_status = "Removed rule " .. tostring(remove_key)
        end

        imgui.tree_pop()
    end
end

local function draw_restore_log()
    if imgui.tree_node("Restore log") then
        if #restore_log == 0 then
            imgui.text("No restore attempts yet.")
        end

        local start = math.max(1, #restore_log - 20)
        for i = start, #restore_log do
            local entry = restore_log[i]
            if entry ~= nil then
                imgui.text(
                    tostring(entry.time)
                    .. " item " .. tostring(entry.item_id)
                    .. " +" .. tostring(entry.amount)
                    .. " ok=" .. tostring(entry.ok)
                    .. " ret=" .. tostring(entry.result)
                    .. " char=" .. tostring(entry.character_id)
                    .. " before=" .. tostring(entry.before_count)
                    .. " after=" .. tostring(entry.after_count)
                    .. " " .. tostring(entry.error or entry.reason or "")
                )
            end
        end

        imgui.tree_pop()
    end
end

local function draw_block_log()
    if imgui.tree_node("Block log") then
        if #block_log == 0 then
            imgui.text("No block checks yet.")
        end

        local start = math.max(1, #block_log - 20)
        for i = start, #block_log do
            local entry = block_log[i]
            if entry ~= nil then
                imgui.text(
                    tostring(entry.time)
                    .. " item " .. tostring(entry.item_id)
                    .. " count=" .. tostring(entry.count)
                    .. " target=" .. tostring(entry.target)
                    .. " blocked=" .. tostring(entry.blocked)
                    .. " " .. tostring(entry.reason or "")
                )
            end
        end

        imgui.tree_pop()
    end
end

local function draw_method_probe_log()
    if imgui.tree_node("Method probe log") then
        imgui.text("Probe enabled: " .. tostring(config.method_probe_enabled == true))
        if config.method_probe_enabled then
            if imgui.button("Disable method probe") then
                config.method_probe_enabled = false
            end
        else
            if imgui.button("Enable method probe") then
                config.method_probe_enabled = true
            end
        end

        if imgui.button("Clear method probe log") then
            method_probe_log = {}
        end

        if #method_probe_log == 0 then
            imgui.text("No method probe events yet.")
        end

        local start = math.max(1, #method_probe_log - 30)
        for i = start, #method_probe_log do
            local entry = method_probe_log[i]
            if entry ~= nil then
                imgui.text(
                    tostring(entry.time)
                    .. " " .. tostring(entry.phase)
                    .. " " .. tostring(entry.method)
                    .. " ret=" .. tostring(entry.ret)
                )
            end
        end

        imgui.tree_pop()
    end
end

local function draw_ui()
    if not imgui then
        return
    end

    if imgui.tree_node(MOD) then
        imgui.text("Status: " .. tostring(last_status))
        draw_enforcement_controls()

        draw_observed_items()
        draw_rules()
        draw_restore_log()

        if imgui.tree_node("Probe and dump tools") then
            imgui.text(
                string.format(
                    "Last summary: types %d / singletons %d / collections %d / sampled items %d",
                    last_summary.type_count,
                    last_summary.singleton_count,
                    last_summary.collection_count,
                    last_summary.item_count
                )
            )
            imgui.text("Observed UI item events: " .. tostring(#observed_ui_events))
            imgui.text("Hook ItemWindowRef.setup: " .. tostring(hook_status.item_window_setup or "not installed"))
            imgui.text("Hook ItemManager.useItemSub: " .. tostring(hook_status.use_item_sub or "not installed"))

            config.max_collection_items = draw_int_stepper("Max collection items", config.max_collection_items, 1, 10, 100)
            config.max_nested_collection_items = draw_int_stepper("Max nested items", config.max_nested_collection_items, 1, 10, 100)
            config.max_observed_ui_events = draw_int_stepper("Max observed UI events", config.max_observed_ui_events, 1, 10, 100)

            if imgui.button("Clear observed UI events") then
                observed_ui_events = {}
                last_status = "Cleared observed UI item events"
            end

            if imgui.button("Probe types and singletons") then
                probe_types_and_singletons()
            end

            if imgui.button("Scan inventory candidates") then
                dump_inventory_candidates()
            end

            if imgui.button("Write JSON dump") then
                write_last_dump()
            end

            if imgui.button("Write Timestamped Dump") then
                write_timestamped_dump()
            end

            imgui.text("Dump: reframework/data/" .. tostring(config.dump_file or DUMP_FILE))
            imgui.tree_pop()
        end

        if imgui.button("Save config") then
            save_config()
        end

        imgui.text("Config: reframework/data/" .. CONFIG_FILE)
        imgui.tree_pop()
    end
end

config = load_config()
save_config()
install_observation_hooks()
info("Loaded DD2 Item Guard. UI: Script Generated UI > " .. MOD)

re.on_draw_ui(draw_ui)
