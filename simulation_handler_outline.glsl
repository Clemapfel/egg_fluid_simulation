#ifdef PIXEL

vec4 effect(vec4 color, Image image, vec2 texture_coordinates, vec2 frag_position) {
    vec2 pixel_size = vec2(1 / 1000.0);

    float tl = texture(image, texture_coordinates + vec2(-1, -1) * pixel_size).a;
    float tm = texture(image, texture_coordinates + vec2( 0, -1) * pixel_size).a;
    float tr = texture(image, texture_coordinates + vec2( 1, -1) * pixel_size).a;
    float ml = texture(image, texture_coordinates + vec2(-1,  0) * pixel_size).a;
    float mr = texture(image, texture_coordinates + vec2( 1,  0) * pixel_size).a;
    float bl = texture(image, texture_coordinates + vec2(-1,  1) * pixel_size).a;
    float bm = texture(image, texture_coordinates + vec2( 0,  1) * pixel_size).a;
    float br = texture(image, texture_coordinates + vec2( 1,  1) * pixel_size).a;

    float gradient_x = -tl + tr - 2.0 * ml + 2.0 * mr - bl + br;
    float gradient_y = -tl - 2.0 * tm - tr + bl + 2.0 * bm + br;

    float magnitude = length(vec2(gradient_x, gradient_y));

    return vec4(magnitude) * color;
}

#endif