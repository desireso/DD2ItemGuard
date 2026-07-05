-- Dragon's Dogma 2 Item Guard - guarded item minimum counts
-- Place this file at: reframework/autorun/dd2_item_guard.lua
--
-- Defaults are safe: enforcement is disabled until explicitly enabled in UI.
-- Configured shortages are restored by calling ItemManager:getItem() with the
-- current player CharaID.

local MOD = "DD2 Item Guard"
local TAG = "[DD2IG] "
local CONFIG_FILE = "dd2_item_guard.json"
local UI_FONT_FILE = "D2Coding.ttf"

local UI_FONT_RANGES = {
    0x0020, 0x00FF, -- Basic Latin + Latin-1
    0x1100, 0x11FF, -- Hangul Jamo
    0x3130, 0x318F, -- Hangul Compatibility Jamo
    0xAC00, 0xD7AF, -- Hangul Syllables
    0x4E00, 0x9FFF, -- CJK Unified Ideographs
    0,
}

local DEFAULT_CONFIG = {
    config_version = 6,
    enabled = false,
    grant_character_id = -2,
    grant_event_type = 1,
    items = {},
}

local config = nil
local last_status = "Loaded. Open inventory, add observed items, then enable enforcement."

local read_number_field
local try_english_item_name
local cached_get_item_name_method = false
local cached_message_manager = false
local cached_message_methods = false
local cached_ui_font = false
local ui_font_logged = false
local english_name_cache = {}
local hooks_installed = false
local hook_status = {}
local known_observed_items = {}
local last_restore_time = {}
local pending_rule_counts = {}
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

local function is_valid_display_name(value)
    if value == nil then
        return false
    end

    local text = tostring(value)
    if text == "" or text == "nil" or text == "<nil>" then
        return false
    end
    if string.find(text, "sol.sdk:", 1, true) ~= nil then
        return false
    end
    if string.find(text, "REMethodDefinition", 1, true) ~= nil then
        return false
    end
    if string.find(text, "via.gui.", 1, true) ~= nil then
        return false
    end
    if string.find(text, "via.", 1, true) == 1 then
        return false
    end
    if string.match(text, "^0x%x+$") or string.match(text, "^0*%x%x%x%x%x%x%x%x+$") then
        return false
    end
    if string.match(text, "^%?+$") then
        return false
    end
    if string.match(text, "^%s+$") then
        return false
    end
    return true
end

local function load_config()
    local loaded = nil
    if json and json.load_file then
        loaded = json.load_file(CONFIG_FILE)
    end

    local merged = {
        config_version = DEFAULT_CONFIG.config_version,
        enabled = DEFAULT_CONFIG.enabled,
        grant_character_id = DEFAULT_CONFIG.grant_character_id,
        grant_event_type = DEFAULT_CONFIG.grant_event_type,
        items = {},
    }

    if type(loaded) == "table" then
        if type(loaded.enabled) == "boolean" then
            merged.enabled = loaded.enabled
        end
        if tonumber(loaded.grant_character_id) ~= nil then
            merged.grant_character_id = tonumber(loaded.grant_character_id)
        end
        if tonumber(loaded.grant_event_type) ~= nil then
            merged.grant_event_type = tonumber(loaded.grant_event_type)
        end
        if type(loaded.items) == "table" then
            merged.items = loaded.items
        end
    end

    if type(merged.items) ~= "table" then
        merged.items = {}
    end
    for key, rule in pairs(merged.items) do
        if type(rule) ~= "table" then
            merged.items[key] = nil
        else
            if type(rule) == "table" and not is_valid_display_name(rule.name) then
                rule.name = nil
            end
        end
    end

    return merged
end

local function config_for_save()
    local out = {
        config_version = DEFAULT_CONFIG.config_version,
        enabled = config and config.enabled == true or false,
        grant_character_id = config and tonumber(config.grant_character_id) or DEFAULT_CONFIG.grant_character_id,
        grant_event_type = config and tonumber(config.grant_event_type) or DEFAULT_CONFIG.grant_event_type,
        items = {},
    }

    if config ~= nil and type(config.items) == "table" then
        for key, rule in pairs(config.items) do
            if type(rule) == "table" then
                local count = math.max(1, math.floor(tonumber(rule.count) or 1))
                out.items[tostring(key)] = {
                    enabled = rule.enabled ~= false,
                    mode = "min",
                    count = count,
                    name = is_valid_display_name(rule.name) and tostring(rule.name) or nil,
                }
                rule.mode = "min"
                rule.count = count
            end
        end
    end

    return out
