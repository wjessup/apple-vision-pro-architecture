using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RevitSync
{
    // Vector glyphs on a 32x32 canvas, rasterized at load so the add-in ships no image files.
    internal static class Icons
    {
        private static readonly Brush Accent = Frozen(new SolidColorBrush(Color.FromRgb(0x1E, 0x6F, 0xD9)));
        private static readonly Brush Ink = Frozen(new SolidColorBrush(Color.FromRgb(0x3A, 0x3A, 0x3A)));

        // Vision Pro headset: visor with a strap.
        public static readonly DrawingGroup Headset = Group(
            new GeometryDrawing(Accent, null, Geometry.Parse("M6,11 C6,8 9,7 16,7 C23,7 26,8 26,11 L26,19 C26,23 23,24 20,24 C18,24 17.5,21 16,21 C14.5,21 14,24 12,24 C9,24 6,23 6,19 Z")),
            new GeometryDrawing(null, new Pen(Ink, 2), Geometry.Parse("M6,14 L2,15 L2,18 L6,18 M26,14 L30,15 L30,18 L26,18")),
            new GeometryDrawing(Brushes.White, null, Geometry.Parse("M9,12 L23,12 L23,15 L9,15 Z")));

        // Void: solid slab with a hole cut through it.
        public static readonly DrawingGroup Void = Group(
            new GeometryDrawing(Ink, null, new CombinedGeometry(GeometryCombineMode.Exclude,
                Geometry.Parse("M3,10 L29,10 L29,24 L3,24 Z"),
                Geometry.Parse("M10,13 L22,13 L22,21 L10,21 Z"))),
            new GeometryDrawing(null, new Pen(Accent, 2) { DashStyle = new DashStyle(new double[] { 1.5, 1 }, 0) },
                Geometry.Parse("M10,13 L22,13 L22,21 L10,21 Z")));

        // Settings: gear.
        public static readonly DrawingGroup Gear = Group(
            new GeometryDrawing(Ink, null, new CombinedGeometry(GeometryCombineMode.Exclude,
                Geometry.Parse("M14,3 L18,3 L18.8,7 L22,8.4 L25.4,6.1 L27.9,8.6 L25.6,12 L27,15.2 L31,16 L31,20 L27,20.8 L25.6,24 L27.9,27.4 L25.4,29.9 L22,27.6 L18.8,29 L18,33 L14,33 L13.2,29 L10,27.6 L6.6,29.9 L4.1,27.4 L6.4,24 L5,20.8 L1,20 L1,16 L5,15.2 L6.4,12 L4.1,8.6 L6.6,6.1 L10,8.4 L13.2,7 Z"),
                new EllipseGeometry(new Point(16, 18), 5, 5)) { Transform = new TranslateTransform(0, -2) }));

        public static ImageSource Render(DrawingGroup drawing, int size)
        {
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                dc.PushTransform(new ScaleTransform(size / 32.0, size / 32.0));
                dc.DrawDrawing(drawing);
            }
            var bitmap = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            bitmap.Freeze();
            return bitmap;
        }

        private static DrawingGroup Group(params Drawing[] children)
        {
            var group = new DrawingGroup();
            foreach (var child in children) group.Children.Add(child);
            group.Children.Insert(0, new GeometryDrawing(Brushes.Transparent, null, new RectangleGeometry(new Rect(0, 0, 32, 32))));
            group.ClipGeometry = new RectangleGeometry(new Rect(0, 0, 32, 32));
            group.Freeze();
            return group;
        }

        private static Brush Frozen(Brush brush)
        {
            brush.Freeze();
            return brush;
        }
    }
}
