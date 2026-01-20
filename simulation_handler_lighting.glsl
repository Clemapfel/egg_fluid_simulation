#ifdef PIXEL

uniform bool use_highlight = true;
uniform bool use_shadow = true;
uniform bool use_particle_color = false;

uniform float threshold = 0.5;
uniform float smoothness = 0.05;

vec4 effect(vec4 color, sampler2D tex, vec2 texture_coordinates, vec2 screen_coords)
{
    vec2 pixel_size = 1.0 / love_ScreenSize.xy;

    vec4 data = texture(tex, texture_coordinates);
    vec4 center;
    {
        float value = smoothstep(
            threshold - smoothness,
            threshold + smoothness,
            data.a
        );

        if (use_particle_color)
            center = vec4(data.rgb * value, value) * color;
        else
            center = vec4(value) * color;
    }

    float opacity = smoothstep(threshold - smoothness, threshold + smoothness, center.a);

    // Sobel kernel (using alpha as height)
    float tl = texture(tex, texture_coordinates + vec2(-1.0, -1.0) * pixel_size).a;
    float tm = texture(tex, texture_coordinates + vec2( 0.0, -1.0) * pixel_size).a;
    float tr = texture(tex, texture_coordinates + vec2( 1.0, -1.0) * pixel_size).a;
    float ml = texture(tex, texture_coordinates + vec2(-1.0,  0.0) * pixel_size).a;
    float mr = texture(tex, texture_coordinates + vec2( 1.0,  0.0) * pixel_size).a;
    float bl = texture(tex, texture_coordinates + vec2(-1.0,  1.0) * pixel_size).a;
    float bm = texture(tex, texture_coordinates + vec2( 0.0,  1.0) * pixel_size).a;
    float br = texture(tex, texture_coordinates + vec2( 1.0,  1.0) * pixel_size).a;

    float gradient_x = -tl + tr - 2.0 * ml + 2.0 * mr - bl + br;
    float gradient_y = -tl - 2.0 * tm - tr + bl + 2.0 * bm + br;

    vec3 surface_normal = normalize(vec3(-gradient_x, -gradient_y, 1.0));


    // specular highlight
    vec3 specular_light_direction = normalize(vec3(1.0, -1.0, 1.0));
    float specular = 0.0;
    const float specular_focus = 48; // how "tightly" the highlight is focused
    const float specular_boost = 1;  // increase specular intensity

    if (use_highlight)
    {
        vec3 view_dir = vec3(0.0, 0.0, 1.0);
        vec3 half_dir = normalize(specular_light_direction + view_dir);
        specular += pow(max(dot(surface_normal, half_dir), 0.0), specular_focus);
    }

    vec4 specular_color = mix(
        vec4(0, 0, 0, 0),
        vec4(1, 1, 1, 1),
        specular
    ) * specular_boost;

    specular_color.a *= data.a;

    // shadows
    vec3 shadow_light_direction = normalize(vec3(-0.5, 0.75, 0));
    float shadow = 1;
    const float shadow_steps = 3;

    if (use_shadow) {
        shadow -= dot(surface_normal, shadow_light_direction);
        shadow = clamp(shadow, 0, 1);
        shadow = smoothstep(0, 0.9, shadow);
        shadow = floor(shadow * shadow_steps) / (shadow_steps - 1.0);
    }

    return shadow * center + specular_color;
}

#endif
