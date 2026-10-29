module pukan.godot_scene.text;

import dlib.math: Quaternionf, Vector2f, Vector2i, Vector3f, Vector3i, Vector4f, Vector4i;
import pukan.exceptions: PukanException;
import pukan.godot_scene.value;
import std.base64: Base64;
import std.conv: to;
import std.string: startsWith;
import std.utf: encode;

/// One tag header from a text scene or resource
struct GodotTextTag
{
    string name;
    GodotVariant[string] fields;
}

struct GodotTextNode
{
    string name;
    string type;
    string parent;
    GodotVariant instance;
    GodotVariant[string] fields;
    GodotVariant[string] properties;
}

struct GodotTextResource
{
    string type;
    string id;
    GodotVariant[string] properties;
}

struct GodotTextExternal
{
    string type;
    string path;
    string id;
    string uid;
}

struct GodotTextDocument
{
    bool isScene;
    bool binary;
    uint binaryVersion;
    int format = 4;
    string resourceType;
    string scriptClass;
    string uid;
    GodotTextExternal[] externals;
    GodotTextResource[] subResources;
    GodotTextNode[] nodes;
    GodotVariant[string] resourceProperties;
    size_t unknownTags;
}

GodotTextDocument parseGodotText(string text)
{
    GodotTextParser parser;
    parser.src = text;
    return parser.parseDocument();
}

GodotTextDocument parseGodotTextFile(string path)
{
    import std.file: read;
    return parseGodotText(cast(string) read(path));
}

private struct GodotTextParser
{
    const(char)[] src;
    size_t pos;
    size_t line = 1;

    void fail(string message) const
    {
        throw new PukanException(message ~ " at line " ~ line.to!string);
    }

    bool eof() const => pos >= src.length;
    char peek() const => pos < src.length ? src[pos] : 0;

    char take()
    {
        const c = src[pos++];
        if(c == '\n')
            ++line;
        return c;
    }

    void skipSpace()
    {
        while(!eof)
        {
            const c = src[pos];

            if(c == ' ' || c == '\t' || c == '\r')
            {
                ++pos;
                continue;
            }

            if(c == '\n')
            {
                ++pos;
                ++line;
                continue;
            }

            if(c == ';')
            {
                while(!eof && src[pos] != '\n')
                    ++pos;
                continue;
            }

            break;
        }
    }

    bool accept(char c)
    {
        skipSpace();
        if(eof || peek != c)
            return false;

        take();
        return true;
    }

    void expect(char c)
    {
        if(!accept(c))
            fail("expected '" ~ c ~ "'");
    }

    static bool isIdentifierChar(char c)
    {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '/' || c == '.' ||
            c == '-' || c == ':' || c == '@' || c == '%';
    }

    string parseIdentifier()
    {
        skipSpace();

        const start = pos;
        while(!eof && isIdentifierChar(peek))
            ++pos;

        if(start == pos)
            fail("expected identifier");

        return src[start .. pos].idup;
    }

    string parseString()
    {
        expect('"');

        char[] result;
        uint pendingSurrogate;

        while(true)
        {
            if(eof)
                fail("unterminated string");

            const c = take();

            if(c == '"')
                break;

            if(c != '\\')
            {
                result ~= c;
                continue;
            }

            if(eof)
                fail("unterminated escape");

            const e = take();

            switch(e)
            {
                case 'b': result ~= '\b'; break;
                case 't': result ~= '\t'; break;
                case 'n': result ~= '\n'; break;
                case 'f': result ~= '\f'; break;
                case 'r': result ~= '\r'; break;
                case 'u':
                case 'U':
                    uint code = parseHex(e == 'U' ? 6 : 4);

                    if(code >= 0xD800 && code <= 0xDBFF)
                    {
                        if(pendingSurrogate != 0)
                            fail("unpaired UTF-16 surrogate");
                        pendingSurrogate = code;
                        continue;
                    }

                    if(code >= 0xDC00 && code <= 0xDFFF)
                    {
                        if(pendingSurrogate == 0)
                            fail("unpaired UTF-16 surrogate");
                        code = 0x10000 + ((pendingSurrogate - 0xD800) << 10) + (code - 0xDC00);
                        pendingSurrogate = 0;
                    }
                    else if(pendingSurrogate != 0)
                        fail("unpaired UTF-16 surrogate");

                    char[4] buf;
                    const length = encode(buf, cast(dchar) code);
                    result ~= buf[0 .. length];
                    break;

                default:
                    result ~= e;
                    break;
            }
        }

        if(pendingSurrogate != 0)
            fail("unpaired UTF-16 surrogate");

        return result.idup;
    }

