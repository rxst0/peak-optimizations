// Peak Optimizations.exe - the installed app's launcher.
// Compiled on the user's PC by Install.ps1 with the app icon and an "administrator" manifest, so Windows shows one
// UAC prompt for "Peak Optimizations" and then the app opens with no console window.
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

static class Program
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBox(IntPtr hwnd, string text, string caption, uint type);

    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "PeakOptimizations.ps1");
        if (!File.Exists(script))
        {
            MessageBox(IntPtr.Zero, "PeakOptimizations.ps1 is missing from:\n" + dir + "\n\nRun the installer again to repair it.", "Peak Optimizations", 0x10);
            return 1;
        }

        string extra = "";
        foreach (string a in args) extra += " \"" + a.Replace("\"", "") + "\"";

        var psi = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
            Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"" + extra,
            WorkingDirectory = dir,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        try { Process.Start(psi); }
        catch (Exception ex)
        {
            MessageBox(IntPtr.Zero, "Could not start Peak Optimizations:\n" + ex.Message, "Peak Optimizations", 0x10);
            return 1;
        }
        return 0;
    }
}
