module pukan.gltf.mesh;

public import pukan.gltf.loader: BufAccess;

class Mesh
{
    string name;
    /*private*/ BufAccess indicesAccessor;
    /*private*/ ushort indices_count;

    this(string name)
    {
        this.name = name;
    }
}