    uint parseHex(size_t digits)
    {
        uint value;

        foreach(_; 0 .. digits)
        {
            if(eof)
                fail("unterminated hex escape");

            const c = take();
            if(c >= '0' && c <= '9')
                value = (value << 4) | (c - '0');
            else if(c >= 'a' && c <= 'f')
                value = (value << 4) | (c - 'a' + 10);
            else if(c >= 'A' && c <= 'F')
                value = (value << 4) | (c - 'A' + 10);
            else
                fail("malformed hex escape");
        }

        return value;
    }

    private static bool isHexDigit(char c)
    {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }

    private static ubyte hexDigit(char c)
    {
        if(c >= '0' && c <= '9') return cast(ubyte) (c - '0');
        if(c >= 'a' && c <= 'f') return cast(ubyte) (c - 'a' + 10);
        return cast(ubyte) (c - 'A' + 10);
    }

    GodotColor parseHexColor()
    {
        take(); // '#'

        char[] digits;
        while(!eof && isHexDigit(peek))
            digits ~= take();

        if(digits.length != 3 && digits.length != 4 && digits.length != 6 && digits.length != 8)
            fail("unsupported color literal");

        float component(size_t index) const
        {
            if(digits.length == 3 || digits.length == 4)
            {
                if(index >= digits.length)
                    return 1.0f;
                return (hexDigit(digits[index]) * 17) / 255.0f;
            }

            if(index * 2 >= digits.length)
                return 1.0f;

            return ((hexDigit(digits[index * 2]) << 4) | hexDigit(digits[index * 2 + 1])) / 255.0f;
        }

        return GodotColor(component(0), component(1), component(2), component(3));
    }

    GodotVariant parseNumber()
    {
        const start = pos;

        if(peek == '-' || peek == '+')
            take();

        if(src[pos .. $].startsWith("inf"))
        {
            pos += 3;
            return GodotVariant(start < pos && src[start] == '-' ? -double.infinity : double.infinity);
        }

        if(src[pos .. $].startsWith("nan"))
        {
            pos += 3;
            return GodotVariant(double.nan);
        }

        if(peek == '0' && pos + 1 < src.length && (src[pos + 1] == 'x' || src[pos + 1] == 'X'))
        {
            pos += 2;
            const digitsStart = pos;

            while(!eof && isHexDigit(peek))
                ++pos;

            if(digitsStart == pos)
                fail("expected hex digits");

            long value = to!long(src[digitsStart .. pos], 16);
            if(src[start] == '-')
                value = -value;

            return GodotVariant(value);
        }

        bool isFloat;

        while(!eof && peek >= '0' && peek <= '9')
            ++pos;

        if(!eof && peek == '.')
        {
            isFloat = true;
            ++pos;
            while(!eof && peek >= '0' && peek <= '9')
                ++pos;
        }

        if(!eof && (peek == 'e' || peek == 'E'))
        {
            isFloat = true;
            ++pos;

            if(!eof && (peek == '-' || peek == '+'))
                ++pos;

            while(!eof && peek >= '0' && peek <= '9')
                ++pos;
        }

        if(start == pos)
            fail("expected number");

        const text = src[start .. pos].idup;
        return isFloat ? GodotVariant(text.to!double) : GodotVariant(text.to!long);
    }

    GodotVariant parseValue()
    {
        skipSpace();

        if(eof)
            fail("unexpected end of file");

        const c = peek;

        if(c == '"')
            return GodotVariant(parseString());

        if(c == '&')
        {
            take();
            return GodotVariant(GodotStringName(parseString()));
        }

        if(c == '^')
        {
            take();
            return GodotVariant(GodotNodePath(parseString()));
        }

        if(c == '#')
            return GodotVariant(parseHexColor());

        if(c == '[')
            return GodotVariant(parseArray());

        if(c == '{')
            return GodotVariant(parseDictionary());

        if(c == '-' || c == '+' || (c >= '0' && c <= '9') || c == '.')
            return parseNumber();

        const identifier = parseIdentifier();

        switch(identifier)
        {
            case "true": return GodotVariant(true);
            case "false": return GodotVariant(false);
            case "null": return GodotVariant(GodotNil());
            case "inf": return GodotVariant(double.infinity);
            case "inf_neg": return GodotVariant(-double.infinity);
            case "nan": return GodotVariant(double.nan);
            default: break;
        }

        skipSpace();

        if(peek == '[')
            return parseTyped(identifier);

        if(peek == '(')
        {
            if(identifier == "Object" || identifier == "Callable" ||
                identifier == "Signal" || identifier == "RID")
            {
                skipParenthesized();
                return GodotVariant(GodotOpaque(identifier));
            }

            return makeConstructor(identifier, parseArguments());
        }

        return GodotVariant(GodotOpaque(identifier));
    }

