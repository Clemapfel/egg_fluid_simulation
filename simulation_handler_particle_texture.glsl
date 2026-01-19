#ifdef PIXEL

const float PI = 3.1415926535897932384626433832795;

/// @brief gaussian, normalized to 0, 1
float gaussian(float x, float ramp)
{
    return exp(((-4 * PI) / 3) * (ramp * x) * (ramp * x));
}

vec4 effect(vec4 color, sampler2D tex, vec2 texture_coords, vec2 screen_coords) {
    // get normalized distance from center, using texture coordinates
    float dist = 2 * (0.5 - distance(texture_coords, vec2(0.5)));

    // weight distance with gaussian for gaussian falloff
    return vec4(vec3(1), gaussian(1 - dist, 1));
}

#endif
