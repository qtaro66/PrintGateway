using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using SkiaSharp;
using SkiaSharp.HarfBuzz;

const int CanvasWidth = 576;
const int HorizontalMargin = 18;
const int ContentWidth = CanvasWidth - (HorizontalMargin * 2);

var options = ParseArguments(args);
var fixturePath = RequireFile(options, "fixture");
var fontRoot = RequireDirectory(options, "font-root");
var outputPath = RequireOutputPath(options, "output");
var threshold = RequireInteger(options, "threshold", 1, 254);

var regularFontPath = Path.Combine(fontRoot, "NotoSansThaiLooped-Regular.ttf");
var boldFontPath = Path.Combine(fontRoot, "NotoSansThaiLooped-Bold.ttf");
RequireExistingFile(regularFontPath);
RequireExistingFile(boldFontPath);

var fixture = JsonSerializer.Deserialize<Fixture>(
    File.ReadAllText(fixturePath),
    new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
    ?? throw new InvalidDataException("Fixture JSON is empty.");

if (!fixture.SyntheticData)
{
    throw new InvalidDataException("Only synthetic commissioning fixtures are allowed.");
}

if (!fixture.Title.Contains("TEST ONLY", StringComparison.Ordinal))
{
    throw new InvalidDataException("Fixture title must contain the exact TEST ONLY marker.");
}

using var regularTypeface = SKTypeface.FromFile(regularFontPath)
    ?? throw new InvalidDataException("Unable to load bundled Regular font.");
using var boldTypeface = SKTypeface.FromFile(boldFontPath)
    ?? throw new InvalidDataException("Unable to load bundled Bold font.");
using var regularShaper = new SKShaper(regularTypeface);
using var boldShaper = new SKShaper(boldTypeface);

var lines = BuildLines(fixture, regularTypeface, boldTypeface, regularShaper, boldShaper);
var height = 24 + lines.Sum(line => line.LineHeight) + 24;

var imageInfo = new SKImageInfo(CanvasWidth, height, SKColorType.Bgra8888, SKAlphaType.Premul);
using var surface = SKSurface.Create(imageInfo)
    ?? throw new InvalidOperationException("Unable to create raster preview surface.");
var canvas = surface.Canvas;
canvas.Clear(SKColors.White);

float y = 24;
foreach (var line in lines)
{
    if (line.IsRule)
    {
        using var rulePaint = new SKPaint { Color = SKColors.Black, StrokeWidth = 2, IsAntialias = false };
        y += line.LineHeight / 2f;
        canvas.DrawLine(HorizontalMargin, y, CanvasWidth - HorizontalMargin, y, rulePaint);
        y += line.LineHeight / 2f;
        continue;
    }

    using var font = new SKFont(line.Bold ? boldTypeface : regularTypeface, line.FontSize);
    using var paint = new SKPaint { Color = SKColors.Black, IsAntialias = true };
    var shaper = line.Bold ? boldShaper : regularShaper;
    y += line.BaselineOffset;
    canvas.DrawShapedText(
        shaper,
        line.Text,
        HorizontalMargin + line.Indent,
        y,
        SKTextAlign.Left,
        font,
        paint);
    y += line.LineHeight - line.BaselineOffset;
}

Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
using var image = surface.Snapshot();
using var encoded = image.Encode(SKEncodedImageFormat.Png, 100);
using (var output = File.Create(outputPath))
{
    encoded.SaveTo(output);
}

using var sourceBitmap = SKBitmap.FromImage(image);
using var monochromeBitmap = new SKBitmap(
    CanvasWidth,
    height,
    SKColorType.Bgra8888,
    SKAlphaType.Premul);
var bytesPerRow = CanvasWidth / 8;
var raster = new byte[bytesPerRow * height];
var blackPixels = 0;

for (var pixelY = 0; pixelY < height; pixelY++)
{
    for (var pixelX = 0; pixelX < CanvasWidth; pixelX++)
    {
        var color = sourceBitmap.GetPixel(pixelX, pixelY);
        var luminance = ((299 * color.Red) + (587 * color.Green) + (114 * color.Blue)) / 1000;
        var isBlack = luminance < threshold;
        monochromeBitmap.SetPixel(pixelX, pixelY, isBlack ? SKColors.Black : SKColors.White);
        if (!isBlack)
        {
            continue;
        }

        var byteIndex = (pixelY * bytesPerRow) + (pixelX >> 3);
        var bit = 7 - (pixelX % 8);
        raster[byteIndex] |= (byte)(1 << bit);
        blackPixels++;
    }
}

var monoPath = Path.Combine(
    Path.GetDirectoryName(outputPath)!,
    Path.GetFileNameWithoutExtension(outputPath) + ".mono.png");
using (var monoImage = SKImage.FromBitmap(monochromeBitmap))
using (var monoEncoded = monoImage.Encode(SKEncodedImageFormat.Png, 100))
using (var monoOutput = File.Create(monoPath))
{
    monoEncoded.SaveTo(monoOutput);
}

var rasterPath = Path.Combine(
    Path.GetDirectoryName(outputPath)!,
    Path.GetFileNameWithoutExtension(outputPath) + ".raster.bin");
File.WriteAllBytes(rasterPath, raster);

var payloadPath = Path.Combine(
    Path.GetDirectoryName(outputPath)!,
    Path.GetFileNameWithoutExtension(outputPath) + ".escpos.bin");
var storeHeader = BuildGraphicsStoreHeader(CanvasWidth, height, raster.Length);
var payload = new List<byte>(2 + storeHeader.Length + raster.Length + 7 + 3 + 3);
payload.AddRange(new byte[] { 0x1B, 0x40 });
payload.AddRange(storeHeader);
payload.AddRange(raster);
payload.AddRange(new byte[] { 0x1D, 0x28, 0x4C, 0x02, 0x00, 0x30, 0x32 });
payload.AddRange(new byte[] { 0x1B, 0x64, 0x04 });
payload.AddRange(new byte[] { 0x1D, 0x56, 0x01 });
File.WriteAllBytes(payloadPath, payload.ToArray());

var metadataPath = Path.ChangeExtension(outputPath, ".metadata.json");
var metadata = new
{
    schemaVersion = "1.0",
    fixtureId = fixture.FixtureId,
    syntheticData = fixture.SyntheticData,
    widthDots = CanvasWidth,
    heightDots = height,
    renderer = "SkiaSharp.HarfBuzz",
    rendererVersion = "4.152.1",
    fontFamily = "Noto Sans Thai Looped",
    fontVersion = "2.000",
    threshold,
    bytesPerRow,
    rasterBytes = raster.Length,
    blackPixels,
    payloadBytes = payload.Count,
    payloadFormat = "ESC @ + GS ( L Function 112 + raster + Function 50 + feed 4 + partial cut",
    payloadIncludesDrawerPulse = false,
    payloadIncludesProcessId = false,
    payloadTransmitted = false,
    regularFontSha256 = Sha256(regularFontPath),
    boldFontSha256 = Sha256(boldFontPath),
    previewPngSha256 = Sha256(outputPath),
    monochromePngSha256 = Sha256(monoPath),
    rasterSha256 = Sha256(rasterPath),
    payloadSha256 = Sha256(payloadPath)
};
File.WriteAllText(
    metadataPath,
    JsonSerializer.Serialize(metadata, new JsonSerializerOptions { WriteIndented = true }) + Environment.NewLine);

Console.WriteLine(JsonSerializer.Serialize(new
{
    outputPath,
    monoPath,
    rasterPath,
    payloadPath,
    metadataPath,
    widthDots = CanvasWidth,
    heightDots = height,
    threshold,
    rasterBytes = raster.Length,
    payloadBytes = payload.Count,
    payloadSha256 = metadata.payloadSha256,
    printerBytesSent = 0,
    networkAccess = false
}));

static byte[] BuildGraphicsStoreHeader(int widthDots, int heightDots, int rasterLength)
{
    if (widthDots <= 0 || widthDots % 8 != 0)
    {
        throw new ArgumentOutOfRangeException(nameof(widthDots), "Width must be positive and divisible by 8.");
    }

    var expectedLength = (widthDots / 8) * heightDots;
    if (rasterLength != expectedLength)
    {
        throw new InvalidDataException($"Raster length mismatch. Expected {expectedLength}, actual {rasterLength}.");
    }

    var parameterLength = checked(10 + rasterLength);
    if (parameterLength > ushort.MaxValue || heightDots > ushort.MaxValue || widthDots > ushort.MaxValue)
    {
        throw new InvalidDataException("Raster dimensions exceed the two-byte GS ( L command fields.");
    }

    return
    [
        0x1D, 0x28, 0x4C,
        (byte)(parameterLength & 0xFF), (byte)((parameterLength >> 8) & 0xFF),
        0x30, 0x70,
        0x30, 0x01, 0x01, 0x31,
        (byte)(widthDots & 0xFF), (byte)((widthDots >> 8) & 0xFF),
        (byte)(heightDots & 0xFF), (byte)((heightDots >> 8) & 0xFF)
    ];
}

static List<LayoutLine> BuildLines(
    Fixture fixture,
    SKTypeface regularTypeface,
    SKTypeface boldTypeface,
    SKShaper regularShaper,
    SKShaper boldShaper)
{
    var lines = new List<LayoutLine>();
    AddWrapped(lines, fixture.Title, true, 30, 0, boldTypeface, boldShaper);
    AddWrapped(lines, fixture.Station, true, 25, 0, boldTypeface, boldShaper);
    AddWrapped(lines, $"เลขทดสอบ: {fixture.OrderNumber}", false, 23, 0, regularTypeface, regularShaper);
    AddWrapped(lines, $"โต๊ะ: {fixture.Table}  ประเภท: {fixture.OrderType}", false, 23, 0, regularTypeface, regularShaper);
    AddWrapped(lines, fixture.CreatedAtDisplay, false, 20, 0, regularTypeface, regularShaper);
    lines.Add(LayoutLine.Rule());

    foreach (var item in fixture.Items)
    {
        AddWrapped(lines, $"{item.Quantity} × {item.Name}", true, 27, 0, boldTypeface, boldShaper);
        foreach (var topping in item.Toppings)
        {
            AddWrapped(lines, $"+ {topping}", false, 23, 22, regularTypeface, regularShaper);
        }

        if (!string.IsNullOrWhiteSpace(item.Note))
        {
            AddWrapped(lines, $"หมายเหตุ: {item.Note}", false, 22, 22, regularTypeface, regularShaper);
        }

        lines.Add(LayoutLine.Spacer(7));
    }

    lines.Add(LayoutLine.Rule());
    foreach (var footer in fixture.Footer)
    {
        AddWrapped(lines, footer, true, 21, 0, boldTypeface, boldShaper);
    }

    return lines;
}

static void AddWrapped(
    List<LayoutLine> destination,
    string text,
    bool bold,
    float fontSize,
    float indent,
    SKTypeface typeface,
    SKShaper shaper)
{
    using var font = new SKFont(typeface, fontSize);
    var maximumWidth = ContentWidth - indent;
    foreach (var paragraph in text.Replace("\r", string.Empty, StringComparison.Ordinal).Split('\n'))
    {
        var remaining = new List<string>();
        var enumerator = StringInfo.GetTextElementEnumerator(paragraph);
        while (enumerator.MoveNext())
        {
            remaining.Add(enumerator.GetTextElement());
        }

        while (remaining.Count > 0)
        {
            var fittingCount = 0;
            var lastWhitespaceBreak = 0;
            var candidate = string.Empty;
            for (var index = 0; index < remaining.Count; index++)
            {
                var nextCandidate = candidate + remaining[index];
                if (candidate.Length > 0 && shaper.Shape(nextCandidate, font).Width > maximumWidth)
                {
                    break;
                }

                candidate = nextCandidate;
                fittingCount = index + 1;
                if (string.IsNullOrWhiteSpace(remaining[index]))
                {
                    lastWhitespaceBreak = fittingCount;
                }
            }

            if (fittingCount == remaining.Count)
            {
                destination.Add(LayoutLine.TextLine(string.Concat(remaining).Trim(), bold, fontSize, indent));
                remaining.Clear();
                continue;
            }

            var breakCount = lastWhitespaceBreak > 0 ? lastWhitespaceBreak : Math.Max(1, fittingCount);
            var line = string.Concat(remaining.Take(breakCount)).Trim();
            destination.Add(LayoutLine.TextLine(line, bold, fontSize, indent));
            remaining.RemoveRange(0, breakCount);
            while (remaining.Count > 0 && string.IsNullOrWhiteSpace(remaining[0]))
            {
                remaining.RemoveAt(0);
            }
        }
    }
}

static Dictionary<string, string> ParseArguments(string[] arguments)
{
    if (arguments.Length % 2 != 0)
    {
        throw new ArgumentException("Arguments must be supplied as --name value pairs.");
    }

    var result = new Dictionary<string, string>(StringComparer.Ordinal);
    for (var index = 0; index < arguments.Length; index += 2)
    {
        if (!arguments[index].StartsWith("--", StringComparison.Ordinal))
        {
            throw new ArgumentException($"Invalid argument name: {arguments[index]}");
        }

        result.Add(arguments[index][2..], arguments[index + 1]);
    }

    return result;
}

static string RequireFile(Dictionary<string, string> options, string name)
{
    var path = RequireOption(options, name);
    RequireExistingFile(path);
    return Path.GetFullPath(path);
}

static string RequireDirectory(Dictionary<string, string> options, string name)
{
    var path = Path.GetFullPath(RequireOption(options, name));
    if (!Directory.Exists(path))
    {
        throw new DirectoryNotFoundException(path);
    }

    return path;
}

static string RequireOutputPath(Dictionary<string, string> options, string name)
{
    var path = Path.GetFullPath(RequireOption(options, name));
    if (!string.Equals(Path.GetExtension(path), ".png", StringComparison.OrdinalIgnoreCase))
    {
        throw new ArgumentException("Output path must use the .png extension.");
    }

    return path;
}

static int RequireInteger(Dictionary<string, string> options, string name, int minimum, int maximum)
{
    var rawValue = RequireOption(options, name);
    if (!int.TryParse(rawValue, NumberStyles.None, CultureInfo.InvariantCulture, out var value) ||
        value < minimum ||
        value > maximum)
    {
        throw new ArgumentOutOfRangeException(name, $"Value must be an integer from {minimum} through {maximum}.");
    }

    return value;
}

static string RequireOption(Dictionary<string, string> options, string name) =>
    options.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
        ? value
        : throw new ArgumentException($"Missing required option --{name}.");

static void RequireExistingFile(string path)
{
    if (!File.Exists(path))
    {
        throw new FileNotFoundException("Required file not found.", path);
    }
}

static string Sha256(string path)
{
    using var stream = File.OpenRead(path);
    return Convert.ToHexString(SHA256.HashData(stream));
}

internal sealed record LayoutLine(
    string Text,
    bool Bold,
    float FontSize,
    float Indent,
    int LineHeight,
    int BaselineOffset,
    bool IsRule)
{
    public static LayoutLine TextLine(string text, bool bold, float fontSize, float indent)
    {
        var lineHeight = (int)Math.Ceiling(fontSize * 1.55f);
        var baseline = (int)Math.Ceiling(fontSize * 1.15f);
        return new LayoutLine(text, bold, fontSize, indent, lineHeight, baseline, false);
    }

    public static LayoutLine Spacer(int height) => new(string.Empty, false, 1, 0, height, 0, false);
    public static LayoutLine Rule() => new(string.Empty, false, 1, 0, 18, 0, true);
}

internal sealed class Fixture
{
    public string FixtureId { get; init; } = string.Empty;
    public bool SyntheticData { get; init; }
    public string Title { get; init; } = string.Empty;
    public string Station { get; init; } = string.Empty;
    public string OrderNumber { get; init; } = string.Empty;
    public string Table { get; init; } = string.Empty;
    public string OrderType { get; init; } = string.Empty;
    public string CreatedAtDisplay { get; init; } = string.Empty;
    public List<FixtureItem> Items { get; init; } = [];
    public List<string> Footer { get; init; } = [];
}

internal sealed class FixtureItem
{
    public int Quantity { get; init; }
    public string Name { get; init; } = string.Empty;
    public List<string> Toppings { get; init; } = [];
    public string? Note { get; init; }
}
