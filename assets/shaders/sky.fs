#version 330
uniform vec2 resolution;
uniform vec3 forward;
uniform vec3 right;
uniform vec3 up;
out vec4 finalColor;
void main() {
    vec2 uv = gl_FragCoord.xy / resolution * 2.0 - 1.0;
    vec3 ray = normalize(forward + right * uv.x * (resolution.x / resolution.y) * 0.57735 + up * uv.y * 0.57735);
    float elevation = smoothstep(-0.15, 0.8, ray.y);
    vec3 sky = mix(vec3(0.70, 0.80, 0.81), vec3(0.34, 0.61, 0.78), elevation);
    float sun = max(dot(ray, normalize(vec3(-0.55, 1.0, -0.35))), 0.0);
    sky += vec3(0.34, 0.25, 0.11) * pow(sun, 28.0);
    sky = mix(sky, vec3(1.0, 0.94, 0.72), smoothstep(0.9993, 0.9996, sun));
    finalColor = vec4(sky, 1.0);
}