    GodotVariant parseTyped(string typeName)
    {
        expect('[');
        int depth = 1;

        while(depth > 0)
        {
            if(eof)
                fail("unterminated typed array");

            const c = take();
            if(c == '[')
                ++depth;
            else if(c == ']')
                --depth;
        }

        expect('(');

        skipSpace();
        if(accept(')'))
            return typeName.startsWith("Dictionary")
                ? GodotVariant(new GodotDictionary)
                : GodotVariant(new GodotArray);

        const value = parseValue();
        expect(')');
        return value;
    }

    GodotVariant[] parseArguments()
    {
        expect('(');

        GodotVariant[] arguments;

        skipSpace();
        if(accept(')'))
            return arguments;

        while(true)
        {
            arguments ~= parseValue();
            skipSpace();

            if(accept(','))
            {
                if(accept(')'))
                    break;
                continue;
            }

            expect(')');
            break;
        }

        return arguments;
    }

    GodotArray parseArray()
    {
        expect('[');

        GodotVariant[] items;

        skipSpace();
        if(accept(']'))
            return new GodotArray(items);

        while(true)
        {
            items ~= parseValue();
            skipSpace();

            if(accept(','))
            {
                if(accept(']'))
                    break;
                continue;
            }

            expect(']');
            break;
        }

        return new GodotArray(items);
    }

    GodotDictionary parseDictionary()
    {
        expect('{');

        auto result = new GodotDictionary;

        skipSpace();
        if(accept('}'))
            return result;

        while(true)
        {
            const key = parseValue();
            expect(':');
            result.keys ~= key;
            result.values ~= parseValue();

            skipSpace();
            if(accept(','))
            {
                if(accept('}'))
                    break;
                continue;
            }

            expect('}');
            break;
        }

        return result;
    }

    void skipParenthesized()
    {
        expect('(');

        int depth = 1;
        while(depth > 0)
        {
            if(eof)
                fail("unterminated constructor");

            const c = take();

            if(c == '"')
            {
                while(!eof)
                {
                    const s = take();
                    if(s == '\\')
                    {
                        if(!eof)
                            take();
                        continue;
                    }
                    if(s == '"')
                        break;
                }
            }
            else if(c == '(')
                ++depth;
            else if(c == ')')
                --depth;
        }
    }

    private static double[] numbers(in GodotVariant[] arguments)
    {
        double[] result;

        foreach(argument; arguments)
        {
            if(argument.type is typeid(long))
                result ~= cast(double) argument.get!long;
            else if(argument.type is typeid(double))
                result ~= argument.get!double;
            else if(argument.type is typeid(Vector2f))
            {
                const v = argument.get!Vector2f;
                result ~= [v.x, v.y];
            }
            else if(argument.type is typeid(Vector2i))
            {
                const v = argument.get!Vector2i;
                result ~= [cast(double) v.x, cast(double) v.y];
            }
            else if(argument.type is typeid(Vector3f))
            {
                const v = argument.get!Vector3f;
                result ~= [v.x, v.y, v.z];
            }
            else if(argument.type is typeid(Vector3i))
            {
                const v = argument.get!Vector3i;
                result ~= [cast(double) v.x, cast(double) v.y, cast(double) v.z];
            }
            else if(argument.type is typeid(Vector4f))
            {
                const v = argument.get!Vector4f;
                result ~= [v.x, v.y, v.z, v.w];
            }
            else if(argument.type is typeid(Vector4i))
            {
                const v = argument.get!Vector4i;
                result ~= [cast(double) v.x, cast(double) v.y, cast(double) v.z, cast(double) v.w];
            }
            else if(argument.type is typeid(Quaternionf))
            {
                const v = argument.get!Quaternionf;
                result ~= [v.x, v.y, v.z, v.w];
            }
            else if(argument.type is typeid(GodotColor))
            {
                const c = argument.get!GodotColor;
                result ~= [c.r, c.g, c.b, c.a];
            }
            else
                throw new PukanException("constructor argument is not a number: " ~ variantTypeName(argument));
        }

        return result;
    }

