#version 440

layout(location = 0) in float vWorldZ;
layout(location = 1) in float vEnd;
layout(location = 2) in float vSide;
layout(location = 3) in float vLineLength;
layout(location = 4) in float vRole;

layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float yawCos;
    float yawSin;
    float pitchCos;
    float pitchSin;
    float scale;
    float centerU;
    float centerV;
    float width;
    float height;
    float lineWidth;
    float dpr;
    float modelCenterX;
    float modelCenterY;
    float modelCenterZ;
    float minZ;
    float explosionProgress;
    float explosionFactor;
    float cutoff;
    float maxZ;
    float cutoffValid;
    float printedR;
    float printedG;
    float printedB;
    float printedA;
    float remainingR;
    float remainingG;
    float remainingB;
    float remainingA;
    float roleColoring;
    float role0R; float role0G; float role0B;
    float role1R; float role1G; float role1B;
    float role2R; float role2G; float role2B;
    float role3R; float role3G; float role3B;
    float role4R; float role4G; float role4B;
} ubuf;

void main()
{
    float dist = abs(vSide);
    if (vEnd < 0.0)
        dist = length(vec2(vEnd, vSide));
    else if (vEnd > vLineLength)
        dist = length(vec2(vEnd - vLineLength, vSide));

    float dpr = max(ubuf.dpr, 1e-6);
    const float antialiasPx = 0.75;
    float halfWidth = ubuf.lineWidth * dpr * 0.5;
    float cover = 1.0 - smoothstep(halfWidth, halfWidth + antialiasPx, dist);
    if (cover <= 0.0)
        discard;

    // A missing cutoff leaves the route unprinted; completion prints all of it.
    bool printed = false;
    if (ubuf.cutoffValid > 0.5) {
        if (ubuf.cutoff >= ubuf.maxZ)
            printed = true;
        else
            printed = vWorldZ <= ubuf.cutoff;
    }

    vec4 color = printed
        ? vec4(ubuf.printedR, ubuf.printedG, ubuf.printedB, ubuf.printedA)
        : vec4(ubuf.remainingR, ubuf.remainingG, ubuf.remainingB, ubuf.remainingA);

    // With roles on, hue carries the feature type and the printed/remaining
    // split stays legible as brightness, so progress is not traded for detail.
    if (ubuf.roleColoring > 0.5) {
        int role = int(clamp(vRole + 0.5, 0.0, 4.0));
        vec3 hue = vec3(ubuf.role0R, ubuf.role0G, ubuf.role0B);
        if (role == 1) hue = vec3(ubuf.role1R, ubuf.role1G, ubuf.role1B);
        else if (role == 2) hue = vec3(ubuf.role2R, ubuf.role2G, ubuf.role2B);
        else if (role == 3) hue = vec3(ubuf.role3R, ubuf.role3G, ubuf.role3B);
        else if (role == 4) hue = vec3(ubuf.role4R, ubuf.role4G, ubuf.role4B);
        color = printed ? vec4(hue, ubuf.printedA)
                        : vec4(hue * 0.45, ubuf.remainingA);
    }
    float alpha = color.a * cover * ubuf.qt_Opacity;
    fragColor = vec4(color.rgb * alpha, alpha);
}