end

local function save_config()
    if json and json.dump_file then
        json.dump_file(CONFIG_FILE, config_for_save())
        info("Saved config to reframework/data/" .. CONFIG_FILE)
    else
        warn("json.dump_file is unavailable; config not saved")
    end
end

local function starts_with(value, prefix)
    value = tostring(value or "")
    return string.sub(value, 1, string.len(prefix)) == prefix
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

local function valid_display_text(value)
    if type(value) == "string" then
        if is_valid_display_name(value) then
            return value
        end
        return nil
    end

    local converted = scalar_or_string(value)
    if type(converted) == "string" and is_valid_display_name(converted) then
        return converted
    end
    return nil
end

local NAME_FIELD_CANDIDATES = {
    "_Name",
    "_name",
    "Name",
    "name",
    "_NameId",
    "_NameID",
    "_NameMsgId",
    "_NameMsgID",
    "_NameGuid",
    "_NameGUID",
    "_MsgId",
    "_MsgID",
    "_MsgGuid",
    "_MsgGUID",
    "_TxtName",
    "_TxtInfo",
    "NameId",
    "NameID",
    "NameMsg",
    "NameMsgId",
    "NameGuid",
    "MsgId",
    "MsgGuid",
    "TxtName",
    "TxtInfo",
}

local NAME_GETTER_CANDIDATES = {
    "get_Name",
    "get_name",
    "get_NameId",
    "get_NameID",
    "get_NameMsgId",
    "get_NameMsgID",
    "get_NameGuid",
    "get_NameGUID",
    "get_MsgId",
    "get_MsgID",
    "get_MsgGuid",
    "get_MsgGUID",
    "get_TxtName",
    "get_TxtInfo",
}

local ITEM_WINDOW_NAME_FIELD_CANDIDATES = {
    "_TxtName",
    "_TxtItemName",
    "_TxtTitle",
    "_TxtItemTitle",
    "_ItemName",
    "_Name",
    "_Title",
    "_TxtInfo",
    "TxtName",
    "TxtItemName",
    "TxtTitle",
    "ItemName",
    "Name",
    "Title",
}

local ITEM_WINDOW_NAME_GETTER_CANDIDATES = {
    "get_Name",
    "get_ItemName",
    "get_Title",
    "get_Text",
    "get_Message",
}

local TEXT_OBJECT_VALUE_CANDIDATES = {
    "get_Message",
    "get_Text",
    "get_String",
    "get_Caption",
    "get_Name",
    "get_Title",
    "ToString",
    "_Message",
    "_Text",
    "_String",
    "_Caption",
    "Message",
    "Text",
    "String",
    "Caption",
}

local MESSAGE_MANAGER_METHOD_CANDIDATES = {
    "getMessage",
    "getMessage(System.Int32)",
    "getMessage(System.UInt32)",
    "getMessage(System.String)",
    "getText",
    "getText(System.Int32)",
    "getText(System.UInt32)",
    "getText(System.String)",
    "getMessageText",
    "getMessageText(System.Int32)",
    "getMessageText(System.UInt32)",
    "getMessageText(System.String)",
    "getMessageByGuid",
    "getMessageByGuid(System.String)",
    "get_Message",
    "get_Text",
}

local function get_message_manager()
    if cached_message_manager ~= false then
        return cached_message_manager
    end

    cached_message_manager = safe("app.MessageManager managed singleton", function()
        return sdk.get_managed_singleton("app.MessageManager")
    end)
    if cached_message_manager ~= nil then
        return cached_message_manager
    end

    cached_message_manager = safe("app.MessageManager native singleton", function()
        if sdk.get_native_singleton then
            return sdk.get_native_singleton("app.MessageManager")
        end
        return nil
    end)
    return cached_message_manager
end

local function get_message_methods()
    if cached_message_methods ~= false then
        return cached_message_methods
    end

    local manager = get_message_manager()
    local methods = {}
    if manager ~= nil then
        local type_def = safe("app.MessageManager type", function()
            return manager:get_type_definition()
        end)
        if type_def == nil then
            type_def = safe("app.MessageManager type def", function()
                return sdk.find_type_definition("app.MessageManager")
            end)
        end
        if type_def ~= nil then
            for _, method_name in ipairs(MESSAGE_MANAGER_METHOD_CANDIDATES) do
                local method = safe("MessageManager method " .. method_name, function()
                    return type_def:get_method(method_name)
                end)
                if method ~= nil then
                    table.insert(methods, {
                        name = method_name,
                        method = method,
                    })
                end
            end
        end
    end

    cached_message_methods = methods
    if #methods == 0 then
        warn("No MessageManager method candidates found")
    end
    return methods
