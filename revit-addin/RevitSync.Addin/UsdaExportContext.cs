using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using Autodesk.Revit.DB;

namespace RevitSync
{
    public class PartitionFile
    {
        public string Id;
        public string Name;
        public string Path;
    }

    /// Writes one .usda per Revit level, Y-up, metres, origin at the project base point.
    public class UsdaExportContext : IExportContext
    {
        private const double FeetToMetres = 0.3048;

        private readonly Document _doc;
        private readonly string _outputDir;
        private readonly Stack<Transform> _transforms = new Stack<Transform>();
        private readonly Stack<Document> _documents = new Stack<Document>();
        private readonly Dictionary<string, PartitionWriter> _partitions = new Dictionary<string, PartitionWriter>();
        private readonly Dictionary<string, MaterialInfo> _materials = new Dictionary<string, MaterialInfo>();

        private XYZ _basePoint = XYZ.Zero;
        private PartitionWriter _current;
        private MaterialInfo _currentMaterial;
        private Dictionary<MaterialInfo, MeshBuffer> _elementMeshes;

        public UsdaExportContext(Document doc, string outputDir)
        {
            _doc = doc;
            _outputDir = outputDir;
        }

        public IReadOnlyList<PartitionFile> Partitions =>
            _partitions.Values.Where(p => p.MeshCount > 0)
                .Select(p => new PartitionFile { Id = p.Id, Name = p.Name, Path = p.Path })
                .ToList();

        public bool Start()
        {
            Directory.CreateDirectory(_outputDir);
            _transforms.Push(Transform.Identity);
            _documents.Push(_doc);
            var pbp = BasePoint.GetProjectBasePoint(_doc);
            if (pbp != null) _basePoint = pbp.Position;
            _currentMaterial = MaterialInfo.Default;
            return true;
        }

        public void Finish()
        {
            foreach (var partition in _partitions.Values) partition.Close();
        }

        public bool IsCanceled() => false;

        public RenderNodeAction OnViewBegin(ViewNode node)
        {
            node.LevelOfDetail = 8;
            return RenderNodeAction.Proceed;
        }

        public void OnViewEnd(ElementId elementId) { }

        public RenderNodeAction OnElementBegin(ElementId elementId)
        {
            var element = _documents.Peek().GetElement(elementId);
            if (element == null) return RenderNodeAction.Skip;
            _current = PartitionFor(element);
            _elementMeshes = new Dictionary<MaterialInfo, MeshBuffer>();
            return RenderNodeAction.Proceed;
        }

        public void OnElementEnd(ElementId elementId)
        {
            if (_elementMeshes == null) return;
            foreach (var pair in _elementMeshes)
            {
                if (pair.Value.FaceCount == 0) continue;
                _current.WriteMesh($"e{elementId.Value()}_{_current.MeshCount}", pair.Value, pair.Key);
            }
            _elementMeshes = null;
        }

        public RenderNodeAction OnInstanceBegin(InstanceNode node)
        {
            _transforms.Push(_transforms.Peek().Multiply(node.GetTransform()));
            return RenderNodeAction.Proceed;
        }

        public void OnInstanceEnd(InstanceNode node) => _transforms.Pop();

        public RenderNodeAction OnLinkBegin(LinkNode node)
        {
            _transforms.Push(_transforms.Peek().Multiply(node.GetTransform()));
            _documents.Push(node.GetDocument());
            return RenderNodeAction.Proceed;
        }

        public void OnLinkEnd(LinkNode node)
        {
            _transforms.Pop();
            _documents.Pop();
        }

        public RenderNodeAction OnFaceBegin(FaceNode node) => RenderNodeAction.Proceed;

        public void OnFaceEnd(FaceNode node) { }

        public void OnRPC(RPCNode node) { }

        public void OnLight(LightNode node) { }

        public void OnMaterial(MaterialNode node)
        {
            var key = _documents.Peek().Title + "/" + node.MaterialId.Value();
            if (!_materials.TryGetValue(key, out var info))
            {
                info = MaterialInfo.From(node);
                _materials[key] = info;
            }
            _currentMaterial = info;
        }

