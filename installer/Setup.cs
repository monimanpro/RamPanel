// RamPanel Setup: unpacks the embedded files into a temporary folder and runs install.ps1 from there.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("RamPanel Setup")]
[assembly: AssemblyProduct("RamPanel — тайминги памяти для AMD Ryzen")]
[assembly: AssemblyDescription("RamPanel installer. Written by Claude (Anthropic) on a fleshy human's initiative.")]
[assembly: AssemblyCompany("Claude (Anthropic)")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.0.0")]

static class Setup
{
    [STAThread]
    static int Main()
    {
        string tmp = Path.Combine(Path.GetTempPath(), "RamPanelSetup_" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(tmp);
            Assembly asm = Assembly.GetExecutingAssembly();
            foreach (string name in asm.GetManifestResourceNames())
            {
                using (Stream s = asm.GetManifestResourceStream(name))
                using (FileStream f = File.Create(Path.Combine(tmp, name)))
                    s.CopyTo(f);
            }
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(tmp, "install.ps1") + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = tmp;
            using (Process p = Process.Start(psi)) { p.WaitForExit(); return p.ExitCode; }
        }
        catch (Exception e)
        {
            MessageBox.Show("Установка не удалась:\r\n" + e.Message, "RamPanel — установка", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            try { Directory.Delete(tmp, true); } catch { }
        }
    }
}
