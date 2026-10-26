static int Parse(string text) {
    if (!int.TryParse(text, out var value) || value is < 0 or > 255)
        throw new FormatException("Invalid byte");
    return value;
}
if (Parse("0") != 0 || Parse("255") != 255) return 4;
foreach (var bad in new[] { "", "-1", "256", "NaN", "99999999999999" }) {
    var rejected = false;
    try { Parse(bad); } catch (FormatException) { rejected = true; }
    if (!rejected) return 5;
}
Console.WriteLine("PASS: .NET positive, negative and limit fixture");
return 0;