    GodotVariant makeConstructor(string name, in GodotVariant[] arguments)
    {
        switch(name)
        {
            case "SubResource":
                return GodotVariant(GodotObjectRef(GodotRefKind.subResource, asString(arguments[0])));
            case "ExtResource":
                return GodotVariant(GodotObjectRef(GodotRefKind.extResource, asString(arguments[0])));
            case "Resource":
                return GodotVariant(GodotObjectRef(GodotRefKind.resource, asString(arguments[0])));
            case "StringName":
                return GodotVariant(GodotStringName(asString(arguments[0])));
            case "NodePath":
                return GodotVariant(GodotNodePath(asString(arguments[0])));
            case "Vector2": return vector2(numbers(arguments));
            case "Vector2i": return vector2i(numbers(arguments));
            case "Vector3": return vector3(numbers(arguments));
            case "Vector3i": return vector3i(numbers(arguments));
            case "Vector4": return vector4(numbers(arguments));
            case "Vector4i": return vector4i(numbers(arguments));
            case "Rect2": return rect2(arguments);
            case "Rect2i": return rect2i(arguments);
            case "Plane": return plane(arguments);
            case "Quaternion": return quaternion(numbers(arguments));
            case "Color": return color(arguments);
            case "Basis": return basis(arguments);
            case "Transform2D": return transform2d(arguments);
            case "Transform3D": return transform3d(arguments);
            case "AABB": return aabb(arguments);
            case "Projection": return projection(numbers(arguments));
            case "PackedByteArray": return packedByteArray(arguments);
            case "PackedInt32Array": return packedIntArray(arguments);
            case "PackedInt64Array": return packedLongArray(arguments);
            case "PackedFloat32Array": return packedFloatArray(arguments);
            case "PackedFloat64Array": return packedDoubleArray(arguments);
            case "PackedStringArray": return packedStringArray(arguments);
            case "PackedVector2Array": return packedVector2Array(arguments);
            case "PackedVector3Array": return packedVector3Array(arguments);
            case "PackedVector4Array": return packedVector4Array(arguments);
            case "PackedColorArray": return packedColorArray(arguments);
            case "Array": return arrayConstructor(arguments);
            case "Dictionary": return dictionaryConstructor(arguments);
            default:
                return GodotVariant(GodotOpaque(name));
        }
    }

    private void requireCount(in double[] values, size_t count, string name)
    {
        if(values.length != count)
            throw new PukanException(name ~ " expects " ~ count.to!string ~ " numbers");
    }

    private GodotVariant vector2(in double[] v)
    {
        if(v.length == 0) return GodotVariant(Vector2f(0, 0));
        requireCount(v, 2, "Vector2");
        return GodotVariant(Vector2f(cast(float) v[0], cast(float) v[1]));
    }

    private GodotVariant vector2i(in double[] v)
    {
        if(v.length == 0) return GodotVariant(Vector2i(0, 0));
        requireCount(v, 2, "Vector2i");
        return GodotVariant(Vector2i(cast(int) v[0], cast(int) v[1]));
    }

    private GodotVariant vector3(in double[] v)
    {
        if(v.length == 0) return GodotVariant(Vector3f(0, 0, 0));
        requireCount(v, 3, "Vector3");
        return GodotVariant(Vector3f(cast(float) v[0], cast(float) v[1], cast(float) v[2]));
    }

    private GodotVariant vector3i(in double[] v)
    {
        if(v.length == 0) return GodotVariant(Vector3i(0, 0, 0));
        requireCount(v, 3, "Vector3i");
        return GodotVariant(Vector3i(cast(int) v[0], cast(int) v[1], cast(int) v[2]));
    }

    private GodotVariant vector4(in double[] v)
    {
        if(v.length == 0) return GodotVariant(Vector4f(0, 0, 0, 0));
        requireCount(v, 4, "Vector4");
        return GodotVariant(Vector4f(cast(float) v[0], cast(float) v[1], cast(float) v[2], cast(float) v[3]));
    }

    private GodotVariant vector4i(in double[] v)
    {
        if(v.length == 0) return GodotVariant(Vector4i(0, 0, 0, 0));
        requireCount(v, 4, "Vector4i");
        return GodotVariant(Vector4i(cast(int) v[0], cast(int) v[1], cast(int) v[2], cast(int) v[3]));
    }

    private GodotVariant quaternion(in double[] v)
    {
        if(v.length == 0) return GodotVariant(Quaternionf(0, 0, 0, 1));
        requireCount(v, 4, "Quaternion");
        return GodotVariant(Quaternionf(cast(float) v[0], cast(float) v[1], cast(float) v[2], cast(float) v[3]));
    }