end

local function read_named_member(obj, name)
    if obj == nil then
        return nil
    end

    if starts_with(name, "get_") or name == "ToString" then
        local called = safe("call " .. name, function()
            return obj:call(name)
        end)
        if called ~= nil then
            return called, "method." .. name
        end
    end

    local value = safe("read " .. name, function()
        return obj[name]
    end)
    if value ~= nil then
        local value_text = tostring(value)
        if string.find(value_text, "REMethodDefinition", 1, true) == nil
            and string.find(value_text, "sol.sdk:", 1, true) == nil then
            return value, "field." .. name
        end
    end

    value = safe("call " .. name, function()
        return obj:call(name)
    end)
    if value ~= nil then
        return value, "method." .. name
    end

    return nil, nil
end

local function message_to_text(value)
    local manager = get_message_manager()
    local methods = get_message_methods()
    if manager ~= nil and type(methods) == "table" and #methods > 0 and value ~= nil then
        for _, entry in ipairs(methods) do
            local result = safe("MessageManager." .. entry.name, function()
                return entry.method:call(manager, value)
            end)
            local text = valid_display_text(result)
            if text ~= nil then
                return text, "app.MessageManager." .. entry.name
            end
        end
    end

    local direct = valid_display_text(value)
    if direct ~= nil then
        return direct, "direct"
    end

    return nil, nil
end

local function text_object_to_display_name(value)
    local text = valid_display_text(value)
    if text ~= nil then
        return text, "direct"
    end

    if value == nil then
        return nil, nil
    end

    for _, name in ipairs(TEXT_OBJECT_VALUE_CANDIDATES) do
        local candidate_value, source = read_named_member(value, name)
        if candidate_value ~= nil then
            local resolved, resolved_source = message_to_text(candidate_value)
            if resolved ~= nil then
                return resolved, tostring(source or name) .. " -> " .. tostring(resolved_source or "direct")
            end
        end
    end

    return nil, nil
end

local function try_item_window_display_name(item_window)
    if item_window == nil then
        return nil, nil
    end

    local first_seen_source = nil
    for _, name in ipairs(ITEM_WINDOW_NAME_FIELD_CANDIDATES) do
        local value, source = read_named_member(item_window, name)
        if value ~= nil then
            first_seen_source = first_seen_source or tostring(source or name)
            local text, text_source = text_object_to_display_name(value)
            if text ~= nil then
                return text, tostring(source or name) .. " -> " .. tostring(text_source or "direct")
            end
        end
    end

    for _, name in ipairs(ITEM_WINDOW_NAME_GETTER_CANDIDATES) do
        local value, source = read_named_member(item_window, name)
        if value ~= nil then
            first_seen_source = first_seen_source or tostring(source or name)
            local text, text_source = text_object_to_display_name(value)
            if text ~= nil then
                return text, tostring(source or name) .. " -> " .. tostring(text_source or "direct")
            end
        end
    end

    if first_seen_source ~= nil then
        return nil, first_seen_source .. " -> no display text"
    end

    return nil, nil
end

local function try_item_data_display_name(item_data)
    if item_data == nil then
        return nil, nil
    end

    for _, name in ipairs(NAME_FIELD_CANDIDATES) do
        local value, source = read_named_member(item_data, name)
        if value ~= nil then
            local text, resolved_source = message_to_text(value)
            if text ~= nil then
                return text, tostring(source or name) .. " -> " .. tostring(resolved_source or "direct")
            end
        end
    end

    for _, name in ipairs(NAME_GETTER_CANDIDATES) do
        local value, source = read_named_member(item_data, name)
        if value ~= nil then
            local text, resolved_source = message_to_text(value)
            if text ~= nil then
                return text, tostring(source or name) .. " -> " .. tostring(resolved_source or "direct")
            end
        end
    end

    return nil, nil
end

