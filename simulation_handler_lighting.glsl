#ifdef PIXEL

uniform bool use_highlight = true;
uniform float highlight_strength = 1;

uniform bool use_shadow = true;
uniform float shadow_strength = 1;

uniform bool use_particle_color = false;

uniform float threshold = 0.5;
uniform float smoothness = 0.05;

vec4 effect(vec4 color, sampler2D tex, vec2 texture_coordinates, vec2 screen_coords)
{
    vec2 pixel_size = 1.0 / love_ScreenSize.xy;

    // threshold alpha density
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

    // compute gradient using sobel kernel
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

    if (use_highlight)
    {
        vec3 view_dir = vec3(0.0, 0.0, 1.0);
        vec3 half_dir = normalize(specular_light_direction + view_dir);
        specular += highlight_strength * pow(max(dot(surface_normal, half_dir), 0.0), specular_focus);
    }

    // shadows
    vec3 shadow_light_direction = normalize(vec3(-0.5, 0.75, 0));
    float shadow = 0;

    if (use_shadow) {
        shadow = dot(surface_normal, shadow_light_direction);
        shadow = smoothstep(0, 1, clamp(shadow * shadow_strength, 0, 1));
    }

    return vec4(center.rgb - shadow + specular, center.a);
}

#endif