    private GodotVariant rect2(in GodotVariant[] arguments)
    {
        if(arguments.length == 2)
            return GodotVariant(GodotRect2(as!(Vector2f)(arguments[0]), as!(Vector2f)(arguments[1])));

        const v = numbers(arguments);
        requireCount(v, 4, "Rect2");
        return GodotVariant(GodotRect2(Vector2f(cast(float) v[0], cast(float) v[1]), Vector2f(cast(float) v[2], cast(float) v[3])));
    }

    private GodotVariant rect2i(in GodotVariant[] arguments)
    {
        if(arguments.length == 2)
            return GodotVariant(GodotRect2i(as!(Vector2i)(arguments[0]), as!(Vector2i)(arguments[1])));

        const v = numbers(arguments);
        requireCount(v, 4, "Rect2i");
        return GodotVariant(GodotRect2i(Vector2i(cast(int) v[0], cast(int) v[1]), Vector2i(cast(int) v[2], cast(int) v[3])));
    }

    private GodotVariant plane(in GodotVariant[] arguments)
    {
        if(arguments.length == 2)
            return GodotVariant(GodotPlane(as!(Vector3f)(arguments[0]), cast(float) asDouble(arguments[1])));

        const v = numbers(arguments);
        requireCount(v, 4, "Plane");
        return GodotVariant(GodotPlane(Vector3f(cast(float) v[0], cast(float) v[1], cast(float) v[2]), cast(float) v[3]));
    }

    private GodotVariant color(in GodotVariant[] arguments)
    {
        if(arguments.length == 1 && arguments[0].type is typeid(string))
        {
            const text = arguments[0].get!string;
            if(text.length == 0 || text[0] != '#')
                throw new PukanException("unsupported color name: " ~ text);
            return GodotVariant(hexColor(text));
        }

        const v = numbers(arguments);
        if(v.length == 3)
            return GodotVariant(GodotColor(cast(float) v[0], cast(float) v[1], cast(float) v[2], 1));
        requireCount(v, 4, "Color");
        return GodotVariant(GodotColor(cast(float) v[0], cast(float) v[1], cast(float) v[2], cast(float) v[3]));
    }

    private static GodotColor hexColor(string text)
    {
        char[] digits;
        foreach(c; text[1 .. $])
        {
            if(!isHexDigit(c))
                throw new PukanException("unsupported color literal: " ~ text);
            digits ~= c;
        }

        if(digits.length != 3 && digits.length != 4 && digits.length != 6 && digits.length != 8)
            throw new PukanException("unsupported color literal: " ~ text);

        float component(size_t index)
        {
            if(digits.length == 3 || digits.length == 4)
            {
                if(index >= digits.length)
                    return 1.0f;
                return (hexDigit(digits[index]) * 17) / 255.0f;
            }

            if(index * 2 >= digits.length)
                return 1.0f;

            return ((hexDigit(digits[index * 2]) << 4) | hexDigit(digits[index * 2 + 1])) / 255.0f;
        }

        return GodotColor(component(0), component(1), component(2), component(3));
    }

    private GodotVariant basis(in GodotVariant[] arguments)
    {
        if(arguments.length == 3)
        {
            const x = as!(Vector3f)(arguments[0]);
            const y = as!(Vector3f)(arguments[1]);
            const z = as!(Vector3f)(arguments[2]);

            GodotBasis result;
            result.rows[0] = Vector3f(x.x, y.x, z.x);
            result.rows[1] = Vector3f(x.y, y.y, z.y);
            result.rows[2] = Vector3f(x.z, y.z, z.z);
            return GodotVariant(result);
        }

        const v = numbers(arguments);
        requireCount(v, 9, "Basis");

        GodotBasis result;
        result.rows[0] = Vector3f(cast(float) v[0], cast(float) v[1], cast(float) v[2]);
        result.rows[1] = Vector3f(cast(float) v[3], cast(float) v[4], cast(float) v[5]);
        result.rows[2] = Vector3f(cast(float) v[6], cast(float) v[7], cast(float) v[8]);
        return GodotVariant(result);
    }

    private GodotVariant transform2d(in GodotVariant[] arguments)
    {
        if(arguments.length == 3)
            return GodotVariant(GodotTransform2D([
                as!(Vector2f)(arguments[0]),
                as!(Vector2f)(arguments[1]),
                as!(Vector2f)(arguments[2]),
            ]));

        const v = numbers(arguments);
        requireCount(v, 6, "Transform2D");
        return GodotVariant(GodotTransform2D([
            Vector2f(cast(float) v[0], cast(float) v[1]),
            Vector2f(cast(float) v[2], cast(float) v[3]),
            Vector2f(cast(float) v[4], cast(float) v[5]),
        ]));
    }