local ITEM_NAME_METHOD_CANDIDATES = {
    {
        label = "app.GUIBase.getItemName(id,false)",
        type_name = "app.GUIBase",
        method_name = "getItemName(System.Int32, System.Boolean)",
        call = function(method, target, item_id)
            return method:call(target, item_id, false)
        end,
    },
    {
        label = "app.GUIBase.getItemName(id)",
        type_name = "app.GUIBase",
        method_name = "getItemName(System.Int32)",
        call = function(method, target, item_id)
            return method:call(target, item_id)
        end,
    },
    {
        label = "app.GuiManager.getItemName(id,false)",
        type_name = "app.GuiManager",
        method_name = "getItemName(System.Int32, System.Boolean)",
        singleton = true,
        call = function(method, target, item_id)
            return method:call(target, item_id, false)
        end,
    },
    {
        label = "app.GuiManager.getItemName(id)",
        type_name = "app.GuiManager",
        method_name = "getItemName(System.Int32)",
        singleton = true,
        call = function(method, target, item_id)
            return method:call(target, item_id)
        end,
    },
    {
        label = "app.GUIBase.getElfItemName(id,false)",
        type_name = "app.GUIBase",
        method_name = "getElfItemName(System.Int32, System.Boolean)",
        call = function(method, target, item_id)
            return method:call(target, item_id, false)
        end,
    },
    {
        label = "app.GUIBase.getElfItemName(id,true)",
        type_name = "app.GUIBase",
        method_name = "getElfItemName(System.Int32, System.Boolean)",
        call = function(method, target, item_id)
            return method:call(target, item_id, true)
        end,
    },
}

local function get_item_name_methods()
    if cached_get_item_name_method ~= false then
        return cached_get_item_name_method
    end

    local methods = {}
    for _, candidate in ipairs(ITEM_NAME_METHOD_CANDIDATES) do
        local type_def = safe(candidate.type_name .. " type", function()
            return sdk.find_type_definition(candidate.type_name)
        end)
        if type_def ~= nil then
            local method = safe(candidate.label, function()
                return type_def:get_method(candidate.method_name)
            end)
            if method ~= nil then
                table.insert(methods, {
                    label = candidate.label,
                    type_name = candidate.type_name,
                    singleton = candidate.singleton == true,
                    call = candidate.call,
                    method = method,
                })
            end
        end
    end

    cached_get_item_name_method = methods
    if #methods == 0 then
        warn("No item name method candidates found; item names may be unavailable")
    end

    return cached_get_item_name_method
end

local function get_item_name_target(candidate)
    if candidate.singleton ~= true then
        return nil
    end

    local target = safe(candidate.type_name .. " managed singleton", function()
        return sdk.get_managed_singleton(candidate.type_name)
    end)
    if target ~= nil then
        return target
    end

    return safe(candidate.type_name .. " native singleton", function()
        return sdk.get_native_singleton(candidate.type_name)
    end)
end

local function try_item_display_name(item_id, item_data, ui_name, ui_name_source)
    if type(item_id) ~= "number" then
        return nil
    end

    local ui_text = valid_display_text(ui_name)
    if ui_text ~= nil then
        return ui_text, tostring(ui_name_source or "ItemWindowRef UI text")
    end

    local data_name, data_source = try_item_data_display_name(item_data)
    if data_name ~= nil then
        return data_name, data_source
    end

    local methods = get_item_name_methods()
    if type(methods) ~= "table" or #methods == 0 then
        return nil
    end

    for _, candidate in ipairs(methods) do
        local target = get_item_name_target(candidate)
        if candidate.singleton ~= true or target ~= nil then
            local value = safe(candidate.label, function()
                return candidate.call(candidate.method, target, item_id)
            end)
            local text = valid_display_text(value)
            if text ~= nil then
                return text, candidate.label
            end
        end
    end

    return nil
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

    if not ok then
        warn("getItem failed item " .. tostring(item_id) .. " amount " .. tostring(amount) .. ": " .. tostring(err))
        return false, tostring(err)
    end

    info("getItem item " .. tostring(item_id) .. " amount " .. tostring(amount) ..
        " char " .. tostring(character_id) ..
        " before " .. tostring(before_count) ..
        " after " .. tostring(after_count) ..
        " result " .. tostring(scalar_or_string(result)) ..
        " reason " .. tostring(reason) ..
        (character_error and (" character_error " .. tostring(character_error)) or ""))

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
    if config == nil or config.enabled ~= true then
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

    if mode ~= "min" then
        return
    end

    local target_character_id = configured_character_id()
    local count = tonumber(get_have_num(item_id, target_character_id))
    local count_source = "getHaveNum"
    if count == nil then
        warn("Skip restore for item " .. tostring(item_id) .. ": target character count unavailable")
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
    local ok, err = give_item(item_id, missing, "min restore from " .. count_source .. " count " .. tostring(count) .. " to " .. tostring(target))
    if ok then
        last_status = "Restored item " .. tostring(item_id) .. " by +" .. tostring(missing)
        info(last_status)
    else
        last_status = "Restore failed for item " .. tostring(item_id) .. ": " .. tostring(err)
        warn(last_status)
    end
