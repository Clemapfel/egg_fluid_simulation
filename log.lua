--- @brief Logging module for error and warning handling
--- @module log

local log = {}

--- @brief Internal function to throw error or warning with pretty printing
--- @param is_fatal boolean true for error, false for warning
--- @param ... any message parts to concatenate
--- @return nil
local function throw(is_fatal, ...)
    -- make it so output is flushed to console immediately, because
    -- love.errorhandler does not flush
    io.stdout:setvbuf("no")

    local message = {}
    if is_fatal then
        table.insert(message, "[ERROR]")
    else
        table.insert(message, "[WARNING]")
    end

    -- get current line number, if possible
    -- skip 3 levels: throw -> error/warning -> caller
    local debug_line_number_acquired = false
    if debug ~= nil then
        local info = debug.getinfo(3, "Sl")
        if info ~= nil and info.short_src ~= nil and info.currentline ~= nil then
            table.insert(message, "In " .. info.short_src .. ":" .. info.currentline .. ": ")
            debug_line_number_acquired = true
        end
    end

    for i = 1, select("#", ...) do
        local arg = select(i, ...)
        table.insert(message, tostring(arg))
    end

    message = table.concat(message, " ")

    -- write to error stream and flush
    if is_fatal then
        error(message, 0)  -- 0 = don't add traceback level info
    else
        io.stderr:write(message .. "\n")
        io.stderr:flush()
    end
end

--- @brief Throw fatal error that halts execution
--- @param ... any message parts to concatenate
--- @return nil
function log.error(...)
    return throw(true, ...)
end

--- @brief Throw non-fatal warning
--- @param ... any message parts to concatenate
--- @return nil
function log.warning(...)
    return throw(false, ...)
end

--- @brief Assert function arguments to be of a specific type
--- @param ... any alternating pairs of (value, expected_type_string)
--- @return boolean true if all assertions pass, false otherwise
function log.assert(...)
    local n = select("#", ...)
    if n % 2 ~= 0 then
        log.error("In log.assert_types: number of arguments is not a multiple of 2")
        return false
    end

    for i = 1, n, 2 do
        local instance = select(i + 0, ...)
        local expected_type = select(i + 1, ...)
        local actual_type = type(instance)

        if actual_type ~= expected_type then
            log.error(
                "for argument #", math.floor(i / 2) + 1,
                ": expected `", expected_type,
                "`, got `", actual_type, "`"
            )
            return false
        end
    end

    return true
end

return log