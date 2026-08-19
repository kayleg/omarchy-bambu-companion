#version 440

layout(location = 0) in float vWorldZ;
layout(location = 1) in float vEnd;
layout(location = 2) in float vSide;
layout(location = 3) in float vLineLength;

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
    float alpha = color.a * cover * ubuf.qt_Opacity;
    fragColor = vec4(color.rgb * alpha, alpha);
}
