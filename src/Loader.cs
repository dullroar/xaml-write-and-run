using System;
using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Markup;

// The entire "program" is the XAML file this hands to the parser. Every write, sleep, load, and
// Show() call in the write-then-run chain is declared in launcher.xaml (and in the .xaml files it
// writes and loads at runtime), not here.
//
// This file does three things that are deliberately NOT part of that claim:
//   1. Bootstraps a WPF Application and calls XamlReader.Load, because something has to.
//   2. Clears data/ at the start of each run, so run.log and the generated stages always reflect
//      only the run you just started, not a leftover from a previous one.
//   3. Optionally auto-shuts-down after XWR_AUTO_EXIT_MS milliseconds, purely so an unattended /
//      scripted run (CI, or an agent driving this from a terminal) terminates on its own instead
//      of waiting forever for a human to close the windows the XAML chain pops up.
internal static class Loader
{
    [STAThread]
    private static void Main(string[] args)
    {
        Directory.CreateDirectory("data");
        foreach (var stale in new[] { "data/run.log", "data/stage1.generated.xaml", "data/stage2.generated.xaml" })
        {
            if (File.Exists(stale)) File.Delete(stale);
        }

        var app = new Application();

        if (Environment.GetEnvironmentVariable("XWR_AUTO_EXIT_MS") is string msText
            && int.TryParse(msText, out var delayMs))
        {
            _ = new Timer(_ => app.Dispatcher.Invoke(() => app.Shutdown()), null, delayMs, Timeout.Infinite);
        }

        var path = args.Length > 0 ? args[0] : "launcher.xaml";
        app.Run((Window)XamlReader.Load(File.OpenRead(path)));
    }
}