    private GodotVariant transform3d(in GodotVariant[] arguments)
    {
        if(arguments.length == 2)
            return GodotVariant(GodotTransform3D(
                as!(GodotBasis)(arguments[0]).rows,
                as!(Vector3f)(arguments[1]),
            ));

        const v = numbers(arguments);
        requireCount(v, 12, "Transform3D");

        GodotTransform3D result;
        result.rows[0] = Vector3f(cast(float) v[0], cast(float) v[1], cast(float) v[2]);
        result.rows[1] = Vector3f(cast(float) v[3], cast(float) v[4], cast(float) v[5]);
        result.rows[2] = Vector3f(cast(float) v[6], cast(float) v[7], cast(float) v[8]);
        result.origin = Vector3f(cast(float) v[9], cast(float) v[10], cast(float) v[11]);
        return GodotVariant(result);
    }

    private GodotVariant aabb(in GodotVariant[] arguments)
    {
        if(arguments.length == 2)
            return GodotVariant(GodotAabb(as!(Vector3f)(arguments[0]), as!(Vector3f)(arguments[1])));

        const v = numbers(arguments);
        requireCount(v, 6, "AABB");
        return GodotVariant(GodotAabb(
            Vector3f(cast(float) v[0], cast(float) v[1], cast(float) v[2]),
            Vector3f(cast(float) v[3], cast(float) v[4], cast(float) v[5]),
        ));
    }

    private GodotVariant projection(in double[] v)
    {
        requireCount(v, 16, "Projection");

        GodotProjection result;
        foreach(i; 0 .. 16)
            result.values[i] = cast(float) v[i];
        return GodotVariant(result);
    }

    private GodotVariant packedByteArray(in GodotVariant[] arguments)
    {
        if(arguments.length == 1 && arguments[0].type is typeid(string))
            return GodotVariant(Base64.decode(arguments[0].get!string));

        const v = numbers(arguments);
        ubyte[] result;
        result.length = v.length;
        foreach(i; 0 .. v.length)
            result[i] = cast(ubyte) v[i];
        return GodotVariant(result);
    }

    private GodotVariant packedIntArray(in GodotVariant[] arguments)
    {
        const v = numbers(arguments);
        int[] result;
        result.length = v.length;
        foreach(i; 0 .. v.length)
            result[i] = cast(int) v[i];
        return GodotVariant(result);
    }

    private GodotVariant packedLongArray(in GodotVariant[] arguments)
    {
        const v = numbers(arguments);
        long[] result;
        result.length = v.length;
        foreach(i; 0 .. v.length)
            result[i] = cast(long) v[i];
        return GodotVariant(result);
    }

    private GodotVariant packedFloatArray(in GodotVariant[] arguments)
    {
        const v = numbers(arguments);
        float[] result;
        result.length = v.length;
        foreach(i; 0 .. v.length)
            result[i] = cast(float) v[i];
        return GodotVariant(result);
    }

    private GodotVariant packedDoubleArray(in GodotVariant[] arguments)
    {
        const v = numbers(arguments);
        double[] result;
        result.length = v.length;
        foreach(i; 0 .. v.length)
            result[i] = v[i];
        return GodotVariant(result);
    }

    private GodotVariant packedStringArray(in GodotVariant[] arguments)
    {
        string[] result;
        foreach(argument; arguments)
            result ~= asString(argument);
        return GodotVariant(result);
    }

    private void requireMultiple(in double[] values, size_t count, string name)
    {
        if(values.length % count != 0)
            throw new PukanException(name ~ " expects a multiple of " ~ count.to!string ~ " numbers");
    }

    private GodotVariant packedVector2Array(in GodotVariant[] arguments)
    {
        const v = numbers(arguments);
        requireMultiple(v, 2, "PackedVector2Array");

        Vector2f[] result;
        result.length = v.length / 2;
        foreach(i; 0 .. result.length)
            result[i] = Vector2f(cast(float) v[i * 2], cast(float) v[i * 2 + 1]);
        return GodotVariant(result);
    }

    private GodotVariant packedVector3Array(in GodotVariant[] arguments)
    {
        const v = numbers(arguments);
        requireMultiple(v, 3, "PackedVector3Array");

        Vector3f[] result;
        result.length = v.length / 3;
        foreach(i; 0 .. result.length)
            result[i] = Vector3f(cast(float) v[i * 3], cast(float) v[i * 3 + 1], cast(float) v[i * 3 + 2]);
        return GodotVariant(result);
    }

