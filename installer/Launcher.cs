using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("WifiGate Setup")]

static class Launcher
{
    [STAThread]
    static int Main()
    {
        try
        {
            string dir = Path.Combine(Path.GetTempPath(), "WifiGate_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            string zip = Path.Combine(dir, "payload.zip");
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            using (FileStream f = File.Create(zip))
                s.CopyTo(f);
            ZipFile.ExtractToDirectory(zip, dir);
            string script = Path.Combine(dir, "WifiGate", "Install.ps1");
            var psi = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"",
                WorkingDirectory = Path.GetDirectoryName(script),
                UseShellExecute = false
            };
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "WifiGate Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
