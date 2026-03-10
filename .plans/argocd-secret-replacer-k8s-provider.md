# Plan: Add `MountedSecret` Provider to `argocd-secret-replacer`

## Goal

Add a new CLI verb `secret` with a `--mount` flag to `argocd-secret-replacer`. This provider reads
secrets from a directory of plain-text files (a Kubernetes Secret mounted as a volume), replacing
`<secret:key>` tokens just like the existing `sops` verb does — but with no SOPS dependency, no
per-app encrypted files, and no Age key required.

## Context

Repository: https://github.com/mmalyska/argocd-secret-replacer

The tool is a .NET 9 C# console app that:
1. Reads Kubernetes manifests from **stdin**
2. Replaces `<secret:key>` and `<secret:key|modifier>` tokens with values from a secrets source
3. Writes the result to **stdout**

The existing architecture already has clean extension points:
- `ISecretsProvider` — single method `GetSecret(string key): string`
- `SecretsProviderFactory` — switch on options type to return correct provider
- `ISecretsProviderFactory` / `ISecretsProvider` interfaces — no other changes needed to the
  replacement engine

The new provider must fit into the same pattern as `SopsSecretProvider`.

---

## How Kubernetes Secret Volume Mounts Work

When a K8s Secret is mounted as a volume into a container, each key becomes a file:

```
/cluster-secrets/
├── private-domain        # file content: "PRIVATE_DOMAIN"
├── oidc-keycloak-clientSecret   # file content: "abc123..."
└── private-repo-password # file content: "hunter2"
```

The provider simply reads the file whose name matches the requested key.

---

## Implementation Plan

### Step 1 — Add `MountedSecretOptions` (new CLI verb)

**File to create:** `src/Replacer/SecretsProvider/MountedSecret/MountedSecretOptions.cs`

```csharp
namespace Replacer;

using CommandLine;

[Verb("secret", HelpText = "Read secrets from a Kubernetes Secret mounted as a directory")]
public class MountedSecretOptions
{
    [Option('m', "mount", Required = true, HelpText = "Path to the mounted Kubernetes Secret directory")]
    public string MountPath { get; set; } = string.Empty;
}
```

---

### Step 2 — Implement `MountedSecretProvider`

**File to create:** `src/Replacer/SecretsProvider/MountedSecret/MountedSecretProvider.cs`

```csharp
namespace Replacer.SecretsProvider.MountedSecret;

public sealed class MountedSecretProvider : ISecretsProvider
{
    private readonly string mountPath;

    public MountedSecretProvider(MountedSecretOptions options)
    {
        if (string.IsNullOrWhiteSpace(options.MountPath))
            throw new ArgumentNullException(nameof(options));

        mountPath = options.MountPath;

        if (!Directory.Exists(mountPath))
            throw new DirectoryNotFoundException($"Mounted secret directory not found: {mountPath}");
    }

    public string GetSecret(string key)
    {
        // K8s secret mount: each key is a file named exactly as the key
        var filePath = Path.Combine(mountPath, key);

        if (!File.Exists(filePath))
            return string.Empty;

        // ReadAllText and trim trailing newline/whitespace that editors/K8s may add
        return File.ReadAllText(filePath).TrimEnd('\n', '\r', ' ');
    }
}
```

**Notes:**
- No async needed — file reads are fast and the tool is stdin→stdout batch.
- `TrimEnd` handles the trailing newline that K8s sometimes adds to mounted secret files.
- Returns `string.Empty` (not throw) for missing keys — consistent with `SopsSecretProvider`.

---

### Step 3 — Register the new verb and provider in the factory

**File to modify:** `src/Replacer/SecretsProvider/ISecretsProviderFactory.cs`

Change the `SecretsProviderFactory.GetProvider` switch to handle `MountedSecretOptions`:

```csharp
// Add using at top:
using Replacer.SecretsProvider.MountedSecret;

public class SecretsProviderFactory : ISecretsProviderFactory
{
    public ISecretsProvider GetProvider(object options) => options switch
    {
        SopsOptions sopsOptions => new SopsSecretProvider(sopsOptions, new SopsProcessWrapper(sopsOptions)),
        MountedSecretOptions mountedOptions => new MountedSecretProvider(mountedOptions),
        _ => throw new ArgumentOutOfRangeException(nameof(options), options, null),
    };
}
```

