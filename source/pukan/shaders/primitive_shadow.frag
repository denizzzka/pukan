#version 460

void main()
{
    // A shader the pipeline still needs; the branch is never taken
    if(gl_FragCoord.x < 0.0)
        discard;
}
