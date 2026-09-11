# iOS-style WinForms helpers
if (-not ([System.Management.Automation.PSTypeName]"IosChromeForm").Type) {
    $src = @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class IosGfx {
    public static GraphicsPath RoundRect(Rectangle r, int radius) {
        int d = Math.Max(2, radius * 2);
        if (r.Width < 2 || r.Height < 2) {
            var empty = new GraphicsPath();
            empty.AddRectangle(r);
            return empty;
        }
        if (d > r.Width) d = r.Width;
        if (d > r.Height) d = r.Height;
        var p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    public static LinearGradientBrush Rainbow(Rectangle r) {
        if (r.Width < 2) r.Width = 2;
        var br = new LinearGradientBrush(r, Color.Magenta, Color.Red, 0f);
        var cb = new ColorBlend();
        cb.Colors = new Color[] {
            Color.FromArgb(255, 92, 168),
            Color.FromArgb(255, 176, 72),
            Color.FromArgb(120, 214, 96),
            Color.FromArgb(64, 196, 224),
            Color.FromArgb(120, 124, 255),
            Color.FromArgb(255, 92, 168)
        };
        cb.Positions = new float[] { 0f, 0.22f, 0.42f, 0.62f, 0.82f, 1f };
        br.InterpolationColors = cb;
        return br;
    }
}

public static class IosNative {
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWA_BORDER_COLOR = 34;
    public const int DWMWA_CAPTION_COLOR = 35;
    public const int DWMWCP_ROUND = 2;
    public const int WM_NCHITTEST = 0x84;
    public const int WM_NCLBUTTONDOWN = 0xA1;
    public const int HTCLIENT = 1;
    public const int HTCAPTION = 2;
    public const int HTLEFT = 10;
    public const int HTRIGHT = 11;
    public const int HTTOP = 12;
    public const int HTTOPLEFT = 13;
    public const int HTTOPRIGHT = 14;
    public const int HTBOTTOM = 15;
    public const int HTBOTTOMLEFT = 16;
    public const int HTBOTTOMRIGHT = 17;
    public const int CS_DROPSHADOW = 0x20000;

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int w, int h);
    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr h);
    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();
    [DllImport("user32.dll")]
    public static extern int SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);

    public static void ApplyChrome(IntPtr hwnd, int captionColor, int borderColor) {
        int pref = DWMWCP_ROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref pref, 4);
        int cap = captionColor;
        DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, ref cap, 4);
        int bor = borderColor;
        DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref bor, 4);
    }

    public static void DragWindow(IntPtr hwnd) {
        ReleaseCapture();
        SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    }
}

public class IosChromeForm : Form {
    public IosChromeForm() {
        FormBorderStyle = FormBorderStyle.Sizable;
        StartPosition = FormStartPosition.CenterScreen;
        DoubleBuffered = true;
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        int cap = ColorTranslator.ToWin32(Color.White);
        int bor = ColorTranslator.ToWin32(Color.FromArgb(228, 228, 231));
        IosNative.ApplyChrome(Handle, cap, bor);
        this.Region = null;
    }
}

public class IosCard : Panel {
    public int CornerRadius = 16;
    public Color LineColor = Color.FromArgb(232, 232, 237);
    public IosCard() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.White;
    }
    protected override void OnPaintBackground(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        Color parentBg = Parent != null ? Parent.BackColor : Color.FromArgb(247, 247, 248);
        e.Graphics.Clear(parentBg);
        Rectangle rr = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
        using (GraphicsPath path = IosGfx.RoundRect(rr, CornerRadius))
        using (SolidBrush b = new SolidBrush(BackColor))
        using (Pen pen = new Pen(LineColor)) {
            e.Graphics.FillPath(b, path);
            e.Graphics.DrawPath(pen, path);
        }
    }
}

