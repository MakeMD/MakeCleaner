using MakeCleaner;

public class CookiesTests
{
    [Theory]
    [InlineData(".example.com", "example.com")]
    [InlineData("www.Example.COM", "example.com")]
    [InlineData(" .www.example.com ", "example.com")]
    [InlineData("mail.google.com", "mail.google.com")]
    public void Normalize_strips_dot_www_and_case(string host, string expected) => Assert.Equal(expected, Cookies.Normalize(host));

    [Theory]
    [InlineData(".example.com", true)]
    [InlineData("example.com", true)]
    [InlineData("www.example.com", true)]
    [InlineData("deep.sub.example.com", true)]
    [InlineData("badexample.com", false)]
    [InlineData("example.com.evil.net", false)]
    [InlineData(null, false)]
    public void Keeping_a_domain_keeps_its_subdomains_only(string? host, bool kept) =>
        Assert.Equal(kept, Cookies.IsKept(host, ["www.example.com"]));

    [Fact]
    public void Empty_keep_list_keeps_nothing() => Assert.False(Cookies.IsKept("example.com", []));

    [Fact]
    public void Parse_reads_one_domain_per_line_ignoring_comments_and_duplicates() =>
        Assert.Equal(["example.com", "github.com"],
            Cookies.Parse(["# my sites", "", "www.github.com", "example.com  # bank", ".example.com", "  "]));
}
