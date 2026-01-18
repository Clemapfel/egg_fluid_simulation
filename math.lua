--- @brief smallest recognized difference between two floats
math.eps = 1e-8

--- @brief round to nearest integer
--- @param x number value to round
--- @return number
function math.round(x)
    return math.floor(x + 0.5)
end

--- @brief clamp value to bounds
--- @param x number value to clamp
--- @param lower_bound number minimum value
--- @param upper_bound number maximum value
--- @return number
function math.clamp(x, lower_bound, upper_bound)
    if x < lower_bound then
        x = lower_bound
    end

    if x > upper_bound then
        x = upper_bound
    end

    return x
end

--- @brief linearly interpolate between two values
--- @param lower number start value
--- @param upper number end value
--- @param ratio number blend factor, in [0,1]
--- @return number
function math.mix(lower, upper, ratio)
    return lower * (1 - ratio) + upper * ratio
end

--- @brief normalize a 2D vector, handles division by 0
--- @param x number x component
--- @param y number y component
--- @return number, number
function math.normalize(x, y)
    local magnitude = math.sqrt(x * x + y * y)
    if magnitude < math.eps then
        return 0, 0
    else
        return x / magnitude, y / magnitude
    end
end

--- @brief get length of 2d vector
--- @param x number x component
--- @param y number y component
--- @return number
function math.magnitude(x, y)
    return math.sqrt(x * x + y * y)
end

--- @brief calculate dot product of two 2d vectors
--- @param x1 number x component of first vector
--- @param y1 number y component of first vector
--- @param x2 number x component of second vector
--- @param y2 number y component of second vector
--- @return number
function math.dot(x1, y1, x2, y2)
    return x1 * x2 + y1 * y2
end

--- @brief calculate cross product of two 2d vectors
--- @param x1 number x component of first vector
--- @param y1 number y component of first vector
--- @param x2 number x component of second vector
--- @param y2 number y component of second vector
--- @return number
function math.cross(x1, y1, x2, y2)
    return x1 * y2 - y1 * x2
end

--- @brief get distance between two points
--- @param x1 number x component of first point
--- @param y1 number y component of first point
--- @param x2 number x component of second point
--- @param y2 number y component of second point
--- @return number
function math.distance(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return math.magnitude(dx, dy)
end

--- @brief get squared distance between two points
--- @param x1 number x component of first point
--- @param y1 number y component of first point
--- @param x2 number x component of second point
--- @param y2 number y component of second point
--- @return number
function math.squared_distance(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return math.dot(dx, dy, dx, dy)
end