end

local function remember_observed_item(event)
    local item_id = tonumber(event.item_id)
    if item_id == nil then
        return
    end

    known_observed_items[tostring(item_id)] = {
        item_id = item_id,
        display_name = event.display_name,
        display_name_source = event.display_name_source,
        count = event.count,
        item_type = event.item_type,
        last_seen = event.time,
    }
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

    local ui_name = extra and extra.ui_name or nil
    local ui_name_source = extra and extra.ui_name_source or nil
    local display_name, display_name_source = try_item_display_name(id, item_data, ui_name, ui_name_source)
    local event = {
        source = source,
        time = os.date("%Y-%m-%d %H:%M:%S"),
        item_id = id,
        item_id_source = id_source,
        display_name = display_name,
        display_name_source = display_name_source,
        count = count,
        item_type = object_type_name(item_data),
        extra = extra,
    }

    remember_observed_item(event)
    maybe_restore_observed_item(event)
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
                    local storage = thread and thread.get_hook_storage and thread.get_hook_storage() or nil
                    local item_data = sdk.to_managed_object(args[3])
                    local count = ptr_to_int(args[4])
                    if storage ~= nil then
                        storage.item_window = sdk.to_managed_object(args[2])
                        storage.item_data = item_data
                        storage.count = count
                        storage.bool_arg = ptr_to_int(args[5])
                    else
                        record_observed_ui_item("app.GUIBase.ItemWindowRef.setup", item_data, count, {
                            bool_arg = ptr_to_int(args[5]),
                            ui_name = nil,
                            ui_name_source = "hook storage unavailable",
                        })
                    end
                end)
            end, function(ret)
                pcall(function()
                    local storage = thread and thread.get_hook_storage and thread.get_hook_storage() or nil
                    if storage ~= nil and storage.item_data ~= nil then
                        local ui_name, ui_name_source = try_item_window_display_name(storage.item_window)
                        record_observed_ui_item("app.GUIBase.ItemWindowRef.setup", storage.item_data, storage.count, {
                            bool_arg = storage.bool_arg,
                            ui_name = ui_name,
                            ui_name_source = ui_name_source,
                            item_window_type = object_type_name(storage.item_window),
                        })
                        storage.item_window = nil
                        storage.item_data = nil
                        storage.count = nil
                        storage.bool_arg = nil
                    end
                end)
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
                pcall(function()
                    local item_data = sdk.to_managed_object(args[5])
                    record_observed_ui_item("app.ItemManager.useItemSub", item_data, nil, {
                        from_type = object_type_name(sdk.to_managed_object(args[3])),
                        to_type = object_type_name(sdk.to_managed_object(args[4])),
                    })
                end)
            end, function(ret)
                return ret
            end)
        end)
        hook_status.use_item_sub = ok and "installed" or tostring(err)
    else
        hook_status.use_item_sub = "method not found"
    end

    info("Observation hooks: ItemWindowRef.setup=" .. tostring(hook_status.item_window_setup) .. ", useItemSub=" .. tostring(hook_status.use_item_sub))
end

local COLOR_ON_MIN = 0xff33cc66
local COLOR_ON_MIN_HOVER = 0xff44dd77
local ITEM_COLUMN_CURRENT_X = 245
local ITEM_COLUMN_TARGET_X = 340
local ITEM_COLUMN_MIN_X = 465
local ITEM_NAME_DISPLAY_WIDTH = 22

local function format_item_current(count)
    if count == nil then
        return "current   ?"
    end
    return string.format("current %3s", tostring(math.floor(tonumber(count) or 0)))
end

local function ui_display_name(row)
    local item_id = row and row.item_id or nil
    if cached_ui_font == nil then
        local fallback = try_english_item_name(item_id)
        if is_valid_display_name(fallback) then
            return tostring(fallback)
        end
    end

    local name = row and row.display_name or nil
    if is_valid_display_name(name) then
        return tostring(name)
    end

    local rule = row and row.rule or nil
    if type(rule) == "table" and is_valid_display_name(rule.name) then
        return tostring(rule.name)
    end

    return "<unnamed>"