        public void OnPolymesh(PolymeshTopology node)
        {
            if (_elementMeshes == null) return;
            if (!_elementMeshes.TryGetValue(_currentMaterial, out var buffer))
            {
                buffer = new MeshBuffer();
                _elementMeshes[_currentMaterial] = buffer;
            }

            var transform = _transforms.Peek();
            var mirrored = transform.Determinant < 0;
            var baseIndex = buffer.Points.Count;

            foreach (var p in node.GetPoints())
            {
                var w = transform.OfPoint(p) - _basePoint;
                buffer.Points.Add(ToUsd(w));
            }

            var facets = node.GetFacets();
            var normals = node.GetNormals();
            var pointNormals = new XYZ[node.NumberOfPoints];

            switch (node.DistributionOfNormals)
            {
                case DistributionOfNormals.AtEachPoint:
                    for (var i = 0; i < pointNormals.Length; i++) pointNormals[i] = normals[i];
                    break;
                case DistributionOfNormals.OnePerFace:
                    for (var i = 0; i < pointNormals.Length; i++) pointNormals[i] = normals[0];
                    break;
                default:
                    for (var i = 0; i < facets.Count; i++)
                    {
                        pointNormals[facets[i].V1] = normals[i];
                        pointNormals[facets[i].V2] = normals[i];
                        pointNormals[facets[i].V3] = normals[i];
                    }
                    break;
            }
            foreach (var n in pointNormals) buffer.PointNormals.Add(ToUsd(transform.OfVector(n ?? XYZ.BasisZ)));

            foreach (var f in facets)
            {
                if (mirrored)
                    buffer.AddFace(baseIndex + f.V1, baseIndex + f.V3, baseIndex + f.V2);
                else
                    buffer.AddFace(baseIndex + f.V1, baseIndex + f.V2, baseIndex + f.V3);
            }
        }

        private static XYZ ToUsd(XYZ revit) => new XYZ(revit.X * FeetToMetres, revit.Z * FeetToMetres, -revit.Y * FeetToMetres);

        private PartitionWriter PartitionFor(Element element)
        {
            var levelId = element.LevelId;
            if (levelId == ElementId.InvalidElementId)
            {
                var param = element.get_Parameter(BuiltInParameter.FAMILY_LEVEL_PARAM)
                            ?? element.get_Parameter(BuiltInParameter.SCHEDULE_LEVEL_PARAM);
                if (param != null) levelId = param.AsElementId();
            }

            string id, name;
            if (levelId != ElementId.InvalidElementId && _documents.Peek().GetElement(levelId) is Level level)
            {
                id = "level-" + levelId.Value();
                name = level.Name;
            }
            else
            {
                id = "site";
                name = "Site and unlevelled";
            }
            if (_documents.Count > 1)
            {
                id = "link-" + Settings.Slugify(_documents.Peek().Title) + "-" + id;
                name = _documents.Peek().Title + " / " + name;
            }

            if (!_partitions.TryGetValue(id, out var writer))
            {
                writer = new PartitionWriter(id, name, Path.Combine(_outputDir, id + ".usda"));
                _partitions[id] = writer;
            }
            return writer;
        }
    }

    public class MaterialInfo
    {
        public string PrimName;
        public double R, G, B;
        public double Roughness;
        public double Opacity;

        public static readonly MaterialInfo Default = new MaterialInfo
        {
            PrimName = "default", R = 0.6, G = 0.6, B = 0.6, Roughness = 0.7, Opacity = 1,
        };

        public static MaterialInfo From(MaterialNode node)
        {
            var color = node.Color;
            var name = node.MaterialId == ElementId.InvalidElementId ? "default" : "m" + node.MaterialId.Value();
            return new MaterialInfo
            {
                PrimName = name,
                R = SrgbToLinear(color.Red / 255.0),
                G = SrgbToLinear(color.Green / 255.0),
                B = SrgbToLinear(color.Blue / 255.0),
                Roughness = 1.0 - Math.Max(node.Smoothness, node.Glossiness) / 100.0,
                Opacity = 1.0 - node.Transparency,
            };
        }

        private static double SrgbToLinear(double c) =>
            c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
    }

    public class MeshBuffer
    {
        public readonly List<XYZ> Points = new List<XYZ>();
        public readonly List<XYZ> PointNormals = new List<XYZ>();
        public readonly List<int> Indices = new List<int>();
        public int FaceCount;

        public void AddFace(int a, int b, int c)
        {
            Indices.Add(a);
            Indices.Add(b);
            Indices.Add(c);
            FaceCount++;
        }
    }

