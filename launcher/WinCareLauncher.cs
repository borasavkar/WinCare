// WinCare launcher
// ---------------------------------------------------------------------------
// A tiny native entry point. The embedded manifest asks Windows for
// administrator rights (standard UAC prompt), then this program starts the
// PowerShell/WPF application next to it without showing a console window.
// It contains no maintenance logic: everything lives in src/ and is readable.

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("WinCare")]
[assembly: AssemblyDescription("Windows 11 maintenance and repair using built-in Windows tools")]
[assembly: AssemblyProduct("WinCare")]
[assembly: AssemblyCompany("WinCare contributors")]
[assembly: AssemblyCopyright("Copyright (c) 2026 borasavkar - MIT License")]
[assembly: AssemblyVersion("1.6.1.0")]
[assembly: AssemblyFileVersion("1.6.1.0")]
[assembly: AssemblyInformationalVersion("1.6.1")]

static class Program
{
    [STAThread]
    static int Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "src", "WinCare.ps1");
        string core = Path.Combine(dir, "src", "Core.psm1");
        string lang = Path.Combine(dir, "lang", "en.json");

        if (!File.Exists(script) || !File.Exists(core) || !File.Exists(lang))
        {
            // Double-clicking WinCare.exe inside the ZIP makes Windows copy only
            // the exe to a temporary folder. Say so plainly instead of "files missing".
            bool fromZip = dir.StartsWith(Path.GetTempPath(), StringComparison.OrdinalIgnoreCase);
            bool tr = System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "tr";
            string text;
            if (fromZip && tr)
                text = "WinCare ZIP dosyasının içinden açılmış.\n\n" +
                       "Önce ZIP dosyasına sağ tıklayıp \"Tümünü ayıkla\"yı seçin, " +
                       "sonra çıkardığınız klasördeki WinCare.exe'yi çalıştırın.";
            else if (fromZip)
                text = "WinCare was opened from inside the ZIP file.\n\n" +
                       "Right-click the ZIP file, choose \"Extract All\", then run WinCare.exe from the extracted folder.";
            else if (tr)
                text = "WinCare dosyalarını bulamadı.\n\n" +
                       "WinCare.exe, 'src' ve 'lang' klasörleriyle aynı yerde durmalı.\n\n" +
                       "Bakılan yer: " + dir;
            else
                text = "WinCare could not find its files.\n\n" +
                       "Keep WinCare.exe together with the 'src' and 'lang' folders.\n\n" +
                       "Looked in: " + dir;
            MessageBox.Show(text, "WinCare", MessageBoxButtons.OK,
                            fromZip ? MessageBoxIcon.Information : MessageBoxIcon.Error);
            return 1;
        }

        // Always the built-in Windows PowerShell 5.1 (64-bit on 64-bit Windows).
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                         @"WindowsPowerShell\v1.0\powershell.exe");

        var psi = new ProcessStartInfo(powershell,
            "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;

        try
        {
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("WinCare could not start PowerShell.\n\n" + ex.Message,
                            "WinCare", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
    }
}