    private GodotVariant packedVector4Array(in GodotVariant[] arguments)
    {
        const v = numbers(arguments);
        requireMultiple(v, 4, "PackedVector4Array");

        Vector4f[] result;
        result.length = v.length / 4;
        foreach(i; 0 .. result.length)
            result[i] = Vector4f(cast(float) v[i * 4], cast(float) v[i * 4 + 1], cast(float) v[i * 4 + 2], cast(float) v[i * 4 + 3]);
        return GodotVariant(result);
    }

    private GodotVariant packedColorArray(in GodotVariant[] arguments)
    {
        GodotColor[] result;

        if(arguments.length && arguments[0].type is typeid(GodotColor))
        {
            foreach(argument; arguments)
                result ~= as!(GodotColor)(argument);
            return GodotVariant(result);
        }

        const v = numbers(arguments);
        requireMultiple(v, 4, "PackedColorArray");
        result.length = v.length / 4;
        foreach(i; 0 .. result.length)
            result[i] = GodotColor(
                cast(float) v[i * 4], cast(float) v[i * 4 + 1],
                cast(float) v[i * 4 + 2], cast(float) v[i * 4 + 3],
            );
        return GodotVariant(result);
    }

    private GodotVariant arrayConstructor(in GodotVariant[] arguments)
    {
        if(arguments.length == 0)
            return GodotVariant(new GodotArray);
        if(arguments.length == 1 && arguments[0].type is typeid(GodotArray))
            return arguments[0];

        throw new PukanException("unsupported Array() arguments");
    }

    private GodotVariant dictionaryConstructor(in GodotVariant[] arguments)
    {
        if(arguments.length == 0)
            return GodotVariant(new GodotDictionary);
        if(arguments.length == 1 && arguments[0].type is typeid(GodotDictionary))
            return arguments[0];

        throw new PukanException("unsupported Dictionary() arguments");
    }

    GodotTextTag parseTag()
    {
        expect('[');

        GodotTextTag tag;
        tag.name = parseIdentifier();

        while(true)
        {
            skipSpace();

            if(eof)
                fail("unterminated tag");

            if(accept(']'))
                break;

            const key = parseIdentifier();
            expect('=');
            tag.fields[key] = parseValue();
        }

        return tag;
    }

    GodotTextDocument parseDocument()
    {
        GodotTextDocument result;

        if(src.length >= 3 && src[0] == '\xEF' && src[1] == '\xBB' && src[2] == '\xBF')
            pos = 3;

        skipSpace();
        if(eof)
            fail("empty text resource");

        const header = parseTag();

        if(header.name == "gd_scene")
            result.isScene = true;
        else if(header.name == "gd_resource")
            result.resourceType = asString(header.fields["type"], "resource type");
        else
            fail("expected gd_scene or gd_resource");

        if(auto format = "format" in header.fields)
        {
            result.format = cast(int) asLong(*format, "format");
            if(result.format < 3 || result.format > 4)
                fail("unsupported text format " ~ result.format.to!string);
        }

        if(auto uid = "uid" in header.fields)
            result.uid = asString(*uid, "uid");

        if(auto scriptClass = "script_class" in header.fields)
            result.scriptClass = asString(*scriptClass, "script_class");

        enum Target
        {
            none,
            subResource,
            node,
            mainResource,
        }

        Target target = Target.none;

        while(true)
        {
            skipSpace();
            if(eof)
                break;

            if(peek == '[')
            {
                auto tag = parseTag();

                switch(tag.name)
                {
                    case "ext_resource":
                        GodotTextExternal external;
                        external.type = asString(tag.fields["type"], "external type");
                        external.path = asString(tag.fields["path"], "external path");
                        external.id = scalarId(tag.fields["id"], "external id");
                        if(auto uid = "uid" in tag.fields)
                            external.uid = asString(*uid, "external uid");
                        result.externals ~= external;
                        target = Target.none;
                        break;

                    case "sub_resource":
                        GodotTextResource resource;
                        resource.type = asString(tag.fields["type"], "sub-resource type");
                        resource.id = scalarId(tag.fields["id"], "sub-resource id");
                        result.subResources ~= resource;
                        target = Target.subResource;
                        break;

                    case "node":
                        GodotTextNode node;
                        node.name = asString(tag.fields["name"], "node name");
                        if(auto type = "type" in tag.fields)
                            node.type = asString(*type, "node type");
                        if(auto parent = "parent" in tag.fields)
                            node.parent = asString(*parent, "node parent");
                        if(auto instance = "instance" in tag.fields)
                            node.instance = *instance;
                        node.fields = tag.fields;
                        result.nodes ~= node;
                        target = Target.node;
                        break;

                    case "resource":
                        target = Target.mainResource;
                        break;

                    case "connection":
                    case "editable":
                        target = Target.none;
                        break;

                    default:
                        ++result.unknownTags;
                        target = Target.none;
                        break;
                }
            }
            else
            {
                string key = peek == '"' ? parseString() : parseIdentifier();
                expect('=');
                const value = parseValue();

                final switch(target)
                {
                    case Target.none:
                        break;

                    case Target.subResource:
                        result.subResources[$ - 1].properties[key] = value;
                        break;

                    case Target.node:
                        result.nodes[$ - 1].properties[key] = value;
                        break;

                    case Target.mainResource:
                        result.resourceProperties[key] = value;
                        break;
                }
            }
        }

        return result;
    }
}