    public class PartitionWriter
    {
        public readonly string Id;
        public readonly string Name;
        public readonly string Path;
        public int MeshCount;

        private readonly StreamWriter _writer;
        private readonly Dictionary<string, MaterialInfo> _usedMaterials = new Dictionary<string, MaterialInfo>();
        private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        public PartitionWriter(string id, string name, string path)
        {
            Id = id;
            Name = name;
            Path = path;
            _writer = new StreamWriter(path, false, new UTF8Encoding(false), 1 << 16);
            _writer.WriteLine("#usda 1.0");
            _writer.WriteLine("(");
            _writer.WriteLine("    defaultPrim = \"Model\"");
            _writer.WriteLine("    metersPerUnit = 1");
            _writer.WriteLine("    upAxis = \"Y\"");
            _writer.WriteLine(")");
            _writer.WriteLine();
            _writer.WriteLine("def Xform \"Model\" (");
            _writer.WriteLine($"    customData = {{ string revitPartition = \"{id}\" }}");
            _writer.WriteLine(")");
            _writer.WriteLine("{");
        }

        public void WriteMesh(string name, MeshBuffer mesh, MaterialInfo material)
        {
            MeshCount++;
            _usedMaterials[material.PrimName] = material;

            var w = _writer;
            w.WriteLine($"    def Mesh \"{name}\" (");
            w.WriteLine("        prepend apiSchemas = [\"MaterialBindingAPI\"]");
            w.WriteLine("    )");
            w.WriteLine("    {");
            w.WriteLine($"        rel material:binding = </Model/Materials/{material.PrimName}>");
            w.WriteLine("        uniform token subdivisionScheme = \"none\"");
            w.WriteLine("        int[] faceVertexCounts = [" + string.Join(", ", Enumerable.Repeat("3", mesh.FaceCount)) + "]");
            w.WriteLine("        int[] faceVertexIndices = [" + string.Join(", ", mesh.Indices) + "]");
            w.Write("        point3f[] points = [");
            WriteVectors(mesh.Points);
            w.WriteLine("]");

            w.Write("        normal3f[] normals = [");
            WriteVectors(mesh.PointNormals);
            w.WriteLine("] (");
            w.WriteLine("            interpolation = \"vertex\"");
            w.WriteLine("        )");
            w.WriteLine("    }");
        }

        private void WriteVectors(List<XYZ> vectors)
        {
            for (var i = 0; i < vectors.Count; i++)
            {
                if (i > 0) _writer.Write(", ");
                var v = vectors[i];
                _writer.Write('(');
                _writer.Write(v.X.ToString("0.#####", Inv));
                _writer.Write(", ");
                _writer.Write(v.Y.ToString("0.#####", Inv));
                _writer.Write(", ");
                _writer.Write(v.Z.ToString("0.#####", Inv));
                _writer.Write(')');
            }
        }

        public void Close()
        {
            var w = _writer;
            w.WriteLine("    def Scope \"Materials\"");
            w.WriteLine("    {");
            foreach (var m in _usedMaterials.Values)
            {
                w.WriteLine($"        def Material \"{m.PrimName}\"");
                w.WriteLine("        {");
                w.WriteLine($"            token outputs:surface.connect = </Model/Materials/{m.PrimName}/Surface.outputs:surface>");
                w.WriteLine("            def Shader \"Surface\"");
                w.WriteLine("            {");
                w.WriteLine("                uniform token info:id = \"UsdPreviewSurface\"");
                w.WriteLine($"                color3f inputs:diffuseColor = ({F(m.R)}, {F(m.G)}, {F(m.B)})");
                w.WriteLine($"                float inputs:roughness = {F(m.Roughness)}");
                w.WriteLine("                float inputs:metallic = 0");
                w.WriteLine($"                float inputs:opacity = {F(m.Opacity)}");
                w.WriteLine("                token outputs:surface");
                w.WriteLine("            }");
                w.WriteLine("        }");
            }
            w.WriteLine("    }");
            w.WriteLine("}");
            w.Dispose();
        }

        private static string F(double v) => v.ToString("0.####", Inv);
    }

    internal static class ElementIdExtensions
    {
        public static long Value(this ElementId id)
        {
#if NET8_0_OR_GREATER
            return id.Value;
#else
            return id.IntegerValue;
#endif
        }
    }
}