public class IosButton : Button {
    public int CornerRadius = 14;
    public bool RainbowBorder = false;
    bool _hover, _down;
    public IosButton() {
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Cursor = Cursors.Hand;
        UseVisualStyleBackColor = false;
    }
    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; _down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { _down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        Color bg = Enabled ? BackColor : Color.FromArgb(210, 210, 215);
        Color fg = Enabled ? ForeColor : Color.FromArgb(142, 142, 147);
        if (Enabled && (_hover || _down)) {
            int k = _down ? 22 : 12;
            bg = Color.FromArgb(Math.Max(0, bg.R - k), Math.Max(0, bg.G - k), Math.Max(0, bg.B - k));
        }
        if (Parent != null) e.Graphics.Clear(Parent.BackColor);
        Rectangle rr = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
        using (GraphicsPath path = IosGfx.RoundRect(rr, CornerRadius))
        using (SolidBrush b = new SolidBrush(bg)) {
            e.Graphics.FillPath(b, path);
            if (RainbowBorder) {
                using (LinearGradientBrush rb = IosGfx.Rainbow(rr))
                using (Pen pen = new Pen(rb, 2.4f)) {
                    e.Graphics.DrawPath(pen, path);
                }
            }
        }
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, fg,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
}

public class IosTraffic : Control {
    public Color DotColor = Color.Silver;
    public string Symbol = "";
    bool _hover;
    public IosTraffic() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Size = new Size(18, 18);
        Cursor = Cursors.Hand;
    }
    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        if (Parent != null) e.Graphics.Clear(Parent.BackColor);
        int s = Math.Min(Width, Height) - 2;
        int x = (Width - s) / 2, y = (Height - s) / 2;
        Color c = _hover ? Color.FromArgb(Math.Max(0, DotColor.R - 18), Math.Max(0, DotColor.G - 18), Math.Max(0, DotColor.B - 18)) : DotColor;
        using (SolidBrush b = new SolidBrush(c)) e.Graphics.FillEllipse(b, x, y, s, s);
        if (_hover && !string.IsNullOrEmpty(Symbol)) {
            using (Font f = new Font("Segoe UI", 6.5f, FontStyle.Bold))
            using (SolidBrush tb = new SolidBrush(Color.FromArgb(70, 40, 20))) {
                TextRenderer.DrawText(e.Graphics, Symbol, f, ClientRectangle, tb.Color,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }
    }
}

public class IosProgress : Panel {
    double _value;
    public Color FillColor = Color.FromArgb(24, 24, 27);
    public double Progress {
        get { return _value; }
        set { _value = Math.Max(0, Math.Min(1, value)); Invalidate(); }
    }
    public IosProgress() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Height = 8;
        BackColor = Color.FromArgb(229, 229, 234);
    }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        if (Parent != null) e.Graphics.Clear(Parent.BackColor);
        Rectangle track = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
        int radius = Math.Max(2, Height / 2);
        using (GraphicsPath tp = IosGfx.RoundRect(track, radius))
        using (SolidBrush tb = new SolidBrush(BackColor)) {
            e.Graphics.FillPath(tb, tp);
        }
        int fw = (int)Math.Round((Width - 1) * _value);
        if (fw > 2) {
            Rectangle fr = new Rectangle(0, 0, fw, Math.Max(1, Height - 1));
            using (GraphicsPath fp = IosGfx.RoundRect(fr, radius))
            using (SolidBrush fb = new SolidBrush(FillColor)) {
                e.Graphics.FillPath(fb, fp);
            }
        }
    }
}
"@
    Add-Type -TypeDefinition $src -ReferencedAssemblies @("System.Windows.Forms", "System.Drawing")
}

