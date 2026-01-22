--- @class Path
local Path = {}
setmetatable(Path, {
    __call = function(self, ...)
        return Path.new(...)
    end
})

local log = require "egg_fluid_simulation.log"

local _type_metatable = { __index = Path }

--- @brief create a new path from points
--- @param points number|number[] first x coord or flat array { x1, y1, x2, y2, ... }
--- @param ... number remaining coordinates if first param is number
--- @return Path
function Path.new(points, ...)
    local self = setmetatable({}, _type_metatable)

    if type(points) == "number" then
        points = { points, ... }
    end

    assert(#points % 2 == 0, "In Path: number of point coordinates must be even")

    self._points = points
    self._entries = {}
    self._n_points = #points
    self._n_entries = 0
    self._length = 0
    self._first_distance = 0
    self._last_distance = 0
    self._use_arclength = false

    self:create_from(points, ...)
    return self
end

--- @brief get position at parameter t
--- @param t number parameter value in [0, 1]
--- @return number, number x and y coordinates
function Path:at(t)
    t = math.clamp(t, 0, 1)

    local segment = self:_find_segment(t)
    local local_t = (t - segment.fraction) / segment.fraction_length

    local distance_along_segment = local_t * segment.distance
    return math.add(
        segment.from_x,
        segment.from_y,
        segment.dx * distance_along_segment,
        segment.dy * distance_along_segment
    )
end

--- @brief get the segment endpoints at parameter t
--- @param t number parameter value in [0, 1]
--- @return number, number, number, number from_x, from_y, to_x, to_y
function Path:get_segment(t)
    local segment = self:_find_segment(math.clamp(t, 0, 1))
    return segment.from_x, segment.from_y, segment.to_x, segment.to_y
end

--- @brief get tangent direction at parameter t
--- @param t number parameter value in [0, 1]
--- @return number, number normalized direction vector dx, dy
function Path:tangent_at(t)
    local segment = self:_find_segment(math.clamp(t, 0, 1))
    return segment.dx, segment.dy
end


--- @brief create path from list of points
--- @param ... number|number[] coordinates as individual numbers or flat array
--- @return Path
function Path:create_from(...)
    return self:_create_from(
        false, -- resample with uniform spacing
        false, -- arc-length parameterize
        ...
    )
end

--- @brief create path from list of points, then apply arc-length parameterization
--- @param ... number|number[] coordinates as individual numbers or flat array
--- @return Path
function Path:create_from_and_reparameterize(...)
    return self:_create_from(
        false,
        true,
        ...
    )
end

--- @brief create path from list of points, then resample uniformly
--- @param ... number|number[] coordinates as individual numbers or flat array
--- @return Path
function Path:create_from_and_resample(...)
    return self:_create_from(
        true,
        true,
        ...
    )
end


--- @brief get path points
--- @return table[] array of point tables
function Path:get_points()
    local out = {}
    for i = 1, self._n_points, 2 do
        table.insert(out, {self._points[i], self._points[i+1]})
    end
    return out
end

--- @brief get total length of path
--- @return number total length
function Path:get_length()
    return self._length
end

--- @brief overrides (arc-length) parameterization with custom per-segment fractions
--- @param ... number fraction values for each segment, must sum to 1
function Path:override_parameterization(...)
    local n_args = select("#", ...)
    if n_args ~= self._n_entries then
        rt.error("In Path.override_parameterization: expected `",  self._n_entries,  "` parameters, got `",  n_args,  "`")
        return
    end

    local total = 0
    local args = {...}

    -- validate arguments sum to 1
    for i = 1, n_args do
        local arg = args[i]
        if type(arg) ~= "number" or arg < 0 then
            rt.error("In Path:override_parameterization: parameter ",  i,  " must be a non-negative number")
            return
        end
        total = total + arg
    end

    if math.abs(total - 1) > 1e-10 then
        rt.error("In Path:override_parameterization: total length of override parameters is `",  total,  "`, but `1` was expected")
        return
    end

    local fraction = 0
    for i = 1, self._n_entries do
        local entry = self._entries[i]
        entry.fraction = fraction
        entry.fraction_length = args[i]
        fraction = fraction + args[i]
    end
end

--- @brief get the number of segments in the path
--- @return number segment count
function Path:get_segment_count()
    return self._n_entries
end


--- @brief find the closest point on the path to given coordinates
--- @param x number query point x coordinate
--- @param y number query point y coordinate
--- @return number|nil, number|nil, number|nil closest x, y and parameter t, or nil if path is empty
function Path:get_closest_point(x, y)
    if self._n_entries == 0 then
        return nil, nil, nil
    end

    local closest_distance_sq = math.huge
    local closest_x, closest_y = nil, nil
    local closest_t = 0

    for i = 1, self._n_entries do
        local entry = self._entries[i]
        local segment_x, segment_y, segment_t = self:_closest_point_on_segment(x, y, entry)

        local dx = segment_x - x
        local dy = segment_y - y
        local distance_sq = dx * dx + dy * dy

        if distance_sq < closest_distance_sq then
            closest_distance_sq = distance_sq
            closest_x = segment_x
            closest_y = segment_y
            closest_t = segment_t
        end
    end

    return closest_x, closest_y, closest_t
end

--- @brief get the flat array of point coordinates
--- @return number[] flat array [x1, y1, x2, y2, ...]
function Path:get_points()
    return self._points
end

--- ### internals, never call any of the functions below ###

--- @brief [internal] updates internal segment entries and calculates distances
function Path:_update()
    local entries = {}
    local points = self._points
    local n_points = self._n_points
    local total_length = 0
    local n_entries = 0

    -- create entries for each line segment
    for i = 1, n_points - 2, 2 do
        local x1, y1 = points[i], points[i+1]
        local x2, y2 = points[i+2], points[i+3]

        local dx = x2 - x1
        local dy = y2 - y1
        local distance = math.distance(x1, y1, x2, y2)
        dx, dy = math.normalize(dx, dy)

        local entry = {
            from_x = x1,
            from_y = y1,
            to_x = x2,
            to_y = y2,
            dx = dx,  -- normalized direction vector
            dy = dy,
            distance = distance,
            cumulative_distance = total_length,
            fraction = 0, -- set below
            fraction_length = 0
        }

        table.insert(entries, entry)
        total_length = total_length + distance
        n_entries = n_entries + 1
    end

    if n_entries == 1 then
        entries[1].fraction = 0
        entries[1].fraction_length = 1
    else
        -- calculate fractions based on whether arc-length parameterization is enabled
        if self._use_arclength then
            -- arc-length: fractions based on cumulative distance
            for i = 1, n_entries do
                local entry = entries[i]
                if total_length > 0 then
                    entry.fraction = entry.cumulative_distance / total_length
                    if i < n_entries then
                        local next_entry = entries[i + 1]
                        entry.fraction_length = (next_entry.cumulative_distance - entry.cumulative_distance) / total_length
                    else
                        entry.fraction_length = (total_length - entry.cumulative_distance) / total_length
                    end
                else
                    -- handle degenerate case where all segments have zero length
                    entry.fraction = i == 1 and 0 or 1
                    entry.fraction_length = 0
                end
            end
        else
            -- uniform: equal fraction for each segment
            local fraction_per_segment = 1 / n_entries
            for i = 1, n_entries do
                local entry = entries[i]
                entry.fraction = (i - 1) * fraction_per_segment
                entry.fraction_length = fraction_per_segment
            end
        end
    end

    self._entries = entries
    self._n_entries = n_entries
    self._length = total_length
    self._first_distance = n_entries > 0 and entries[1].fraction or 0
    self._last_distance = n_entries > 0 and entries[n_entries].fraction or 0
end

--- @brief [internal] finds the segment entry at parameter t using binary search
--- @param t number parameter value in [0, 1]
--- @return table|nil segment entry or nil if no segments exist
function Path:_find_segment(t)
    local entries = self._entries
    local n_entries = self._n_entries

    if n_entries == 0 then
        return nil
    end

    if n_entries == 1 then
        return entries[1]
    end

    if t <= 0 then
        return entries[1]
    elseif t >= 1 then
        return entries[n_entries]
    end

    -- binary search for the correct segment
    local low = 1
    local high = n_entries

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local entry = entries[mid]
        local entry_end = entry.fraction + entry.fraction_length

        if t >= entry.fraction and t <= entry_end then
            return entry
        elseif t < entry.fraction then
            high = mid - 1
        else
            low = mid + 1
        end
    end

    return entries[math.clamp(low, 1, n_entries)]
end

--- @brief [internal] create from points
--- @param reparameterize_as_uniform boolean whether to resample points uniformly
--- @param use_arclength boolean whether to use arc-length parameterization
--- @param points number|number[] first coordinate or flat array
--- @param ... number remaining coordinates
--- @return Path
--- @private
function Path:_create_from(reparameterize_as_uniform, use_arclength, points, ...)
    if type(points) == "number" then
        points = { points, ... }
    end

    if points == nil or #points < 2 then
        points = { 0, 0, 0, 0 }
    elseif #points < 4 then
        table.insert(points, points[1])
        table.insert(points, points[2])
    end

    local n_points = #points
    assert(n_points % 2 == 0, "In Path: number of point coordinates must be even")

    -- reparameterize to uniform spacing if requested
    if reparameterize_as_uniform then
        local num_points = n_points / 2

        -- calculate cumulative distances
        local distances = { 0 }
        local total_length = 0
        for i = 1, n_points - 2, 2 do
            local dist = math.distance(points[i], points[i+1], points[i+2], points[i+3])
            total_length = total_length + dist
            distances[#distances + 1] = total_length
        end

        if total_length > 0 then
            local uniform_points = {}
            local target_spacing = total_length / (num_points - 1)
            local num_segments = #distances - 1

            -- first point
            uniform_points[1] = points[1]
            uniform_points[2] = points[2]

            -- intermediate points
            local segment_idx = 1
            for i = 1, num_points - 2 do
                local target_dist = i * target_spacing

                -- advance segment_idx (distances are sorted, so we can start from last position)
                while segment_idx < num_segments and target_dist > distances[segment_idx + 1] do
                    segment_idx = segment_idx + 1
                end

                -- interpolate within the segment
                local seg_start_dist = distances[segment_idx]
                local seg_end_dist = distances[segment_idx + 1]
                local seg_length = seg_end_dist - seg_start_dist

                local local_t = (target_dist - seg_start_dist) / seg_length

                local point_idx = segment_idx * 2 - 1
                local x1, y1 = points[point_idx], points[point_idx + 1]
                local x2, y2 = points[point_idx + 2], points[point_idx + 3]

                local out_idx = i * 2 + 1
                uniform_points[out_idx], uniform_points[out_idx + 1] = math.mix2(x1, y1, x2, y2, local_t)
            end

            -- last point
            local last_idx = (num_points - 1) * 2 + 1
            uniform_points[last_idx] = points[n_points - 1]
            uniform_points[last_idx + 1] = points[n_points]

            points = uniform_points
            n_points = #points
        end
    end

    self._points = points
    self._n_points = n_points
    self._use_arclength = use_arclength
    self:_update()
    return self
end

--- @brief [internal] find closest point on a specific line segment
--- @param x number query point x coordinate
--- @param y number query point y coordinate
--- @param entry table segment entry from self._entries
--- @return number, number, number closest point x, y and global parameter t
--- @private
function Path:_closest_point_on_segment(x, y, entry)
    local x1, y1 = entry.from_x, entry.from_y
    local x2, y2 = entry.to_x, entry.to_y

    -- vector from start to end of segment
    local segment_dx = x2 - x1
    local segment_dy = y2 - y1
    local segment_length_sq = segment_dx * segment_dx + segment_dy * segment_dy

    if segment_length_sq < 1e-10 then
        -- degenerate segment
        local global_t = entry.fraction + entry.fraction_length * 0.5
        return x1, y1, global_t
    end

    local dot = (x - x1) * segment_dx + (y - y1) * segment_dy
    local local_t = math.clamp(dot / segment_length_sq, 0, 1)

    local closest_x = x1 + local_t * segment_dx
    local closest_y = y1 + local_t * segment_dy
    local global_t = entry.fraction + entry.fraction_length * local_t

    return closest_x, closest_y, global_t
end


return Path