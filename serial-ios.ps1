# iOS-style WinForms helpers
if (-not ([System.Management.Automation.PSTypeName]"IosCard").Type) {
    $src = @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
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
}

public class IosCard : Panel {
    public int CornerRadius = 18;
    public IosCard() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.White;
    }
    protected override void OnPaintBackground(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        Color parentBg = Parent != null ? Parent.BackColor : Color.FromArgb(242, 242, 247);
        e.Graphics.Clear(parentBg);
        Rectangle rr = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
        using (GraphicsPath path = IosGfx.RoundRect(rr, CornerRadius))
        using (SolidBrush b = new SolidBrush(BackColor)) {
            e.Graphics.FillPath(b, path);
        }
    }
}

public class IosButton : Button {
    public int CornerRadius = 14;
    public IosButton() {
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Cursor = Cursors.Hand;
        UseVisualStyleBackColor = false;
    }
    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        Color bg = Enabled ? BackColor : Color.FromArgb(210, 210, 215);
        Color fg = Enabled ? ForeColor : Color.FromArgb(142, 142, 147);
        if (Parent != null) e.Graphics.Clear(Parent.BackColor);
        Rectangle rr = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
        using (GraphicsPath path = IosGfx.RoundRect(rr, CornerRadius))
        using (SolidBrush b = new SolidBrush(bg)) {
            e.Graphics.FillPath(b, path);
        }
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, fg,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
}
"@
    Add-Type -TypeDefinition $src -ReferencedAssemblies @("System.Windows.Forms", "System.Drawing")
}

$script:Ui = @{
    Bg      = [System.Drawing.Color]::FromArgb(242, 242, 247)
    Nav     = [System.Drawing.Color]::FromArgb(249, 249, 251)
    Card    = [System.Drawing.Color]::White
    Input   = [System.Drawing.Color]::FromArgb(242, 242, 247)
    Text    = [System.Drawing.Color]::FromArgb(28, 28, 30)
    Muted   = [System.Drawing.Color]::FromArgb(142, 142, 147)
    Accent  = [System.Drawing.Color]::FromArgb(0, 122, 255)
    Ok      = [System.Drawing.Color]::FromArgb(52, 199, 89)
    Danger  = [System.Drawing.Color]::FromArgb(255, 59, 48)
    Seg     = [System.Drawing.Color]::FromArgb(229, 229, 234)
    Border  = [System.Drawing.Color]::FromArgb(209, 209, 214)
    TermBg  = [System.Drawing.Color]::FromArgb(28, 28, 30)
    TermFg  = [System.Drawing.Color]::FromArgb(210, 245, 210)
}

$script:FontUi = New-Object System.Drawing.Font("Segoe UI", 10)
$script:FontUiSm = New-Object System.Drawing.Font("Segoe UI", 8.5)
try {
    $script:FontUiBd = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
    $script:FontTitle = New-Object System.Drawing.Font("Segoe UI Semibold", 20)
} catch {
    $script:FontUiBd = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $script:FontTitle = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
}
$script:FontCaption = New-Object System.Drawing.Font("Segoe UI", 8.5)
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