---

### Step 4 — Register the new verb in `Program.cs`

**File to modify:** `src/Replacer/Program.cs`

Add `MountedSecretOptions` to the `ParseArguments` call:

```csharp
// Add using at top:
using Replacer.SecretsProvider.MountedSecret;

var parser = Default.ParseArguments(args, typeof(SopsOptions), typeof(MountedSecretOptions))
    .WithNotParsed(ParseErrors);

parser.WithParsed(RunOptions);
```

No other changes to `Program.cs` are needed — `RunOptions` already calls
`providerFactory.GetProvider(opts)` which now handles both types.

---

### Step 5 — Add unit tests

**File to create:** `test/ReplacerUnitTests/MountedSecret/MountedSecretProviderTests.cs`

```csharp
namespace ReplacerUnitTests.MountedSecret;

using System.IO;
using Replacer;
using Replacer.SecretsProvider.MountedSecret;
using Xunit;

public class MountedSecretProviderTests
{
    [Fact]
    public void WhenKeyExistsShouldReturnValue()
    {
        var dir = CreateTempSecret(("private-domain", "PRIVATE_DOMAIN"));
        var provider = new MountedSecretProvider(new MountedSecretOptions { MountPath = dir });

        Assert.Equal("PRIVATE_DOMAIN", provider.GetSecret("private-domain"));
    }

    [Fact]
    public void WhenKeyMissingShouldReturnEmpty()
    {
        var dir = CreateTempSecret(("other-key", "value"));
        var provider = new MountedSecretProvider(new MountedSecretOptions { MountPath = dir });

        Assert.Equal(string.Empty, provider.GetSecret("missing-key"));
    }

    [Fact]
    public void WhenValueHasTrailingNewlineShouldTrim()
    {
        var dir = CreateTempSecret(("my-key", "hello\n"));
        var provider = new MountedSecretProvider(new MountedSecretOptions { MountPath = dir });

        Assert.Equal("hello", provider.GetSecret("my-key"));
    }

    [Fact]
    public void WhenDirectoryMissingShouldThrow()
    {
        var opts = new MountedSecretOptions { MountPath = "/nonexistent/path/abc123" };
        Assert.Throws<DirectoryNotFoundException>(() => new MountedSecretProvider(opts));
    }

    private static string CreateTempSecret(params (string key, string value)[] entries)
    {
        var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
        Directory.CreateDirectory(dir);
        foreach (var (key, value) in entries)
            File.WriteAllText(Path.Combine(dir, key), value);
        return dir;
    }
}
```

---

### Step 6 — Add factory unit test for new verb

**File to modify:** `test/ReplacerUnitTests/SecretsProviderFactoryTests.cs`

Add a test case:

```csharp
[Fact]
public void WhenMountedSecretOptionsShouldReturnMountedSecretProvider()
{
    var dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
    Directory.CreateDirectory(dir);

    var factory = new SecretsProviderFactory();
    var opts = new MountedSecretOptions { MountPath = dir };
    var provider = factory.GetProvider(opts);

    Assert.IsType<MountedSecretProvider>(provider);
}
```

---

### Step 7 — Add E2E test

**File to create:** `test/ReplacerE2ETests/MountedSecretE2ETests.cs`

