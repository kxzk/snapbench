#version 330
in vec2 fragTexCoord;
in vec3 fragNormal;
in vec3 fragPosition;
in vec4 shadowPosition;
in float fragTint;
uniform sampler2D texture0;
uniform sampler2D shadowMap;
uniform vec4 colDiffuse;
uniform vec3 cameraPosition;
uniform float depthPass;
out vec4 finalColor;

float sunlight(vec3 normal) {
    vec3 p = shadowPosition.xyz / shadowPosition.w * 0.5 + 0.5;
    if (p.z > 1.0 || p.z < 0.0 || any(lessThan(p.xy, vec2(0))) || any(greaterThan(p.xy, vec2(1)))) return 1.0;
    float bias = max(0.0012 * (1.0 - dot(normal, normalize(vec3(-0.55, 1.0, -0.35)))), 0.0004);
    vec2 texel = 1.0 / vec2(textureSize(shadowMap, 0));
    float lit = 0.0;
    for (int x = -1; x <= 1; x++) for (int y = -1; y <= 1; y++)
        lit += p.z - bias <= texture(shadowMap, p.xy + vec2(x, y) * texel).r ? 1.0 : 0.0;
    return lit / 9.0;
}
void main() {
    vec4 texel = texture(texture0, fragTexCoord) * colDiffuse;
    if (texel.a < 0.4) discard;
    if (depthPass > 0.5) { finalColor = vec4(1.0); return; }
    vec3 normal = normalize(fragNormal);
    float diffuse = max(dot(normal, normalize(vec3(-0.55, 1.0, -0.35))), 0.0);
    vec3 ambient = mix(vec3(0.24, 0.24, 0.20), vec3(0.47, 0.54, 0.57), normal.y * 0.5 + 0.5);
    vec3 light = ambient + vec3(0.70, 0.61, 0.45) * diffuse * sunlight(normal);
    // A restrained palette preserves the authored textures and species markings.
    vec3 albedo = mix(vec3(dot(texel.rgb, vec3(0.2126, 0.7152, 0.0722))), texel.rgb, 0.82);
    vec3 color = albedo * fragTint * light;
    float distance = length(fragPosition - cameraPosition);
    float fog = 1.0 - exp(-pow(distance * 0.008, 2.0));
    finalColor = vec4(mix(color, vec3(0.70, 0.80, 0.81), fog), texel.a);
}
