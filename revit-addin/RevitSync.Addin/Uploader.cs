using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RevitSync
{
    public class UploadResult
    {
        public int Revision { get; set; }
        public string[] Changed { get; set; } = Array.Empty<string>();
        public string[] Removed { get; set; } = Array.Empty<string>();
        public string[] Unchanged { get; set; } = Array.Empty<string>();
    }

    public class ServerRejectedException : Exception
    {
        public ServerRejectedException(string message) : base(message) { }
    }

    public static class Uploader
    {
        private static readonly HttpClient Http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        private static readonly JsonSerializerOptions Json = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

        public static UploadResult Push(string serverUrl, string projectId, string projectName, IReadOnlyList<PartitionFile> partitions)
        {
            var entries = new List<object>();
            var content = new MultipartFormDataContent();

            foreach (var partition in partitions)
            {
                var sha = Sha256(partition.Path);
                entries.Add(new { id = partition.Id, name = partition.Name, sha256 = sha, ext = "usda" });

                var head = new HttpRequestMessage(HttpMethod.Head, $"{serverUrl}/api/projects/{projectId}/assets/{sha}.usda");
                if (Http.SendAsync(head).GetAwaiter().GetResult().IsSuccessStatusCode) continue;

                var part = new ByteArrayContent(File.ReadAllBytes(partition.Path));
                part.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("text/plain");
                content.Add(part, partition.Id, partition.Id + ".usda");
            }

            var manifest = JsonSerializer.Serialize(new { name = projectName, partitions = entries });
            content.Add(new StringContent(manifest, Encoding.UTF8, "application/json"), "manifest");

            var response = Http.PostAsync($"{serverUrl}/api/projects/{projectId}/revisions", content).GetAwaiter().GetResult();
            var body = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            if (!response.IsSuccessStatusCode)
            {
                throw new ServerRejectedException($"HTTP {(int)response.StatusCode}: {body}");
            }
            return JsonSerializer.Deserialize<UploadResult>(body, Json);
        }

        private static string Sha256(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(path))
            {
                return string.Concat(sha.ComputeHash(stream).Select(b => b.ToString("x2")));
            }
        }
    }
}