end

try_english_item_name = function(item_id)
    item_id = tonumber(item_id)
    if item_id == nil then
        return nil
    end

    local key = tostring(item_id)
    if english_name_cache[key] ~= nil then
        return english_name_cache[key] ~= false and english_name_cache[key] or nil
    end

    english_name_cache[key] = false
    local type_def = safe("GUIBase type for English item name", function()
        return sdk.find_type_definition("app.GUIBase")
    end)
    if type_def == nil then
        return nil
    end

    local method = safe("getElfItemName English method", function()
        return type_def:get_method("getElfItemName(System.Int32, System.Boolean)")
    end)
    if method == nil then
        return nil
    end

    local value = safe("getElfItemName English", function()
        return method:call(nil, item_id, true)
    end)
    local text = valid_display_text(value)
    if text ~= nil then
        english_name_cache[key] = text
        return text
    end

    return nil
end

local function utf8_next_codepoint(text, index)
    local b1 = string.byte(text, index)
    if b1 == nil then
        return nil, nil, index + 1
    end

    if b1 < 0x80 then
        return string.sub(text, index, index), b1, index + 1
    end

    local b2 = string.byte(text, index + 1) or 0
    if b1 >= 0xC0 and b1 < 0xE0 then
        local cp = ((b1 & 0x1F) << 6) | (b2 & 0x3F)
        return string.sub(text, index, index + 1), cp, index + 2
    end

    local b3 = string.byte(text, index + 2) or 0
    if b1 >= 0xE0 and b1 < 0xF0 then
        local cp = ((b1 & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
        return string.sub(text, index, index + 2), cp, index + 3
    end

    local b4 = string.byte(text, index + 3) or 0
    if b1 >= 0xF0 and b1 < 0xF8 then
        local cp = ((b1 & 0x07) << 18) | ((b2 & 0x3F) << 12) | ((b3 & 0x3F) << 6) | (b4 & 0x3F)
        return string.sub(text, index, index + 3), cp, index + 4
    end

    return string.sub(text, index, index), b1, index + 1
end

local function display_cell_width(codepoint)
    if codepoint == nil then
        return 1
    end

    if (codepoint >= 0x1100 and codepoint <= 0x11FF)
        or (codepoint >= 0x2E80 and codepoint <= 0xA4CF)
        or (codepoint >= 0xAC00 and codepoint <= 0xD7AF)
        or (codepoint >= 0xF900 and codepoint <= 0xFAFF)
        or (codepoint >= 0xFE10 and codepoint <= 0xFE6F)
        or (codepoint >= 0xFF00 and codepoint <= 0xFF60) then
        return 2
    end

    return 1
end

local function fixed_display_width_text(text, target_width)
    text = tostring(text or "")
    local pieces = {}
    local width = 0
    local index = 1

    while index <= #text do
        local char, codepoint, next_index = utf8_next_codepoint(text, index)
        local char_width = display_cell_width(codepoint)
        if width + char_width > target_width then
            break
        end
        table.insert(pieces, char)
        width = width + char_width
        index = next_index
    end

    if width < target_width then
        table.insert(pieces, string.rep(" ", target_width - width))
    end

    return table.concat(pieces)
end

local function fixed_item_display_name(row)
    return fixed_display_width_text(ui_display_name(row), ITEM_NAME_DISPLAY_WIDTH)
end

local function get_ui_font()
    if cached_ui_font ~= false then
        return cached_ui_font
    end

    cached_ui_font = nil
    if imgui == nil or imgui.load_font == nil then
        if not ui_font_logged then
            warn("imgui.load_font unavailable; Korean UI font was not loaded")
            ui_font_logged = true
        end
        return nil
    end

    local ok, font = pcall(function()
        return imgui.load_font(UI_FONT_FILE, 18, UI_FONT_RANGES)
    end)
    if ok and font ~= nil then
        cached_ui_font = font
        if not ui_font_logged then
            info("Loaded UI font reframework/fonts/" .. UI_FONT_FILE)
            ui_font_logged = true
        end
        return cached_ui_font
    end

    if not ui_font_logged then
        warn("Failed to load UI font reframework/fonts/" .. UI_FONT_FILE .. ": " .. tostring(font))
        ui_font_logged = true
    end
    return nil
end

local function push_ui_font_if_available()
    local font = get_ui_font()
    if font == nil or imgui.push_font == nil then
        return false
    end

    local ok = pcall(function()
        imgui.push_font(font)
    end)
    return ok == true
end

local function pop_ui_font_if_pushed(pushed)
    if pushed and imgui.pop_font ~= nil then
        pcall(function()
            imgui.pop_font()
        end)
    end
end

local function item_rows_list()
    local by_key = {}
    for _, item in pairs(known_observed_items) do
        local item_id = tonumber(item.item_id)
        if item_id ~= nil then
            by_key[tostring(item_id)] = {
                item_id = item_id,
                display_name = item.display_name,
                display_name_source = item.display_name_source,
                observed_count = item.count,
                last_seen = item.last_seen,
            }
        end
    end

    if type(config.items) == "table" then
        for key, rule in pairs(config.items) do
            if type(rule) == "table" then
                local item_id = tonumber(key)
                if item_id ~= nil then
                    local row = by_key[tostring(item_id)] or {
                        item_id = item_id,
                    }
                    row.rule = rule
                    if not is_valid_display_name(row.display_name) then
                        row.display_name = nil
                    end
                    if row.display_name == nil and is_valid_display_name(rule.name) then
                        row.display_name = rule.name
                    end
                    by_key[tostring(item_id)] = row
                end
            end
        end
    end

    local list = {}
    for _, row in pairs(by_key) do
        table.insert(list, row)
    end
    table.sort(list, function(a, b)
        return tonumber(a.item_id or 0) < tonumber(b.item_id or 0)
    end)
    return list
end

local function set_item_rule(item_id, mode, count, display_name)
    item_id = tonumber(item_id)
    if item_id == nil then
        return
    end
    count = math.max(1, math.floor(tonumber(count) or 1))
    config.items = config.items or {}
    config.items[tostring(item_id)] = {
        enabled = true,
        mode = mode,
        count = count,
        name = is_valid_display_name(display_name) and display_name or nil,
    }
    pending_rule_counts[tostring(item_id)] = count
    last_status = "Set " .. tostring(mode) .. " rule: " .. tostring(display_name or item_id) .. " = " .. tostring(count)
    info(last_status)
end

local function toggle_item_rule(row, mode, target)
    local key = tostring(row.item_id)
    local rule = config.items and config.items[key] or nil
    if type(rule) == "table" and rule.enabled ~= false and tostring(rule.mode or "min") == mode then
        config.items[key] = nil
        last_status = "Removed rule " .. key
        return
    end
    set_item_rule(row.item_id, mode, target, ui_display_name(row))
end

local function push_button_color_if_supported(color, hover_color)
    if imgui.push_style_color == nil then
        return 0
    end

    local pushed = 0
    local colors = {
        { 21, color },
        { 22, hover_color or color },
        { 23, color },
    }
    for _, pair in ipairs(colors) do
        local ok = pcall(function()
            imgui.push_style_color(pair[1], pair[2])
        end)
        if ok then
            pushed = pushed + 1
        else
            break
        end
    end
    return pushed
end

local function pop_button_color_if_supported(count)
    if count <= 0 or imgui.pop_style_color == nil then
        return
    end

    local ok = pcall(function()
        imgui.pop_style_color(count)
    end)
    if ok then
        return
    end

    for _ = 1, count do
        pcall(function()
            imgui.pop_style_color()
        end)
    end
end

local function draw_mode_button(label, active, color, hover_color, id)
    local pushed = 0
    if active then
        pushed = push_button_color_if_supported(color, hover_color)
    end
    local text = label
    if active and pushed <= 0 then
        text = label .. " ON"
    end
    local clicked = imgui.button(text .. "##" .. id)
    pop_button_color_if_supported(pushed)
    return clicked
end

local function draw_top_controls()
    local changed = nil
    local value = nil
    if imgui.checkbox then
        changed, value = imgui.checkbox("Item Guard Enabled", config.enabled == true)
        if changed then
            config.enabled = value == true
            last_status = config.enabled and "Item Guard enabled" or "Item Guard disabled"
        end
    else
        imgui.text("Item Guard Enabled: " .. tostring(config.enabled == true))
        if imgui.button((config.enabled and "Disable" or "Enable") .. " Item Guard") then
            config.enabled = not config.enabled
            last_status = config.enabled and "Item Guard enabled" or "Item Guard disabled"
        end
    end

end

local function draw_config_controls()
    if imgui.button("Save config") then
        save_config()
    end
    imgui.same_line()
    imgui.text("reframework/data/" .. CONFIG_FILE)
end

local function begin_items_columns()
    if imgui.columns == nil then
        return false
    end

    local ok = pcall(function()
        imgui.columns(4, "dd2_item_guard_items_columns", false)
    end)
    if not ok then
        return false
    end

    if imgui.set_column_width then
        pcall(function() imgui.set_column_width(0, 245) end)
        pcall(function() imgui.set_column_width(1, 95) end)
        pcall(function() imgui.set_column_width(2, 125) end)
        pcall(function() imgui.set_column_width(3, 70) end)
    end

    return true
end

local function end_items_columns()
    if imgui.columns then
        pcall(function()
            imgui.columns(1)
        end)
    end
end

local function next_item_column()
    if imgui.next_column then
        pcall(function()
            imgui.next_column()
        end)
    end
end

local function same_line_at(x)
    if imgui.same_line == nil then
        return false
    end

    local ok = pcall(function()
        imgui.same_line(x)
    end)
    if ok then
        return true
    end

    pcall(function()
        imgui.same_line()
    end)
    return false
end

local function draw_target_input(key, target, rule)
    if imgui.push_item_width then
        imgui.push_item_width(100)
    end
    local changed, new_target = imgui.drag_int("Target##target_" .. key, target, 1, 1, 9999)
    if imgui.pop_item_width then
        imgui.pop_item_width()
    end
    if changed then
        new_target = math.max(1, math.floor(tonumber(new_target) or target))
        pending_rule_counts[key] = new_target
        if type(rule) == "table" then
            rule.count = new_target
        end
        return new_target
    end
    return target
end

local function draw_item_row_columns(row, key, rule, target, actual_count, observed_count, min_active)
    imgui.text(fixed_item_display_name(row))
    next_item_column()
    imgui.text(format_item_current(actual_count or observed_count))
    next_item_column()
    target = draw_target_input(key, target, rule)
    next_item_column()
    if draw_mode_button("Min", min_active, COLOR_ON_MIN, COLOR_ON_MIN_HOVER, "mode_min_" .. key) then
        toggle_item_rule(row, "min", target)
    end
    next_item_column()
end

local function draw_item_row_positioned(row, key, rule, target, actual_count, observed_count, min_active)
    imgui.text(fixed_item_display_name(row))
    same_line_at(ITEM_COLUMN_CURRENT_X)
    imgui.text(format_item_current(actual_count or observed_count))
    same_line_at(ITEM_COLUMN_TARGET_X)
    target = draw_target_input(key, target, rule)
    same_line_at(ITEM_COLUMN_MIN_X)
    if draw_mode_button("Min", min_active, COLOR_ON_MIN, COLOR_ON_MIN_HOVER, "mode_min_" .. key) then
        toggle_item_rule(row, "min", target)
    end
end

local function draw_items()
    if imgui.tree_node("Items") then
        local list = item_rows_list()
        if #list == 0 then
            imgui.text("No item rows yet. Open the inventory and hover/scroll items.")
        end

        local using_columns = begin_items_columns()
        for _, row in ipairs(list) do
            local key = tostring(row.item_id)
            local rule = row.rule
            local mode = type(rule) == "table" and tostring(rule.mode or "min") or nil
            local target_character_id = configured_character_id()
            local actual_count = get_have_num(row.item_id, target_character_id)
            local target = tonumber(rule and rule.count) or tonumber(pending_rule_counts[key]) or tonumber(row.observed_count) or tonumber(actual_count) or 1
            target = math.max(1, math.floor(target))

            local min_active = type(rule) == "table" and rule.enabled ~= false and mode == "min"
            if using_columns then
                draw_item_row_columns(row, key, rule, target, actual_count, row.observed_count, min_active)
            else
                draw_item_row_positioned(row, key, rule, target, actual_count, row.observed_count, min_active)
            end
        end
        if using_columns then
            end_items_columns()
        end

        imgui.tree_pop()
    end
end

local function draw_ui()
    if not imgui then
        return
    end

    local font_pushed = push_ui_font_if_available()
    if imgui.tree_node(MOD) then
        imgui.text("Status: " .. tostring(last_status))
        draw_top_controls()
        draw_config_controls()

        draw_items()
        imgui.tree_pop()
    end
    pop_ui_font_if_pushed(font_pushed)
end

config = load_config()
install_observation_hooks()
info("Loaded DD2 Item Guard. UI: Script Generated UI > " .. MOD)

re.on_draw_ui(draw_ui)