$script:Ui = @{
    Bg      = [System.Drawing.Color]::FromArgb(247, 247, 248)
    Nav     = [System.Drawing.Color]::White
    Card    = [System.Drawing.Color]::White
    Input   = [System.Drawing.Color]::FromArgb(237, 237, 238)
    Text    = [System.Drawing.Color]::FromArgb(24, 24, 27)
    Muted   = [System.Drawing.Color]::FromArgb(113, 113, 122)
    Accent  = [System.Drawing.Color]::FromArgb(24, 24, 27)
    Ink     = [System.Drawing.Color]::FromArgb(24, 24, 27)
    Ok      = [System.Drawing.Color]::FromArgb(34, 197, 94)
    Danger  = [System.Drawing.Color]::FromArgb(239, 68, 68)
    Seg     = [System.Drawing.Color]::FromArgb(237, 237, 238)
    Border  = [System.Drawing.Color]::FromArgb(237, 237, 238)
    TermBg  = [System.Drawing.Color]::FromArgb(24, 24, 27)
    TermFg  = [System.Drawing.Color]::FromArgb(228, 228, 231)
    Close   = [System.Drawing.Color]::FromArgb(255, 95, 87)
    Min     = [System.Drawing.Color]::FromArgb(255, 189, 46)
    Max     = [System.Drawing.Color]::FromArgb(40, 200, 64)
}

$script:FontUi = New-Object System.Drawing.Font("Segoe UI", 10)
$script:FontUiSm = New-Object System.Drawing.Font("Segoe UI", 8.5)
try {
    $script:FontUiBd = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
    $script:FontTitle = New-Object System.Drawing.Font("Segoe UI Semibold", 13)
} catch {
    $script:FontUiBd = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:FontTitle = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
}
$script:FontCaption = New-Object System.Drawing.Font("Segoe UI", 8.25)
$script:FontMono = New-Object System.Drawing.Font("Consolas", 10.5)

function Add-L([System.Windows.Forms.Control]$parent, [string]$t, [int]$x, [int]$y, [int]$w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $t
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.AutoSize = $false
    $l.Size = New-Object System.Drawing.Size($w, 20)
    $l.ForeColor = $script:Ui.Muted
    $l.Font = $script:FontCaption
    $l.BackColor = [System.Drawing.Color]::Transparent
    $parent.Controls.Add($l)
    return $l
}

function Add-Box([System.Windows.Forms.Control]$parent, [int]$x, [int]$y, [int]$w) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, 30)
    $t.BackColor = $script:Ui.Input
    $t.ForeColor = $script:Ui.Text
    $t.BorderStyle = "None"
    $t.Font = $script:FontUi
    $parent.Controls.Add($t)
    return $t
}

function Add-Btn([System.Windows.Forms.Control]$parent, [string]$t, [int]$x, [int]$y, [int]$w, [int]$h, $bg, $fg) {
    $b = New-Object IosButton
    $b.Text = $t
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.BackColor = $bg
    $b.ForeColor = $fg
    $b.Font = $script:FontUiBd
    $b.CornerRadius = [Math]::Min(16, [int]($h / 2))
    $parent.Controls.Add($b)
    return $b
}

function New-UiCombo([System.Windows.Forms.Control]$parent) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.FlatStyle = "Flat"
    $c.BackColor = $script:Ui.Input
    $c.ForeColor = $script:Ui.Text
    $c.Font = $script:FontUi
    $parent.Controls.Add($c)
    return $c
}

function New-Card([System.Windows.Forms.Control]$parent) {
    $p = New-Object IosCard
    $p.BackColor = $script:Ui.Card
    $p.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
    $parent.Controls.Add($p)
    return $p
}

function New-Field([System.Windows.Forms.Control]$parent, [int]$x, [int]$y, [int]$w, [int]$h) {
    $p = New-Object IosCard
    $p.CornerRadius = 10
    $p.BackColor = $script:Ui.Input
    $p.LineColor = $script:Ui.Input
    $p.Location = New-Object System.Drawing.Point($x, $y)
    $p.Size = New-Object System.Drawing.Size($w, $h)
    $p.Padding = New-Object System.Windows.Forms.Padding(10, 6, 8, 4)
    $parent.Controls.Add($p)
    return $p
}

function Enable-IosDrag([System.Windows.Forms.Control]$ctrl) {
    $ctrl.Add_MouseDown({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $script:IosMainForm) {
            [IosNative]::DragWindow($script:IosMainForm.Handle)
        }
    })
}
