#ifdef PIXEL

uniform float outline_thickness = 2.0;
uniform float threshold = 0.5;

vec4 effect(vec4 color, sampler2D tex, vec2 texture_coordinates, vec2 frag_position) {
    vec2 screen_size = love_ScreenSize.xy;
    vec2 pixel_size = 1.0 / screen_size;

    vec4 center = texture(tex, texture_coordinates);
    if (center.a == 0) discard;

    float max_alpha = 0.0;
    float radius = outline_thickness;

    int steps = int(ceil(radius)) + 1;
    float step_size = radius / float(steps);

    // approximate circular topological dilation kernel with normalized 8-directional sampling
    const float diagonal = sqrt(2.0) / 2.0;
    const float cardinal = 1.0;

    const vec2 directions[8] = vec2[8](
        vec2(cardinal, 0.0),
        vec2(-cardinal, 0.0),
        vec2(0.0, +cardinal),
        vec2(0.0, -cardinal),
        vec2(+diagonal, +diagonal),
        vec2(-diagonal, +diagonal),
        vec2(+diagonal, -diagonal),
        vec2(-diagonal, -diagonal)
    );

    for (int direction = 0; direction < 8; direction++) {
        for (int step = 1; step <= steps; step++) {
            vec2 offset = directions[direction] * (float(step) * step_size) * pixel_size;
            vec4 sample_color = Texel(tex, texture_coordinates + offset);
            max_alpha = max(max_alpha, sample_color.a);
        }
    }

    max_alpha = min(max_alpha, 1);

    float outline_threshold = 0.5 * threshold; // manually tuned to match outline_width in px
    float outline_smoothness = 0.035;
    float outline_alpha = smoothstep(
        outline_threshold, outline_threshold + outline_smoothness,
        max_alpha
    );

    return color * vec4(outline_alpha);
}

#endif