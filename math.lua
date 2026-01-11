function math.mix(lower, upper, ratio)
    return lower * (1 - ratio) + upper * ratio
end

function math.mix2(x1, y1, x2, y2, ratio)
    return x1 * (1 - ratio) + x2 * ratio,
    y1 * (1 - ratio) + y2 * ratio
end