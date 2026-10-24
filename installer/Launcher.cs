using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("M3U8 Downloader Launcher")]
[assembly: AssemblyProduct("M3U8 Downloader")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class Launcher
{
    private const string HealthUrl = "http://127.0.0.1:17890/health";
    private const string AppUrl = "http://127.0.0.1:17890/";

    [STAThread]
    private static void Main()
    {
        string appDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        string dataDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "M3U8Downloader", "Data");

        Directory.CreateDirectory(dataDirectory);
        bool healthy = IsHealthy();
        using (var startupMutex = new Mutex(false, @"Local\M3U8Downloader.Startup"))
        {
            bool ownsMutex = false;
            try
            {
                try { ownsMutex = startupMutex.WaitOne(0, false); }
                catch (AbandonedMutexException) { ownsMutex = true; }
                if (!healthy && ownsMutex)
                {
                    StartHelper(appDirectory, dataDirectory);
                }
                if (!healthy) healthy = WaitForHealth(30000);
            }
            finally
            {
                if (ownsMutex) startupMutex.ReleaseMutex();
            }
        }

        if (healthy) OpenEdge(AppUrl);
        else MessageBox.Show(
            "The local helper did not start. Run helper\\start-helper.ps1 to see the error.",
            "M3U8 Downloader", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    private static void StartHelper(string appDirectory, string dataDirectory)
    {
        string helperScript = Path.Combine(appDirectory, "helper", "start-helper.ps1");
        if (!File.Exists(helperScript)) return;

        var startInfo = new ProcessStartInfo
        {
            // HttpListener is provided by Windows PowerShell on supported
            // Windows installs; PowerShell Core may report it unsupported.
            FileName = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe"),
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Quote(helperScript),
            WorkingDirectory = dataDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        startInfo.EnvironmentVariables["M3U8_DOWNLOADER_DATA"] = dataDirectory;
        startInfo.EnvironmentVariables["M3U8_DOWNLOADER_APP"] = appDirectory;
        try { Process.Start(startInfo); } catch { }
    }

    private static bool IsHealthy()
    {
        try
        {
            var request = (HttpWebRequest)WebRequest.Create(HealthUrl);
            request.Method = "GET";
            request.Timeout = 700;
            request.ReadWriteTimeout = 700;
            using (var response = (HttpWebResponse)request.GetResponse())
                return (int)response.StatusCode >= 200 && (int)response.StatusCode < 300;
        }
        catch { return false; }
    }

    private static bool WaitForHealth(int milliseconds)
    {
        int attempts = milliseconds / 250;
        for (int i = 0; i < attempts; i++)
        {
            if (IsHealthy()) return true;
            Thread.Sleep(250);
        }
        return false;
    }

    private static void OpenEdge(string url)
    {
        string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        string[] candidates =
        {
            Path.Combine(programFilesX86, "Microsoft", "Edge", "Application", "msedge.exe"),
            Path.Combine(programFiles, "Microsoft", "Edge", "Application", "msedge.exe")
        };
        foreach (string candidate in candidates)
        {
            if (!File.Exists(candidate)) continue;
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = candidate,
                    Arguments = "--app=" + Quote(url),
                    UseShellExecute = false,
                    WorkingDirectory = Path.GetDirectoryName(candidate)
                });
                return;
            }
            catch { }
        }

        try { Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true }); } catch { }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