unittest
{
    const text = q"EOS
[gd_scene format=3]

[ext_resource type="Texture2D" path="res://checker.png" id="1_abc"]

[sub_resource type="ArrayMesh" id="ArrayMesh_1"]
_surfaces = [{
"format": 34359738391,
"primitive": 3
}]

[node name="Root" type="Node3D"]
transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 2, 3)

[node name="Child" type="MeshInstance3D" parent="."]
mesh = SubResource("ArrayMesh_1")
visible = false
EOS";

    const document = parseGodotText(text);
    assert(document.isScene);
    assert(document.format == 3);
    assert(document.externals.length == 1);
    assert(document.externals[0].path == "res://checker.png");
    assert(document.subResources.length == 1);
    assert(document.subResources[0].type == "ArrayMesh");
    assert(document.nodes.length == 2);
    assert(document.nodes[0].name == "Root");
    assert(document.nodes[1].parent == ".");
    assert(document.nodes[1].properties["visible"].get!bool == false);

    const transform = document.nodes[0].properties["transform"].get!GodotTransform3D;
    const matrix = transform.toMatrix;
    assert(matrix.a14 == 1 && matrix.a24 == 2 && matrix.a34 == 3);

    const surfaces = document.subResources[0].properties["_surfaces"].get!GodotArray;
    assert(surfaces.length == 1);
    assert(surfaces[0].get!GodotDictionary.get("format").get!long == 34359738391);
}

private string fixturePath(string relative)
{
    import std.path: buildPath, dirName;
    return buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "demo", "assets", "godot_samples", relative);
}

unittest
{
    auto document = parseGodotTextFile(fixturePath("generated/procedural.tscn"));
    assert(document.format == 4);
    assert(document.externals.length == 1);
    assert(document.subResources.length == 3);
    assert(document.nodes.length == 2);

    GodotTextResource* mesh;
    foreach(ref resource; document.subResources)
        if(resource.type == "ArrayMesh")
            mesh = &resource;
    assert(mesh !is null);

    const surfaces = mesh.properties["_surfaces"].get!GodotArray;
    assert(surfaces.length == 2);

    const first = surfaces[0].get!GodotDictionary;
    assert((*first.get("format")).get!long == 34359742495);
    assert((*first.get("vertex_count")).get!long == 4);
    assert((*first.get("vertex_data")).get!(ubyte[]).length == 80);
    assert((*first.get("attribute_data")).get!(ubyte[]).length == 48);
    assert((*first.get("index_data")).get!(ubyte[]).length == 12);

    const procedural = document.nodes[1];
    assert(procedural.name == "Procedural");
    const transform = procedural.properties["transform"].get!GodotTransform3D;
    const matrix = transform.toMatrix;
    assert(matrix.a14 == 0 && matrix.a24 == 1 && matrix.a34 == 0);
    assert(matrix.a11 > 0.866f && matrix.a11 < 0.867f);
}

unittest
{
    auto document = parseGodotTextFile(fixturePath("lights_and_shadows/test.tscn"));
    assert(document.isScene);
    assert(document.nodes.length > 0);
    assert(document.subResources.length > 0);
    assert(document.externals.length > 0);
}

unittest
{
    auto document = parseGodotTextFile(fixturePath("platformer/enemy/enemy.tscn"));
    assert(document.isScene);
    assert(document.nodes.length > 0);
    assert(document.subResources.length > 0);

    bool foundPackedInt;
    foreach(ref node; document.nodes)
        if(auto ids = "parent_id_path" in node.fields)
            if((*ids).type is typeid(int[]))
                foundPackedInt = true;
    assert(foundPackedInt);
}
