#version 330

in vec2 fragTexCoord;
in vec3 fragNormal;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform float time;

out vec4 finalColor;

void main() {
    vec3 lightDir = normalize(vec3(0.5, 1.0, 0.3));
    float lighting = 0.4 + max(dot(fragNormal, lightDir), 0.0) * 0.6;

    vec4 texel = texture(texture0, fragTexCoord);
    vec3 lit = texel.rgb * colDiffuse.rgb * lighting;

    float glow = (time > 0.0) ? 0.5 + 0.3 * sin(time * 3.0) : 0.0; // pulses [0.2, 0.8], time <= 0 disables
    finalColor = vec4(lit + texel.rgb * glow, texel.a * colDiffuse.a);
}