```csharp
namespace ReplacerE2ETests;

using System.IO;
using System.Threading.Tasks;
using Utils;
using Xunit;

public class MountedSecretE2ETests
{
    [Fact]
    public async Task TestTokenReplacement()
    {
        // Arrange: create a temp directory acting as a K8s secret mount
        var mountDir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
        Directory.CreateDirectory(mountDir);
        File.WriteAllText(Path.Combine(mountDir, "private-domain"), "PRIVATE_DOMAIN");

        const string inputText = "host: argocd.<secret:private-domain>";
        const string expectedOutput = "host: argocd.PRIVATE_DOMAIN";

        using var consoleOutput = new ConsoleOutput();
        using var consoleInput = ConsoleInput.FromString(inputText);

        var entryPoint = typeof(Program).Assembly.EntryPoint!;
        var options = new[] { "secret", $"--mount={mountDir}" };
        var returnObject = entryPoint.Invoke(null, new object[] { options });
        if (returnObject is Task returnTask)
            await returnTask;

        Assert.Equal(expectedOutput, consoleOutput.GetOutput());

        Directory.Delete(mountDir, true);
    }

    [Fact]
    public async Task TestBase64TokenReplacement()
    {
        var mountDir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName());
        Directory.CreateDirectory(mountDir);
        File.WriteAllText(Path.Combine(mountDir, "my-password"), "hunter2");

        // Base64 of "hunter2" = "aHVudGVyMg=="
        const string inputText = "password: <secret:my-password|base64>";
        const string expectedOutput = "password: aHVudGVyMg==";

        using var consoleOutput = new ConsoleOutput();
        using var consoleInput = ConsoleInput.FromString(inputText);

        var entryPoint = typeof(Program).Assembly.EntryPoint!;
        var options = new[] { "secret", $"--mount={mountDir}" };
        var returnObject = entryPoint.Invoke(null, new object[] { options });
        if (returnObject is Task returnTask)
            await returnTask;

        Assert.Equal(expectedOutput, consoleOutput.GetOutput());

        Directory.Delete(mountDir, true);
    }
}
```

---

## Summary of Files Changed/Created

| Action | File |
|--------|------|
| CREATE | `src/Replacer/SecretsProvider/MountedSecret/MountedSecretOptions.cs` |
| CREATE | `src/Replacer/SecretsProvider/MountedSecret/MountedSecretProvider.cs` |
| MODIFY | `src/Replacer/SecretsProvider/ISecretsProviderFactory.cs` — add `MountedSecretOptions` case |
| MODIFY | `src/Replacer/Program.cs` — add `MountedSecretOptions` to `ParseArguments` |
| CREATE | `test/ReplacerUnitTests/MountedSecret/MountedSecretProviderTests.cs` |
| MODIFY | `test/ReplacerUnitTests/SecretsProviderFactoryTests.cs` — add factory test case |
| CREATE | `test/ReplacerE2ETests/MountedSecretE2ETests.cs` |

Total new/changed code: ~120 lines. No new NuGet dependencies required.

---

## CLI Usage After This Change

```bash
# Existing sops verb — unchanged
helm template ... | argocd-secret-replacer sops -f secret.sec.yaml

# New secret verb — reads from mounted K8s Secret directory
helm template ... | argocd-secret-replacer secret --mount /cluster-secrets
```

---

## What Changes in the home-ops Repo (separate work, after plugin is released)

This is **not** in scope for the plugin PR but documents what the caller side needs:

1. **`cluster/apps/core/argocd/patches/argo-cd-repo-server-ksops-patch.yaml`**
   - Add volume: `cluster-secrets` Secret → mounted at `/cluster-secrets` in both sidecar containers
   - Remove: `sops-age` volume and `SOPS_AGE_KEY_FILE` env var from sidecars

2. **`cluster/apps/core/argocd/resources/sops-replacer-plugin.yaml`**
   - Change both `generate` commands from:
     ```bash
     ... | argocd-secret-replacer sops -f "$ARGOCD_ENV_SOPS_SECRET_FILE"
     ```
     to:
     ```bash
     ... | argocd-secret-replacer secret --mount /cluster-secrets
     ```
   - Change both `discover` commands from checking `ARGOCD_ENV_SOPS_SECRET_FILE` to checking
     `ARGOCD_ENV_SECRET_PROVIDER`:
     ```bash
     [[ ! -z $ARGOCD_ENV_SECRET_PROVIDER ]] && find . -name 'Chart.yaml'
     ```

3. **New file: `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml`**
   - `ExternalSecret` pulling all global secrets from Bitwarden into a `cluster-secrets` K8s Secret
     in the `argocd` namespace. All keys that currently live in per-app `secret.sec.yaml` files
     (e.g. `private-domain`, `oidc-keycloak-clientSecret`, `private-repo-password`, etc.) go here.

4. **Per-app `app-config.yaml` changes**
   - Replace `SOPS_SECRET_FILE: secret.sec.yaml` with `SECRET_PROVIDER: cluster-secrets`
   - For apps with app-specific secrets: those stay as `ExternalSecret` resources (already the
     pattern used by cloudflare-dns, adguard-dns, cloudflared) — no plugin needed for those

5. **Delete all per-app `secret.sec.yaml` files** once all secrets are migrated to Bitwarden
