math.eps = 1e-7

function math.round(x)
    return math.floor(x + 0.5)
end

function math.clamp(x, lower_bound, upper_bound)
    if x < lower_bound then
        x = lower_bound
    end

    if x > upper_bound then
        x = upper_bound
    end

    return x
end

function math.mix(lower, upper, ratio)
    return lower * (1 - ratio) + upper * ratio
end

function math.normalize(x, y)
    local magnitude = math.sqrt(x * x + y * y)
    if magnitude < math.eps then
        return 0, 0
    else
        return x / magnitude, y / magnitude
    end
end

function math.magnitude(x, y)
    return math.sqrt(x * x + y * y)
end

function math.dot(x1, y1, x2, y2)
    return x1 * x2 + y1 * y2
end

function math.cross(x1, y1, x2, y2)
    return x1 * y2 - y1 * x2
end

function math.distance(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return math.magnitude(dx, dy)
end

