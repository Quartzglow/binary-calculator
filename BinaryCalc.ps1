#Requires -Version 5.1
<#
================================================================================
  B I N A R Y   C A L C U L A T O R
  Калькулятор с пошаговой визуализацией вычислений в двоичной системе.

  ЗАПУСК:
      .\BinaryCalc.cmd                     (двойной клик / из cmd)
      powershell -ExecutionPolicy Bypass -File .\BinaryCalc.ps1
      pwsh -File .\BinaryCalc.ps1          (если есть PowerShell 7)

  ЧТО ВВОДИТЬ:
      2+5                 десятичные числа
      0b1011*0b110        двоичные  (префикс 0b)
      0xFF-0b1            шестнадцатеричные (префикс 0x)
      255/7               деление со столбиком
      00101001+00101110   тоже поймётся как двоичные (ведущий ноль)

  СЛОЖНЫЕ ВЫРАЖЕНИЯ (сразу несколько операций):
      2+2*2-2+2           приоритеты как в математике: × и ÷ раньше + и −
      (2+3)*4              скобки
      100/(2+3)-0b1010    можно смешивать десятичные, двоичные и hex
      -(5+5)*2             унарный минус
      Для таких выражений калькулятор показывает план вычисления:
      какой шаг идёт первым, а затем анимирует КАЖДУЮ операцию по очереди.

  ОПЕРАЦИИ:  +  -  *  /   (можно x, ×, ÷),  скобки ( )
  ВЫХОД:     q | exit | выход

  ПАРАМЕТРЫ:
      -Delay 60      пауза между шагами анимации, мс (0 = без пауз)
      -Demo          показать демонстрацию и выйти
      -Expression    посчитать одно выражение и выйти
      -ForceAnim     рисовать анимацию даже при перенаправленном выводе
================================================================================
#>

[CmdletBinding()]
param(
    [int]$Delay = 60,
    [switch]$Demo,
    [switch]$ForceAnim,
    [string]$Expression
)

$ErrorActionPreference = 'Stop'

# =============================== ОКРУЖЕНИЕ ===================================
try { Add-Type -AssemblyName System.Numerics -ErrorAction SilentlyContinue | Out-Null } catch { }
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

$E = [char]27

$P = @{
    R    = "$E[0m"
    B    = "$E[1m"
    Dim  = "$E[38;2;92;104;128m"
    Gray = "$E[38;2;146;158;180m"
    Cyan = "$E[38;2;86;222;255m"
    Blue = "$E[38;2;118;156;255m"
    Mag  = "$E[38;2;255;112;228m"
    Pink = "$E[38;2;255;150;190m"
    Grn  = "$E[38;2;124;255;168m"
    Amb  = "$E[38;2;255;206;92m"
    Red  = "$E[38;2;255;104;120m"
    Wht  = "$E[38;2;236;240;255m"
    BgHi = "$E[48;2;36;54;96m"
    BgRes= "$E[48;2;22;74;54m"
    BgCar= "$E[48;2;84;58;18m"
    BgErr= "$E[48;2;74;22;30m"
}

$script:Interactive = $true
$script:OutputRedirected = $false
try {
    $script:OutputRedirected = [Console]::IsOutputRedirected
    if ($script:OutputRedirected) { $script:Interactive = $false }
} catch { $script:Interactive = $false }
if ($ForceAnim) { $script:Interactive = $true }

# ---- поддержка ANSI/VT: включаем, если консоль это умеет ----
$script:Vt = $true
try {
    if ($null -ne $Host.UI.SupportsVirtualTerminal) {
        if (-not $Host.UI.SupportsVirtualTerminal) { $script:Vt = $false }
    }
} catch { }
if ($script:Vt -and -not $script:OutputRedirected) {
    try {
        if (-not ('Win32.ConsoleVT' -as [type])) {
            Add-Type -Namespace Win32 -Name ConsoleVT -ErrorAction Stop -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
        }
        $hOut = [Win32.ConsoleVT]::GetStdHandle(-11)
        $mode = [uint32]0
        if ([Win32.ConsoleVT]::GetConsoleMode($hOut, [ref]$mode)) {
            [void][Win32.ConsoleVT]::SetConsoleMode($hOut, ($mode -bor 0x0004))
            $mode2 = [uint32]0
            if ([Win32.ConsoleVT]::GetConsoleMode($hOut, [ref]$mode2)) {
                if (($mode2 -band 0x0004) -eq 0) { $script:Vt = $false }
            }
            else { $script:Vt = $false }
        }
        else {
            $script:Vt = $false
        }
    }
    catch { $script:Vt = $false }
}

# без VT цвета не рисуем и анимацию не гоняем (иначе будут видны ESC-последовательности)
if (-not $script:Vt) {
    foreach ($key in @($P.Keys)) { $P[$key] = '' }
    if (-not $ForceAnim) { $script:Interactive = $false }
}

$script:DelayMs = [Math]::Max(0, $Delay)
$script:Cols = 100
try {
    $cw = [Console]::WindowWidth
    if ($cw -gt 30) { $script:Cols = [Math]::Min($cw, 132) }
} catch { }
$script:PrevLines = 0

# =============================== УТИЛИТЫ ====================================
function W([string]$s)  { Write-Host -NoNewline $s }
function WL([string]$s = '') { Write-Host $s }
function Paint([string]$col, [string]$txt) { return ($col + $txt + $P.R) }
function Rep([string]$s, [int]$n) { if ($n -le 0) { return '' } return ($s * $n) }

function Get-VisLen([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return 0 }
    return ($s -replace ($E + '\[[0-9;]*m'), '').Length
}

# дополняет строку пробелами до нужной ВИДИМОЙ ширины (ANSI не считается)
function Pad-Ansi([string]$s, [int]$width) {
    $v = Get-VisLen $s
    if ($v -ge $width) { return $s }
    return ($s + (' ' * ($width - $v)))
}

# ускоряем анимацию для длинных чисел, чтобы не ждать минуту
$script:SpeedFactor = 1.0
$script:SpeedSave = 1.0

function Push-Speed([int]$size) {
    $script:SpeedSave = $script:SpeedFactor
    if ($size -gt 28) { $script:SpeedFactor = 28.0 / $size }
}

function Pop-Speed { $script:SpeedFactor = $script:SpeedSave }

function Wait-Bit([int]$mult = 1) {
    if ($script:DelayMs -le 0 -or -not $script:Interactive) { return }
    $ms = [int]($script:DelayMs * $mult * $script:SpeedFactor)
    Start-Sleep -Milliseconds ([Math]::Max(1, $ms))
}

function Clear-Screen {
    if (-not $script:Interactive) { return }
    try { [Console]::Clear() } catch { }
    if ($script:Vt) { Write-Host -NoNewline ($E + '[2J' + $E + '[H') }
}

# Рисуем «живой» блок: при следующем вызове старый блок стирается и заменяется.
function Draw([string[]]$Lines, [switch]$Final) {
    $show = $script:Interactive -or $Final
    if (-not $show) { return }
    if ($script:Interactive -and $script:PrevLines -gt 0) {
        Write-Host -NoNewline ($E + '[' + $script:PrevLines + 'A')
    }
    foreach ($l in $Lines) {
        Write-Host -NoNewline ($E + '[2K' + $l + "`n")
    }
    if ($script:Interactive) { $script:PrevLines = $Lines.Count } else { $script:PrevLines = 0 }
}

function End-Block {
    $script:PrevLines = 0
    WL ''
}

function Get-PanelLines {
    param(
        [string[]]$Lines,
        [string]$Title = '',
        [string]$Border = ''
    )
    if ([string]::IsNullOrEmpty($Border)) { $Border = $P.Cyan }
    $inner = 0
    foreach ($l in $Lines) {
        $v = Get-VisLen $l
        if ($v -gt $inner) { $inner = $v }
    }
    $tl = Get-VisLen $Title
    if (($tl + 2) -gt $inner) { $inner = $tl + 2 }
    $pad = '  '
    $out = @()
    if ($Title -ne '') {
        $fill = $inner - $tl - 1
        if ($fill -lt 0) { $fill = 0 }
        $out += ($pad + $Border + '╭─ ' + $P.Wht + $Title + $P.R + $Border + ' ' + (Rep '─' $fill) + '╮' + $P.R)
    }
    else {
        $out += ($pad + $Border + '╭' + (Rep '─' ($inner + 2)) + '╮' + $P.R)
    }
    foreach ($l in $Lines) {
        $v = Get-VisLen $l
        $out += ($pad + $Border + '│' + $P.R + ' ' + $l + (Rep ' ' ($inner - $v)) + ' ' + $Border + '│' + $P.R)
    }
    $out += ($pad + $Border + '╰' + (Rep '─' ($inner + 2)) + '╯' + $P.R)
    return $out
}

function Show-Panel {
    param(
        [string[]]$Lines,
        [string]$Title = '',
        [string]$Border = ''
    )
    $panel = Get-PanelLines -Lines $Lines -Title $Title -Border $Border
    foreach ($l in $panel) { WL $l }
    WL ''
}

# ============================ ДВОИЧНАЯ АРИФМЕТИКА ===========================
function To-Big([string]$dec) { return [System.Numerics.BigInteger]::Parse($dec) }

function ToBinStr([System.Numerics.BigInteger]$n) {
    if ($n.Sign -eq 0) { return '0' }
    if ($n.Sign -lt 0) { return ('-' + (ToBinStr ([System.Numerics.BigInteger]::Negate($n)))) }
    $two = [System.Numerics.BigInteger]::Parse('2')
    $rem = [System.Numerics.BigInteger]::Zero
    $list = New-Object 'System.Collections.Generic.List[char]'
    while ($n.Sign -gt 0) {
        $q = [System.Numerics.BigInteger]::DivRem($n, $two, [ref]$rem)
        $list.Add([char](48 + [int]$rem))
        $n = $q
    }
    $arr = $list.ToArray()
    [array]::Reverse($arr)
    return (-join $arr)
}

function BinToBig([string]$s) {
    $n = [System.Numerics.BigInteger]::Zero
    $two = [System.Numerics.BigInteger]::Parse('2')
    foreach ($ch in $s.ToCharArray()) {
        $n = $n * $two + ([int]$ch - 48)
    }
    return $n
}

function Trim-Bin([string]$s) {
    $t = $s.TrimStart('0')
    if ($t -eq '') { return '0' }
    return $t
}

function Format-Bin([string]$bin) {
    $b = Trim-Bin $bin
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $i = $b.Length
    while ($i -gt 0) {
        $take = 4
        if ($i -lt 4) { $take = $i }
        $parts.Insert(0, $b.Substring($i - $take, $take))
        $i -= $take
    }
    return ($parts -join ' ')
}

function Format-Dec([System.Numerics.BigInteger]$n) {
    $s = $n.ToString()
    $neg = $false
    if ($s.StartsWith('-')) { $neg = $true; $s = $s.Substring(1) }
    $out = ''
    $c = 0
    for ($i = $s.Length - 1; $i -ge 0; $i--) {
        $out = $s[$i] + $out
        $c++
        if ($c % 3 -eq 0 -and $i -gt 0) { $out = ' ' + $out }
    }
    if ($neg) { return '-' + $out }
    return $out
}

# Сложение произвольного числа строк — по столбцам, с переносами.
function Get-AddInfo([string[]]$Rows) {
    $n = 0
    foreach ($r in $Rows) { if ($r.Length -gt $n) { $n = $r.Length } }
    $padded = @()
    foreach ($r in $Rows) { $padded += $r.PadLeft($n, '0') }
    $carry = 0
    $res = [char[]](' ' * $n)
    $steps = @()
    for ($i = $n - 1; $i -ge 0; $i--) {
        $bits = @()
        $sum = 0
        foreach ($r in $padded) {
            $b = [int]$r[$i] - 48
            $bits += $b
            $sum += $b
        }
        $cin = $carry
        $sum = $sum + $cin
        $bit = $sum % 2
        $carry = [int][Math]::Floor($sum / 2)
        $res[$i] = [char](48 + $bit)
        $steps += [pscustomobject]@{
            Col = $i; Bits = $bits; CarryIn = $cin; Total = $sum; Bit = $bit; CarryOut = $carry
        }
    }
    $extra = ''
    if ($carry -gt 0) { $extra = ToBinStr ([System.Numerics.BigInteger]$carry) }
    $resStr = -join $res
    return [pscustomobject]@{
        Rows       = $padded
        OrigWidth  = $n
        Result     = ($extra + $resStr)
        Steps      = $steps
        Extra      = $extra.Length
        FinalCarry = $carry
    }
}

# Вычитание столбиком (A >= B).
function Get-SubInfo([string]$A, [string]$B) {
    $n = [Math]::Max($A.Length, $B.Length)
    $a = $A.PadLeft($n, '0')
    $b = $B.PadLeft($n, '0')
    $res = [char[]](' ' * $n)
    $borrow = 0
    $steps = @()
    for ($i = $n - 1; $i -ge 0; $i--) {
        $ba = [int]$a[$i] - 48
        $bb = [int]$b[$i] - 48
        $bin_ = $borrow
        $d = $ba - $bb - $borrow
        if ($d -lt 0) { $d += 2; $bout = 1 } else { $bout = 0 }
        $res[$i] = [char](48 + $d)
        $steps += [pscustomobject]@{
            Col = $i; A = $ba; B = $bb; BorrowIn = $bin_; Diff = $d; BorrowOut = $bout
        }
        $borrow = $bout
    }
    $raw = -join $res
    return [pscustomobject]@{
        A       = $a
        B       = $b
        Width   = $n
        Raw     = $raw
        Result  = (Trim-Bin $raw)
        Steps   = $steps
    }
}

# Частичные произведения для умножения: массив строк (двоичных), выровненных вправо.
function Get-Partials([string]$a, [string]$b) {
    $rows = @()
    $info = @()
    $bTrim = Trim-Bin $b
    $total = $a.Length + $bTrim.Length
    for ($i = $bTrim.Length - 1; $i -ge 0; $i--) {
        $mbit = [int]$bTrim[$i] - 48
        $pos = $bTrim.Length - 1 - $i
        if ($mbit -eq 1) {
            $val = $a + (Rep '0' $pos)
        }
        else {
            $val = '0'
        }
        $rows += $val
        $info += [pscustomobject]@{
            MultiplierBit = $mbit
            Position      = $pos
            Value         = $val
        }
    }
    # приводим все строки к одной ширине
    $w = 0
    foreach ($r in $rows) { if ($r.Length -gt $w) { $w = $r.Length } }
    $padded = @()
    foreach ($r in $rows) { $padded += $r.PadLeft($w, '0') }
    for ($k = 0; $k -lt $info.Count; $k++) { $info[$k].Value = $padded[$k] }
    return [pscustomobject]@{
        Rows     = $padded
        Info     = $info
        Width    = $w
    }
}

# ================================ БАННЕР ====================================
function Get-BannerLines {
    $g = [ordered]@{}
    $g['B'] = @('██████╗', '██╔══██╗', '██████╔╝', '██╔══██╗', '██████╔╝', '╚═════╝')
    $g['I'] = @('██╗', '██║', '██║', '██║', '██║', '╚═╝')
    $g['N'] = @('███╗   ██╗', '████╗  ██║', '██╔██╗ ██║', '██║╚██╗██║', '██║ ╚████║', '╚═╝  ╚═══╝')
    $g['A'] = @(' █████╗', '██╔══██╗', '███████║', '██╔══██║', '██║  ██║', '╚═╝  ╚═╝')
    $g['R'] = @('██████╗', '██╔══██╗', '██████╔╝', '██╔══██╗', '██║  ██║', '╚═╝  ╚═╝')
    $g['Y'] = @('██╗   ██╗', '╚██╗ ██╔╝', ' ╚████╔╝', '  ╚██╔╝', '   ██║', '   ╚═╝')
    $widths = @{}
    foreach ($k in $g.Keys) {
        $mw = 0
        foreach ($row in $g[$k]) { if ($row.Length -gt $mw) { $mw = $row.Length } }
        $widths[$k] = $mw
    }
    $lines = @('', '', '', '', '', '')
    foreach ($k in 'B', 'I', 'N', 'A', 'R', 'Y') {
        $w = $widths[$k]
        for ($r = 0; $r -lt 6; $r++) {
            $lines[$r] += $g[$k][$r].PadRight($w, ' ')
        }
    }
    return $lines
}

function Get-GradientColor([int]$i, [int]$total) {
    if (-not $script:Vt) { return '' }
    $t = 0.0
    if ($total -gt 1) { $t = $i / ($total - 1.0) }
    $r1 = 70;  $g1 = 200; $b1 = 255
    $r2 = 255; $g2 = 96;  $b2 = 226
    $r = [int]($r1 + ($r2 - $r1) * $t)
    $g = [int]($g1 + ($g2 - $g1) * $t)
    $b = [int]($b1 + ($b2 - $b1) * $t)
    return "$E[38;2;$r;$g;${b}m"
}

function Show-Banner {
    Clear-Screen
    try { $Host.UI.RawUI.WindowTitle = 'BINARY CALCULATOR — пошаговые вычисления' } catch { }
    $banner = Get-BannerLines
    $title = 'Binary Calculator'
    $ascii = 'BINARY CALCULATOR'
    $artW = 0
    foreach ($l in $banner) { if ($l.TrimEnd().Length -gt $artW) { $artW = $l.TrimEnd().Length } }
    $indent = [Math]::Max(2, [int](($script:Cols - $artW) / 2))

    if ($script:Cols -lt ($artW + 6)) {
        # узкий терминал — простая шапка
        WL ''
        WL ($P.Cyan + $P.B + ('═' * [Math]::Max(10, $script:Cols - 4)) + $P.R)
        $pad = [Math]::Max(0, [int](($script:Cols - $ascii.Length) / 2))
        WL ((Rep ' ' $pad) + $P.Cyan + $P.B + $ascii + $P.R)
        WL ($P.Cyan + $P.B + ('═' * [Math]::Max(10, $script:Cols - 4)) + $P.R)
        WL ''
        return
    }

    WL ''
    for ($r = 0; $r -lt 6; $r++) {
        $col = Get-GradientColor $r 6
        WL ((Rep ' ' $indent) + $col + $banner[$r].TrimEnd() + $P.R)
        if ($script:Interactive) { Start-Sleep -Milliseconds 45 }
    }
    $sub = '· двоичный калькулятор · вычисления по шагам ·'
    $pad2 = [Math]::Max(0, [int](($script:Cols - $sub.Length) / 2))
    WL ''
    WL ((Rep ' ' $pad2) + $P.Gray + $sub + $P.R)
    WL ''
}

function Show-Hints {
    $s = '    ·  '
    $g = $P.Gray + $s + $P.R
    $lines = @(
        ($P.Cyan + '2+5' + $P.R + $g + $P.Cyan + '2+2*2-2+2' + $P.R + $g + $P.Cyan + '(2+3)*4' + $P.R + $g + $P.Cyan + '0b1011*0b110' + $P.R + $g + $P.Cyan + '255/7' + $P.R + $g + $P.Cyan + 'q' + $P.R + $P.Gray + ' — выход' + $P.R),
        ($P.Dim + 'можно смешивать основания и скобки:  ' + $P.R + $P.Gray + '0b1010 + 2*0xFF' + $P.R + $P.Dim + '   ·   ' + $P.R + $P.Gray + '100/(2+3)' + $P.R + $P.Dim + '   ·   ' + $P.R + $P.Gray + '-(5+5)*2' + $P.R)
    )
    Show-Panel -Lines $lines -Title 'ВВЕДИ ВЫРАЖЕНИЕ' -Border $P.Dim
    WL ''
}

function Show-Bye {
    WL ''
    Show-Panel -Lines @($P.Gray + 'до встречи. биты всегда рядом.' + $P.R) -Border $P.Dim
    WL ''
}

# ============================= ВЫВОД ЧИСЛА ==================================
function Show-NumberCard($num, [string]$label, [string]$color) {
    $bin = Trim-Bin $num.Bin
    $dec = Format-Dec $num.Value
    $kindText = 'десятичное'
    if ($num.Kind -eq 'bin') { $kindText = 'двоичное' }
    if ($num.Kind -eq 'hex') { $kindText = 'шестнадцатеричное' }

    WL ''
    WL ('  ' + $color + $P.B + $label + $P.R + $color + '  ' + $num.Raw + $P.R + $P.Dim + '   (' + $kindText + ')' + $P.R)

    if ($num.Kind -eq 'dec' -and $num.Value.Sign -gt 0 -and $bin.Length -le 20) {
        # деление на 2 столбиком
        $n = $num.Value
        $two = [System.Numerics.BigInteger]::Parse('2')
        $rem = [System.Numerics.BigInteger]::Zero
        $table = @()
        $digits = @()
        $work = $n
        while ($work.Sign -gt 0) {
            $q = [System.Numerics.BigInteger]::DivRem($work, $two, [ref]$rem)
            $table += [pscustomobject]@{ From = $work; To = $q; Rem = [int]$rem }
            $digits = @([string][int]$rem) + $digits
            $work = $q
        }
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $lines.Add($P.Dim + 'делим на 2, остатки записываем:' + $P.R)
        $idx = 0
        Push-Speed ($table.Count * 3)
        foreach ($row in $table) {
            $lines.Add('  ' + $P.Wht + (Format-Dec $row.From).PadLeft(8) + $P.R + $P.Dim + ' / 2 = ' + $P.R +
                $P.Wht + (Format-Dec $row.To).PadLeft(8) + $P.R + $P.Dim + '  ост. ' + $P.R +
                $P.Amb + $row.Rem + $P.R)
            $idx++
            Draw $lines.ToArray()
            Wait-Bit 1
        }
        Pop-Speed
        $lines.Add($P.Dim + 'читаем остатки СНИЗУ ВВЕРХ → ' + $P.R + $color + $P.B + (-join $digits) + '₂' + $P.R)
        Draw $lines.ToArray() -Final
        End-Block
    }
    elseif ($num.Kind -eq 'bin' -or $num.Kind -eq 'hex') {
        if ($bin.Length -le 24 -and $bin -ne '0') {
            $terms = @()
            $powers = @()
            $sum = [System.Numerics.BigInteger]::Zero
            for ($i = 0; $i -lt $bin.Length; $i++) {
                $bit = [int]$bin[$i] - 48
                $pw = $bin.Length - 1 - $i
                $val = [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]::Parse('2'), $pw)
                if ($bit -eq 1) { $sum = $sum + $val }
                $sup = ''
                if ($pw -eq 0) { $sup = '⁰' }
                elseif ($pw -eq 1) { $sup = '¹' }
                elseif ($pw -eq 2) { $sup = '²' }
                elseif ($pw -eq 3) { $sup = '³' }
                else { $sup = '^' + $pw }
                $cbit = $P.Dim; $cval = $P.Dim
                if ($bit -eq 1) { $cbit = $color; $cval = $P.Wht }
                $terms += ($cbit + $bit + $P.R + $P.Dim + '·2' + $sup + $P.R)
                if ($bit -eq 1) {
                    $powers += ($cval + (Format-Dec $val) + $P.R)
                }
                else {
                    $powers += ($P.Dim + '0' + $P.R)
                }
            }
            $line1 = '  ' + ($terms -join ($P.Dim + ' + ' + $P.R)) + $P.Dim + '  =  ' + $P.R + ($powers -join ($P.Dim + ' + ' + $P.R))
            $line2 = '  ' + $P.Dim + 'итого: ' + $P.R + $color + $P.B + (Format-Dec $sum) + $P.R + $P.Dim + '₁₀  =  ' + $P.R + $color + (Format-Bin $bin) + '₂' + $P.R
            WL $line1
            Wait-Bit 2
            WL $line2
        }
        else {
            WL ('  ' + $P.Dim + '→ ' + $P.R + $color + (Format-Bin $bin) + '₂' + $P.R + $P.Dim + '  =  ' + $P.R + $P.Wht + (Format-Dec $num.Value) + '₁₀' + $P.R)
        }
    }
    else {
        WL ('  ' + $P.Dim + '→ ' + $P.R + $color + (Format-Bin $bin) + '₂' + $P.R + $P.Dim + '  =  ' + $P.R + $P.Wht + (Format-Dec $num.Value) + '₁₀' + $P.R)
    }
}

# ======================== АНИМАЦИЯ: СЛОЖЕНИЕ СТОЛБИКОМ ======================
function Show-Sum {
    param(
        [string[]]$Rows,
        [string[]]$Ops,
        [string]$Title = 'СЛОЖЕНИЕ',
        [string[]]$RowColors
    )
    $info = Get-AddInfo $Rows
    $w = $info.Result.Length
    $off = $info.Extra
    $rowCount = $info.Rows.Count

    if (-not $RowColors) {
        $RowColors = @()
        for ($i = 0; $i -lt $rowCount; $i++) {
            if ($i -eq 0) { $RowColors += $P.Cyan }
            elseif ($i -eq 1) { $RowColors += $P.Mag }
            elseif ($i % 2 -eq 0) { $RowColors += $P.Blue }
            else { $RowColors += $P.Gray }
        }
    }

    WL ''
    WL ('  ' + $P.Wht + $P.B + $Title + $P.R + $P.Dim + '   ' + $P.R + $P.Gray + 'суммируем по столбцам с переносами' + $P.R)
    WL ''

    $colOps = @()
    for ($i = 0; $i -lt $rowCount; $i++) {
        if ($i -lt $Ops.Count) { $colOps += $Ops[$i] } else { $colOps += ' ' }
    }

    $lastIdx = $info.Steps.Count - 1
    Push-Speed ([Math]::Max($w, $rowCount * 2))
    for ($k = 0; $k -le $lastIdx; $k++) {
        $frame = New-SumFrame -Info $info -StepIdx $k -Ops $colOps -RowColors $RowColors
        Draw $frame
        Wait-Bit 1
    }
    Pop-Speed
    $frame = New-SumFrame -Info $info -StepIdx $lastIdx -Ops $colOps -RowColors $RowColors -Done
    Draw $frame -Final
    End-Block
    return $info
}

function New-SumFrame {
    param(
        $Info,
        [int]$StepIdx,
        [string[]]$Ops,
        [string[]]$RowColors,
        [switch]$Done
    )
    $w = $Info.Result.Length
    $off = $Info.Extra
    $cur = -1
    if (-not $Done -and $StepIdx -ge 0 -and $StepIdx -lt $Info.Steps.Count) { $cur = $off + $Info.Steps[$StepIdx].Col }

    $rc = [char[]]('·' * $w)
    $cc = @('') * $w
    for ($k = 0; $k -le $StepIdx -and $k -lt $Info.Steps.Count; $k++) {
        $s = $Info.Steps[$k]
        $rc[$off + $s.Col] = [char](48 + $s.Bit)
        if ($s.CarryIn -gt 0) { $cc[$off + $s.Col] = [string]$s.CarryIn }
    }
    if ($StepIdx -ge $Info.Steps.Count - 1) {
        for ($j = 0; $j -lt $off; $j++) { $rc[$j] = $Info.Result[$j] }
    }

    $gutterW = 4
    $lines = New-Object 'System.Collections.Generic.List[string]'

    # строка переносов
    $ln = Rep ' ' $gutterW
    for ($i = 0; $i -lt $w; $i++) {
        $txt = $cc[$i]
        if ($txt.Length -gt 2) { $txt = $txt.Substring(0, 2) }
        $txt = $txt.PadRight(2, ' ')
        if ($i -eq $cur) {
            $ln += ($P.BgCar + $P.Amb + $txt + $P.R)
        }
        elseif ($txt.Trim() -ne '') {
            $ln += ($P.Amb + $txt + $P.R)
        }
        else {
            $ln += ('  ')
        }
    }
    $lines.Add($ln)

    # строки операндов
    for ($r = 0; $r -lt $Info.Rows.Count; $r++) {
        $row = $Info.Rows[$r]
        $opCh = ' '
        if ($Ops[$r] -ne ' ') { $opCh = $Ops[$r] }
        $ln = '  ' + $P.Dim + $opCh + ' ' + $P.R
        for ($i = 0; $i -lt $w; $i++) {
            $colIdx = $i - $off
            $bit = ' '
            if ($colIdx -ge 0 -and $colIdx -lt $Info.OrigWidth) {
                $bit = [string]$row[$colIdx]
            }
            $color = $P.Gray
            if ($r -lt $RowColors.Count) { $color = $RowColors[$r] }
            if ($bit -eq ' ') { $ln += '  ' }
            elseif ($i -eq $cur) { $ln += ($P.BgHi + $color + $bit + $P.R + ' ') }
            else { $ln += ($color + $bit + $P.R + ' ') }
        }
        $lines.Add($ln)
    }

    # разделитель
    $ln = Rep ' ' $gutterW
    for ($i = 0; $i -lt $w; $i++) {
        if ($i -eq $cur) { $ln += ($P.BgHi + $P.Dim + '──' + $P.R) }
        else { $ln += ($P.Dim + '──' + $P.R) }
    }
    $lines.Add($ln)

    # результат
    $ln = Rep ' ' $gutterW
    for ($i = 0; $i -lt $w; $i++) {
        $ch = [string]$rc[$i]
        if ($ch -eq '·') { $ln += ($P.Dim + '·' + $P.R + ' ') }
        elseif ($i -eq $cur) { $ln += ($P.BgHi + $P.Grn + $P.B + $ch + $P.R + ' ') }
        else { $ln += ($P.Grn + $ch + $P.R + ' ') }
    }
    $lines.Add($ln)
    $lines.Add('')

    # описание шага
    $desc = ''
    $desc2 = ''
    if ($StepIdx -ge 0 -and $StepIdx -lt $Info.Steps.Count) {
        $s = $Info.Steps[$StepIdx]
        $colNo = $Info.OrigWidth - $s.Col
        $parts = @()
        foreach ($b in $s.Bits) {
            if ($b -eq 1) { $parts += ($P.Cyan + '1' + $P.R) } else { $parts += ($P.Dim + '0' + $P.R) }
        }
        $expr = ($parts -join ($P.Gray + ' + ' + $P.R))
        if ($s.CarryIn -gt 0) {
            $expr += ($P.Gray + ' + перенос ' + $P.R + $P.Amb + $s.CarryIn + $P.R)
        }
        $desc = '  ' + $P.Dim + 'столбец ' + $colNo + ' (' + $P.R + $P.Dim + 'вес 2^' + ($Info.OrigWidth - 1 - $s.Col) + $P.R + $P.Dim + '):  ' + $P.R +
            $expr + $P.Gray + '  =  ' + $P.R + $P.Wht + $s.Total + $P.R + $P.Dim + '₁₀  =  ' + $P.R +
            $P.Amb + (ToBinStr ([System.Numerics.BigInteger]$s.Total)) + '₂' + $P.R +
            $P.Gray + '   → пишем ' + $P.R + $P.Grn + $P.B + $s.Bit + $P.R
        if ($s.CarryOut -gt 0) {
            $desc += ($P.Gray + ', переносим ' + $P.R + $P.Amb + $P.B + $s.CarryOut + $P.R)
        }
        else {
            $desc += ($P.Gray + ', переноса нет' + $P.R)
        }
        if (-not $Done) {
            $desc2 = '  ' + $P.Dim + 'осталось столбцов: ' + ($Info.Steps.Count - 1 - $StepIdx) + $P.R
        }
    }
    if ($Done) {
        $desc = '  ' + $P.Grn + $P.B + 'готово!' + $P.R + $P.Gray + '  все разряды обработаны, результат собран снизу вверх' + $P.R
        $desc2 = ''
    }
    $lines.Add($desc)
    $lines.Add($desc2)

    # обрезка по ширине терминала
    $out = @()
    foreach ($l in $lines) {
        if ((Get-VisLen $l) -gt ($script:Cols - 2)) {
            $out += (Trim-Msg $l ($script:Cols - 6))
        }
        else { $out += $l }
    }
    return $out
}

# обрезает строку с ANSI-кодами до N видимых символов
function Trim-Msg([string]$s, [int]$max) {
    $out = ''
    $vis = 0
    $i = 0
    while ($i -lt $s.Length) {
        if ($s[$i] -eq $E) {
            $j = $i + 1
            while ($j -lt $s.Length -and $s[$j] -ne 'm') { $j++ }
            if ($j -lt $s.Length) { $j++ }
            $out += $s.Substring($i, $j - $i)
            $i = $j
        }
        else {
            if ($vis -ge $max) { break }
            $out += $s[$i]
            $vis++
            $i++
        }
    }
    return ($out + $P.R + '…')
}

# ======================== АНИМАЦИЯ: ВЫЧИТАНИЕ ==============================
function Show-Sub {
    param([string]$A, [string]$B, [string]$Title = 'ВЫЧИТАНИЕ')
    $info = Get-SubInfo $A $B
    $n = $info.Width

    WL ''
    WL ('  ' + $P.Wht + $P.B + $Title + $P.R + $P.Dim + '   ' + $P.R + $P.Gray + 'вычитаем по столбцам с заёмами' + $P.R)
    WL ''

    $lastIdx = $info.Steps.Count - 1
    for ($k = 0; $k -le $lastIdx; $k++) {
        $frame = New-SubFrame -Info $info -StepIdx $k
        Draw $frame
        Wait-Bit 1
    }
    $frame = New-SubFrame -Info $info -StepIdx $lastIdx -Done
    Draw $frame -Final
    End-Block
    return $info
}

function New-SubFrame {
    param($Info, [int]$StepIdx, [switch]$Done)
    $w = $Info.Width
    $cur = -1
    if (-not $Done -and $StepIdx -ge 0 -and $StepIdx -lt $Info.Steps.Count) { $cur = $Info.Steps[$StepIdx].Col }

    $rc = [char[]]('·' * $w)
    $bc = @('') * $w
    for ($k = 0; $k -le $StepIdx -and $k -lt $Info.Steps.Count; $k++) {
        $s = $Info.Steps[$k]
        $rc[$s.Col] = [char](48 + $s.Diff)
        if ($s.BorrowIn -gt 0) { $bc[$s.Col] = [string]$s.BorrowIn }
    }

    $gutterW = 4
    $lines = New-Object 'System.Collections.Generic.List[string]'

    $ln = Rep ' ' $gutterW
    for ($i = 0; $i -lt $w; $i++) {
        $txt = $bc[$i].PadRight(2, ' ')
        if ($i -eq $cur) { $ln += ($P.BgCar + $P.Amb + $txt + $P.R) }
        elseif ($txt.Trim() -ne '') { $ln += ($P.Amb + $txt + $P.R) }
        else { $ln += '  ' }
    }
    $lines.Add($ln)

    foreach ($pair in @(@(' ', $Info.A, $P.Cyan), @('-', $Info.B, $P.Mag))) {
        $ln = '  ' + $P.Dim + $pair[0] + ' ' + $P.R
        for ($i = 0; $i -lt $w; $i++) {
            $bit = [string]$pair[1][$i]
            if ($i -eq $cur) { $ln += ($P.BgHi + $pair[2] + $bit + $P.R + ' ') }
            else { $ln += ($pair[2] + $bit + $P.R + ' ') }
        }
        $lines.Add($ln)
    }

    $ln = Rep ' ' $gutterW
    for ($i = 0; $i -lt $w; $i++) {
        if ($i -eq $cur) { $ln += ($P.BgHi + $P.Dim + '──' + $P.R) }
        else { $ln += ($P.Dim + '──' + $P.R) }
    }
    $lines.Add($ln)

    $ln = Rep ' ' $gutterW
    for ($i = 0; $i -lt $w; $i++) {
        $ch = [string]$rc[$i]
        if ($ch -eq '·') { $ln += ($P.Dim + '·' + $P.R + ' ') }
        elseif ($i -eq $cur) { $ln += ($P.BgHi + $P.Grn + $P.B + $ch + $P.R + ' ') }
        else { $ln += ($P.Grn + $ch + $P.R + ' ') }
    }
    $lines.Add($ln)
    $lines.Add('')

    $desc = ''
    if ($StepIdx -ge 0 -and $StepIdx -lt $Info.Steps.Count) {
        $s = $Info.Steps[$StepIdx]
        $colNo = $w - $s.Col
        $cA = $P.Cyan; if ($s.A -eq 0) { $cA = $P.Dim }
        $cB = $P.Mag;  if ($s.B -eq 0) { $cB = $P.Dim }
        $desc = '  ' + $P.Dim + 'столбец ' + $colNo + ' (вес 2^' + ($w - 1 - $s.Col) + '):  ' + $P.R +
            $cA + $s.A + $P.R + $P.Gray + ' − ' + $P.R + $cB + $s.B + $P.R
        if ($s.BorrowIn -gt 0) { $desc += ($P.Gray + ' − заём ' + $P.R + $P.Amb + $s.BorrowIn + $P.R) }
        if ($s.BorrowOut -gt 0) {
            $desc += ($P.Gray + '   →  10₂ − ' + $P.R + $cB + $s.B + $P.R + $P.Gray + ' = ' + $P.R +
                $P.Grn + $P.B + $s.Diff + $P.R + $P.Gray + ', пишем ' + $P.R + $P.Grn + $P.B + $s.Diff + $P.R +
                $P.Gray + ', занимаем ' + $P.R + $P.Amb + '1' + $P.R)
        }
        else {
            $desc += ($P.Gray + '   →  = ' + $P.R + $P.Grn + $P.B + $s.Diff + $P.R + $P.Gray + ', пишем ' + $P.R +
                $P.Grn + $P.B + $s.Diff + $P.R + $P.Gray + ', заёма нет' + $P.R)
        }
    }
    if ($Done) {
        $desc = '  ' + $P.Grn + $P.B + 'готово!' + $P.R + $P.Gray + '  результат собран снизу вверх: ' + $P.R +
            $P.Grn + (Format-Bin $Info.Raw) + '₂' + $P.R
    }
    $lines.Add($desc)
    $lines.Add('')

    $out = @()
    foreach ($l in $lines) {
        if ((Get-VisLen $l) -gt ($script:Cols - 2)) { $out += (Trim-Msg $l ($script:Cols - 6)) }
        else { $out += $l }
    }
    return $out
}

# ======================== АНИМАЦИЯ: УМНОЖЕНИЕ ==============================
function Show-Mul {
    param(
        [string]$A,
        [string]$B,
        [System.Numerics.BigInteger]$Product,
        [string]$Title = 'УМНОЖЕНИЕ',
        [string]$Sub = 'каждый бит множителя даёт своё частичное произведение'
    )
    $part = Get-Partials $A $B
    $bTrim = Trim-Bin $B
    $w = $part.Width
    $gutterW = 4

    WL ''
    WL ('  ' + $P.Wht + $P.B + $Title + $P.R + $P.Dim + '   ' + $P.R + $P.Gray + $Sub + $P.R)
    WL ''

    $totalRows = $part.Rows.Count
    # кадры: сначала операнды, затем частичные произведения появляются по одному
    Push-Speed ($totalRows * 2)
    for ($reveal = 0; $reveal -lt $totalRows; $reveal++) {
        $lines = New-MulFrame -A $A -B $bTrim -Part $part -Reveal $reveal -Gutter $gutterW
        Draw $lines
        Wait-Bit 1
    }
    Pop-Speed
    $lines = New-MulFrame -A $A -B $bTrim -Part $part -Reveal ($totalRows - 1) -Gutter $gutterW -Done
    Draw $lines -Final
    End-Block

    WL ('  ' + $P.Dim + 'теперь складываем все частичные произведения:' + $P.R)
    $ops = @()
    for ($i = 0; $i -lt $part.Rows.Count; $i++) {
        if ($i -eq 0) { $ops += ' ' } else { $ops += '+' }
    }
    $sum = Show-Sum -Rows $part.Rows -Ops $ops -Title 'СУММА ЧАСТИЧНЫХ ПРОИЗВЕДЕНИЙ'
    return $sum
}
function New-MulFrame {
    param(
        [string]$A, [string]$B, $Part, [int]$Reveal, [int]$Gutter, [switch]$Done
    )
    $w = $Part.Width
    $lines = New-Object 'System.Collections.Generic.List[string]'

    # строка множимого
    $ln = Rep ' ' $Gutter
    $lead = $w - $A.Length
    for ($i = 0; $i -lt $w; $i++) {
        if ($i -lt $lead) { $ln += '  ' }
        else { $ln += ($P.Cyan + $A[$i - $lead] + $P.R + ' ') }
    }
    $lines.Add($ln)

    # строка множителя
    $ln = '  ' + $P.Dim + '× ' + $P.R
    $lead = $w - $B.Length
    for ($i = 0; $i -lt $w; $i++) {
        if ($i -lt $lead) { $ln += '  ' }
        else {
            $pos = $B.Length - 1 - ($i - $lead)
            $color = $P.Mag
            if ($B[$i - $lead] -eq '0') { $color = $P.Dim }
            if ($pos -eq $Reveal -and -not $Done) { $ln += ($P.BgHi + $color + $B[$i - $lead] + $P.R + ' ') }
            else { $ln += ($color + $B[$i - $lead] + $P.R + ' ') }
        }
    }
    $lines.Add($ln)

    # разделитель
    $ln = Rep ' ' $Gutter
    for ($i = 0; $i -lt $w; $i++) { $ln += ($P.Dim + '──' + $P.R) }
    $lines.Add($ln)

    # частичные произведения
    for ($r = 0; $r -lt $Part.Rows.Count; $r++) {
        if ($r -gt $Reveal) { break }
        $isCur = ($r -eq $Reveal -and -not $Done)
        $opCh = ' '
        if ($r -gt 0) { $opCh = '+' }
        $ln = '  ' + $P.Dim + $opCh + ' ' + $P.R
        $rowStr = $Part.Rows[$r]
        for ($i = 0; $i -lt $w; $i++) {
            $bit = [string]$rowStr[$i]
            $color = $P.Blue
            if ($bit -eq '0') { $color = $P.Dim }
            if ($isCur) { $ln += ($P.BgHi + $color + $bit + $P.R + ' ') }
            else { $ln += ($color + $bit + $P.R + ' ') }
        }
        $lines.Add($ln)
    }

    $desc = ''
    if (-not $Done) {
        $mi = $Part.Info[$Reveal]
        $mb = $mi.MultiplierBit
        $desc = '  ' + $P.Dim + 'бит множителя ' + $P.R + $P.Amb + $mb + $P.R + $P.Dim + ' на позиции ' + $mi.Position + ':  ' + $P.R
        if ($mb -eq 1) {
            $desc += $P.Gray + 'множимое сдвигаем влево на ' + $mi.Position + ' → ' + $P.R + $P.Blue + (Trim-Bin $mi.Value) + '₂' + $P.R
        }
        else {
            $desc += $P.Gray + 'бит нулевой → частичное произведение = 0' + $P.R
        }
    }
    else {
        $desc = '  ' + $P.Grn + $P.B + 'все частичные произведения готовы' + $P.R + $P.Gray + '  (всего ' + $Part.Rows.Count + ')' + $P.R
    }
    $lines.Add($desc)
    $lines.Add('')

    $out = @()
    foreach ($l in $lines) {
        if ((Get-VisLen $l) -gt ($script:Cols - 2)) { $out += (Trim-Msg $l ($script:Cols - 6)) }
        else { $out += $l }
    }
    return $out
}

# ======================== АНИМАЦИЯ: ДЕЛЕНИЕ ================================
function Show-Div {
    param(
        [string]$A,
        [string]$B,
        [string]$Title = 'ДЕЛЕНИЕ'
    )
    $aTrim = Trim-Bin $A
    $bTrim = Trim-Bin $B

    WL ''
    WL ('  ' + $P.Wht + $P.B + $Title + $P.R + $P.Dim + '   ' + $P.R + $P.Gray + 'двоичное деление столбиком: сдвиг — сравнение — вычитание' + $P.R)
    WL ''
    WL ('  ' + $P.Dim + 'делимое  ' + $P.R + $P.Cyan + (Format-Bin $aTrim) + '₂' + $P.R + $P.Dim + '   делитель  ' + $P.R + $P.Mag + (Format-Bin $bTrim) + '₂' + $P.R)
    WL ''

    $divisorVal = BinToBig $bTrim
    $rem = [System.Numerics.BigInteger]::Zero
    $steps = @()
    $qbits = ''
    for ($i = 0; $i -lt $aTrim.Length; $i++) {
        $bit = [int]$aTrim[$i] - 48
        $shifted = $rem * 2 + $bit
        $ge = $false
        $sub = $null
        if ($shifted -ge $divisorVal) {
            $ge = $true
            $sub = $shifted
            $rem = $shifted - $divisorVal
            $qbits += '1'
        }
        else {
            $rem = $shifted
            $qbits += '0'
        }
        $steps += [pscustomobject]@{
            Index   = $i
            Bit     = $bit
            Shifted = $shifted
            Sub     = $sub
            Ge      = $ge
            Rem     = $rem
            QBit    = $qbits[$qbits.Length - 1]
        }
    }

    # ширины колонок
    $cStep = 4
    $cBit = 4
    $maxShift = 0
    $maxRem = 0
    foreach ($s in $steps) {
        $l1 = (ToBinStr $s.Shifted).Length
        if ($l1 -gt $maxShift) { $maxShift = $l1 }
        $l2 = (ToBinStr $s.Rem).Length
        if ($l2 -gt $maxRem) { $maxRem = $l2 }
    }
    $cShift = [Math]::Max($maxShift, 6)
    $cRem = [Math]::Max($maxRem, 6)
    $cSub = [Math]::Max($maxShift, 6)

    $hdrPlain = '  ' + 'шаг'.PadRight($cStep) + 'бит'.PadRight($cBit) + 'сдвиг'.PadLeft($cShift) + '  ' +
        '≥ дел.'.PadRight(10) + ' ' + 'вычли'.PadLeft($cSub) + '  ' + 'остаток'.PadLeft($cRem) + '  q'
    $header = $P.Dim + $hdrPlain + $P.R

    $tableLines = New-Object 'System.Collections.Generic.List[string]'
    $tableLines.Add($header)
    $sep = '  ' + $P.Dim + (Rep '─' ($hdrPlain.Length - 2)) + $P.R
    $tableLines.Add($sep)

    $lastIdx = $steps.Count - 1
    Push-Speed ($aTrim.Length * 2)
    for ($k = 0; $k -le $lastIdx; $k++) {
        $s = $steps[$k]
        $colorShift = $P.Cyan
        $cmpTxt = $P.Dim + 'нет' + $P.R
        $subTxt = $P.Dim + '—' + $P.R
        if ($s.Ge) {
            $cmpTxt = $P.Grn + 'да' + $P.R
            $subTxt = $P.Wht + (ToBinStr $s.Sub).PadLeft($cSub) + $P.R
        }
        $line = '  ' + $P.Wht + ([string]($s.Index + 1)).PadRight($cStep) + $P.R +
            $P.Amb + ([string]$s.Bit).PadRight($cBit) + $P.R +
            $colorShift + (ToBinStr $s.Shifted).PadLeft($cShift) + $P.R + '  ' +
            (Pad-Ansi $cmpTxt 10) + ' ' + (Pad-Ansi $subTxt $cSub) + '  ' +
            $P.Grn + (ToBinStr $s.Rem).PadLeft($cRem) + $P.R + '  ' +
            $P.B + $P.Mag + $s.QBit + $P.R
        $tableLines.Add($line)
        Draw $tableLines.ToArray()
        Wait-Bit 1
    }
    Pop-Speed
    Draw $tableLines.ToArray() -Final
    End-Block

    WL ''
    WL ('  ' + $P.Dim + 'биты частного собираются по одному: ' + $P.R + $P.Mag + $P.B + (Trim-Bin $qbits) + '₂' + $P.R)
    WL ''

    $qVal = BinToBig $qbits
    return [pscustomobject]@{
        Quotient  = $qVal
        Remainder = $rem
        QBin      = (Trim-Bin $qbits)
    }
}

# ============================ ПАНЕЛЬ РЕЗУЛЬТАТА =============================
function Show-Result {
    param(
        [string]$ExprText,
        [System.Numerics.BigInteger]$DecResult,
        [string]$BinResult,
        [string]$Extra = ''
    )
    $bin = Trim-Bin $BinResult
    $hex = '0x' + $DecResult.ToString('X')
    if ($DecResult.Sign -lt 0) { $hex = '-0x' + ([System.Numerics.BigInteger]::Abs($DecResult)).ToString('X') }
    $decTxt = Format-Dec $DecResult
    $binTxt = Format-Bin $bin

    $lines = @()
    $lines += ($P.Dim + 'выражение:  ' + $P.R + $P.Wht + $ExprText + $P.R)
    $lines += ''
    $lines += ($P.Dim + 'десятичное:  ' + $P.R + $P.Amb + $P.B + $decTxt + $P.R)
    $lines += ($P.Dim + 'двоичное:    ' + $P.R + $P.Grn + $P.B + $binTxt + '₂' + $P.R + $P.Dim + '   (' + $bin.Length + ' бит)' + $P.R)

    # битовая карта результата, сгруппированная по нибблам
    $bitRow = ''
    for ($i = 0; $i -lt $bin.Length; $i++) {
        if ($bin[$i] -eq '1') { $bitRow += ($P.Grn + $P.B + '1' + $P.R + ' ') }
        else { $bitRow += ($P.Dim + '0' + $P.R + ' ') }
        if ((($bin.Length - 1 - $i) % 4) -eq 0 -and $i -lt ($bin.Length - 1)) { $bitRow += ' ' }
    }
    $lines += ($P.Dim + 'биты:        ' + $P.R + $bitRow)
    $lines += ($P.Dim + 'hex:         ' + $P.R + $P.Blue + $hex + $P.R)
    if ($Extra -ne '') { $lines += ($P.Dim + $Extra + $P.R) }

    # короткая «вспышка» рамки, потом спокойный зелёный
    foreach ($bc in @($P.Mag, $P.Cyan)) {
        Draw (Get-PanelLines -Lines $lines -Title 'РЕЗУЛЬТАТ' -Border $bc)
        Wait-Bit 2
    }
    Draw (Get-PanelLines -Lines $lines -Title 'РЕЗУЛЬТАТ' -Border $P.Grn) -Final
    End-Block
}

function Show-ErrorPanel([string]$msg) {
    WL ''
    Show-Panel -Lines @($P.Red + $P.B + $msg + $P.R, '', ($P.Dim + 'пример:  2+5   0b1011*0b110   0xFF-0b1' + $P.R)) -Title 'ОШИБКА' -Border $P.Red
    WL ''
}

# ============================== ПАРСИНГ ====================================
$script:NumPattern = '(?<{0}>(?:0[bB][01]+)|(?:0[xX][0-9a-fA-F]+)|(?:0[01]+)|(?:\d+))'

function Parse-Number([string]$tok) {
    $t = $tok.Trim()
    $kind = 'dec'
    $bin = '0'
    $val = [System.Numerics.BigInteger]::Zero

    if ($t -match '^0[bB]([01]+)$') {
        $kind = 'bin'
        $bin = Trim-Bin $matches[1]
        $val = BinToBig $bin
    }
    elseif ($t -match '^0[xX]([0-9a-fA-F]+)$') {
        $kind = 'hex'
        $hexDigits = $matches[1]
        # .NET трактует hex как дополнительный код, поэтому добавляем ведущий 0
        $val = [System.Numerics.BigInteger]::Parse('0' + $hexDigits, 'HexNumber')
        $bin = ToBinStr $val
    }
    elseif ($t -match '^0([01]+)$') {
        $kind = 'bin'
        $bin = Trim-Bin $t
        $val = BinToBig $bin
    }
    elseif ($t -match '^\d+$') {
        $kind = 'dec'
        $val = [System.Numerics.BigInteger]::Parse($t)
        $bin = ToBinStr $val
    }
    else {
        throw ('не понимаю число "' + $t + '"')
    }

    return [pscustomobject]@{
        Raw   = $t
        Kind  = $kind
        Bin   = $bin
        Value = $val
    }
}

function Parse-Expr([string]$text) {
    $pat = '^\s*(?<s1>[-+])?\s*' + ($script:NumPattern -f 'n1') + '\s*(?<op>[+\-*/xX×÷])\s*(?<s2>[-+])?\s*' + ($script:NumPattern -f 'n2') + '\s*$'
    if ($text -notmatch $pat) {
        throw 'формат не распознан — нужен вид  ЧИСЛО  ОПЕРАЦИЯ  ЧИСЛО'
    }
    $m = $matches
    $a = Parse-Number $m['n1']
    $b = Parse-Number $m['n2']
    $s1 = 1
    if ($m['s1'] -eq '-') { $s1 = -1 }
    $s2 = 1
    if ($m['s2'] -eq '-') { $s2 = -1 }
    $op = $m['op']
    if ($op -eq 'x' -or $op -eq 'X' -or $op -eq '×') { $op = '*' }
    if ($op -eq '÷') { $op = '/' }

    return [pscustomobject]@{
        A     = $a.Value * $s1
        B     = $b.Value * $s2
        NumA  = $a
        NumB  = $b
        SignA = $s1
        SignB = $s2
        Op    = $op
    }
}

function Get-Sign([System.Numerics.BigInteger]$n) {
    if ($n.Sign -gt 0) { return 1 }
    if ($n.Sign -lt 0) { return -1 }
    return 0
}

# =========================== ВЫПОЛНЕНИЕ ОПЕРАЦИИ ============================
function Invoke-AddSub($parsed) {
    $a = $parsed.A
    $b = $parsed.B
    $effB = $b
    if ($parsed.Op -eq '-') { $effB = -$b }
    $sum = $a + $effB

    $absA = [System.Numerics.BigInteger]::Abs($a)
    $absB = [System.Numerics.BigInteger]::Abs($effB)
    $binA = Trim-Bin $parsed.NumA.Bin
    $binB = Trim-Bin $parsed.NumB.Bin
    $sa = Get-Sign $a
    $sb = Get-Sign $effB

    $opSym = '+'
    if ($parsed.Op -eq '-') { $opSym = '−' }

    # словарь знаков
    $signNote = ''
    if ($sa -eq 0) { $signNote = 'A = 0, поэтому результат равен B' }
    elseif ($sb -eq 0) { $signNote = 'B = 0, поэтому результат равен A' }

    WL ''
    WL ('  ' + $P.Dim + 'выражение:  ' + $P.R + $P.Wht + (Format-Dec $a) + '  ' + $opSym + '  ' + (Format-Dec $b) + $P.R +
        $P.Dim + '   =   ?' + $P.R)

    Show-NumberCard $parsed.NumA 'A' $P.Cyan
    if ($parsed.SignA -lt 0) { WL ('  ' + $P.Red + 'знак A: минус' + $P.R) }
    Show-NumberCard $parsed.NumB 'B' $P.Mag
    if ($parsed.SignB -lt 0 -and $parsed.Op -ne '-') { WL ('  ' + $P.Red + 'знак B: минус' + $P.R) }

    $signStr = ''
    if ($sum.Sign -lt 0) { $signStr = '-' }

    $label = ''
    if ($sa -eq 0 -or $sb -eq 0) {
        # вырожденный случай — просто покажем результат
        $label = 'вырожденный случай: одно из слагаемых равно нулю'
    }
    elseif ($sa -eq $sb) {
        $label = 'знаки одинаковые → складываем модули, знак сохраняется'
    }
    else {
        $label = 'знаки разные → вычитаем меньший модуль из большего'
    }
    WL ''
    WL ('  ' + $P.Amb + '▸ ' + $label + $P.R)
    WL ''

    $absSum = [System.Numerics.BigInteger]::Abs($sum)
    $binSum = ToBinStr $absSum

    if ($sa -ne 0 -and $sb -ne 0 -and $sa -ne $sb) {
        # вычитание модулей
        $bigBin = $binA; $smallBin = $binB
        $swapped = $false
        if ($absA -lt $absB) {
            $bigBin = $binB; $smallBin = $binA; $swapped = $true
        }
        if (-not $swapped) {
            Show-Sub -A $bigBin -B $smallBin -Title 'ВЫЧИТАНИЕ МОДУЛЕЙ' | Out-Null
        }
        else {
            WL ('  ' + $P.Dim + '|A| < |B| → меняем местами: ' + $P.R + $P.Cyan + $binB + $P.R + $P.Dim + ' − ' + $P.R + $P.Mag + $binA + $P.R)
            WL ''
            Show-Sub -A $bigBin -B $smallBin -Title 'ВЫЧИТАНИЕ МОДУЛЕЙ' | Out-Null
        }
    }
    else {
        $rows = @($binA, $binB)
        $ops = @(' ', '+')
        if ($sa -lt 0 -or $sb -lt 0) { $ops[1] = '+' }
        Show-Sum -Rows $rows -Ops $ops -Title 'СЛОЖЕНИЕ' | Out-Null
    }

    $exprTxt = (Format-Dec $a) + ' ' + $opSym + ' ' + (Format-Dec $b)
    $extra = ''
    if ($sum.Sign -lt 0) { $extra = 'результат отрицательный — показан модуль, знак: минус' }
    Show-Result -ExprText $exprTxt -DecResult $sum -BinResult $binSum -Extra $extra

    # дополнительный код для отрицательного результата
    if ($sum.Sign -lt 0) {
        Show-TwosComplement $sum
    }
    return $sum
}

function Group-Left([string]$s) {
    $out = ''
    for ($i = 0; $i -lt $s.Length; $i += 4) { $out += $s.Substring($i, [Math]::Min(4, $s.Length - $i)) + ' ' }
    return $out.Trim()
}

function Show-TwosComplement([System.Numerics.BigInteger]$neg) {
    $abs = [System.Numerics.BigInteger]::Abs($neg)
    $bits = Trim-Bin (ToBinStr $abs)
    $sizes = @(8, 16, 32, 64)
    $size = 8
    foreach ($s in $sizes) { if ($bits.Length + 1 -le $s) { $size = $s; break } }
    $padded = $bits.PadLeft($size - 1, '0')
    $inv = ''
    foreach ($ch in $padded.ToCharArray()) {
        if ($ch -eq '1') { $inv += '0' } else { $inv += '1' }
    }
    $carry = 1
    $arr = [char[]]$inv
    for ($i = $arr.Length - 1; $i -ge 0; $i--) {
        $b = [int]$arr[$i] - 48 + $carry
        if ($b -ge 2) { $arr[$i] = '0'; $carry = 1 } else { $arr[$i] = [char](48 + $b); $carry = 0 }
    }
    $tc = '1' + (-join $arr)
    $grouped = Group-Left $tc
    $lines = @(
        ($P.Dim + 'модуль:            ' + $P.R + $P.Grn + (Format-Bin $bits) + '₂' + $P.R),
        ($P.Dim + 'инверсия:          ' + $P.R + $P.Wht + (Group-Left $inv) + $P.R),
        ($P.Dim + 'дополнительный код: ' + $P.R + $P.Amb + $grouped + $P.R + $P.Dim + '   (' + $size + ' бит)' + $P.R)
    )
    Show-Panel -Lines $lines -Title 'ДОПОЛНИТЕЛЬНЫЙ КОД' -Border $P.Amb
    WL ''
}

function Invoke-Mul($parsed) {
    $absA = [System.Numerics.BigInteger]::Abs($parsed.A)
    $absB = [System.Numerics.BigInteger]::Abs($parsed.B)
    $binA = Trim-Bin (ToBinStr $absA)
    $binB = Trim-Bin (ToBinStr $absB)
    $sign = 1
    if ($parsed.A.Sign * $parsed.B.Sign -lt 0) { $sign = -1 }
    $prod = $absA * $absB
    $signedProd = $prod
    if ($sign -lt 0) { $signedProd = -$prod }

    WL ''
    WL ('  ' + $P.Dim + 'выражение:  ' + $P.R + $P.Wht + (Format-Dec $parsed.A) + '  ×  ' + (Format-Dec $parsed.B) + $P.R + $P.Dim + '   =   ?' + $P.R)

    Show-NumberCard $parsed.NumA 'A' $P.Cyan
    Show-NumberCard $parsed.NumB 'B' $P.Mag

    WL ''
    WL ('  ' + $P.Amb + '▸ ' + 'умножаем модули, знак результата: ' + $P.R +
        $(if ($sign -lt 0) { $P.Red + 'минус' + $P.R } else { $P.Grn + 'плюс' + $P.R }))
    WL ''

    Show-Mul -A $binA -B $binB -Product $prod | Out-Null

    $exprTxt = (Format-Dec $parsed.A) + ' × ' + (Format-Dec $parsed.B)
    $extra = ''
    if ($sign -lt 0) { $extra = 'результат отрицательный — показан модуль, знак: минус' }
    Show-Result -ExprText $exprTxt -DecResult $signedProd -BinResult (Trim-Bin (ToBinStr $prod)) -Extra $extra
    if ($sign -lt 0) { Show-TwosComplement $signedProd }
    return $signedProd
}

function Invoke-Div($parsed) {
    $absA = [System.Numerics.BigInteger]::Abs($parsed.A)
    $absB = [System.Numerics.BigInteger]::Abs($parsed.B)
    if ($absB.Sign -eq 0) { throw 'деление на ноль — вселенная не одобряет' }
    $binA = Trim-Bin (ToBinStr $absA)
    $binB = Trim-Bin (ToBinStr $absB)

    WL ''
    WL ('  ' + $P.Dim + 'выражение:  ' + $P.R + $P.Wht + (Format-Dec $parsed.A) + '  ÷  ' + (Format-Dec $parsed.B) + $P.R + $P.Dim + '   =   ?' + $P.R)

    Show-NumberCard $parsed.NumA 'A' $P.Cyan
    Show-NumberCard $parsed.NumB 'B' $P.Mag

    $sign = 1
    if ($parsed.A.Sign * $parsed.B.Sign -lt 0) { $sign = -1 }

    $div = Show-Div -A $binA -B $binB
    $q = $div.Quotient
    $rem = $div.Remainder

    # проверка
    $qSigned = $q
    if ($sign -lt 0) { $qSigned = -$q }
    $checkTxt = ''
    if ($rem.Sign -ne 0) {
        $checkTxt = 'проверка:  ' + (Format-Dec $q) + ' × ' + (Format-Dec $absB) + ' + ' + (Format-Dec $rem) + ' = ' + (Format-Dec $absA)
    }

    WL ('  ' + $P.Dim + 'частное: ' + $P.R + $P.Grn + $P.B + (Format-Dec $qSigned) + $P.R + $P.Dim + '   =   ' + $P.R + $P.Grn + (Format-Bin (Trim-Bin $div.QBin)) + '₂' + $P.R)
    if ($rem.Sign -ne 0) {
        WL ('  ' + $P.Dim + 'остаток: ' + $P.R + $P.Amb + (Format-Dec $rem) + $P.R + $P.Dim + '   =   ' + $P.R + $P.Amb + (Format-Bin (Trim-Bin (ToBinStr $rem))) + '₂' + $P.R)
    }
    WL ''
    if ($checkTxt -ne '') { WL ('  ' + $P.Dim + $checkTxt + $P.R) }

    $exprTxt = (Format-Dec $parsed.A) + ' ÷ ' + (Format-Dec $parsed.B)
    $extra = ''
    if ($rem.Sign -ne 0) { $extra = 'деление с остатком — частное округлено вниз по модулю' }
    Show-Result -ExprText $exprTxt -DecResult $qSigned -BinResult (Trim-Bin $div.QBin) -Extra $extra
    return $qSigned
}

# ====================== СЛОЖНЫЕ ВЫРАЖЕНИЯ: ПАРСЕР ==========================
function Get-Prec([string]$op) {
    if ($op -eq '*' -or $op -eq '/') { return 2 }
    if ($op -eq 'neg') { return 3 }
    return 1
}

function Format-OpSym([string]$op) {
    if ($op -eq '*') { return '×' }
    if ($op -eq '/') { return '÷' }
    if ($op -eq '-') { return '−' }
    if ($op -eq 'neg') { return '−' }
    return '+'
}

function Normalize-Op([string]$op) {
    if ($op -eq 'x' -or $op -eq 'X' -or $op -eq '×') { return '*' }
    if ($op -eq '÷') { return '/' }
    return $op
}

function Fmt-Num([System.Numerics.BigInteger]$v) {
    if ($v.Sign -lt 0) { return ('(' + (Format-Dec $v) + ')') }
    return (Format-Dec $v)
}

function Get-Tokens([string]$text) {
    $list = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $text.Length) {
        $ch = $text[$i]
        if ([char]::IsWhiteSpace($ch)) { $i = $i + 1; continue }
        if ($ch -ge [char]'0' -and $ch -le [char]'9') {
            $rest = $text.Substring($i)
            $mt = [regex]::Match($rest, '^(0[bB][01]+|0[xX][0-9a-fA-F]+|\d+)')
            if (-not $mt.Success) { throw ('не понимаю число в позиции ' + ($i + 1)) }
            $raw = $mt.Groups[1].Value
            $info = Parse-Number $raw
            [void]$list.Add([pscustomobject]@{ Type = 'num'; Text = $raw; Num = $info; Pos = $i })
            $i = $i + $raw.Length
            continue
        }
        if ('+-*/xX×÷'.IndexOf($ch) -ge 0) {
            [void]$list.Add([pscustomobject]@{ Type = 'op'; Text = [string]$ch; Num = $null; Pos = $i })
            $i = $i + 1
            continue
        }
        if ($ch -eq '(') {
            [void]$list.Add([pscustomobject]@{ Type = 'lp'; Text = '('; Num = $null; Pos = $i })
            $i = $i + 1
            continue
        }
        if ($ch -eq ')') {
            [void]$list.Add([pscustomobject]@{ Type = 'rp'; Text = ')'; Num = $null; Pos = $i })
            $i = $i + 1
            continue
        }
        throw ('не понимаю символ "' + $ch + '" в позиции ' + ($i + 1))
    }
    return $list
}

function New-Num-Node($ctx, $info) {
    $ctx.NextId = $ctx.NextId + 1
    return [pscustomobject]@{
        Id = $ctx.NextId; Kind = 'num'; Raw = $info.Raw; KindNum = $info.Kind
        Bin = $info.Bin; Val = $info.Value; Done = $false; Op = ''
    }
}

function New-Op-Node($ctx, [string]$op, $left, $right) {
    $ctx.NextId = $ctx.NextId + 1
    return [pscustomobject]@{
        Id = $ctx.NextId; Kind = 'op'; Raw = ''; KindNum = ''; Bin = ''
        Left = $left; Right = $right; Op = $op; Val = $null; Done = $false
    }
}

function New-Neg-Node($ctx, $child) {
    $ctx.NextId = $ctx.NextId + 1
    return [pscustomobject]@{
        Id = $ctx.NextId; Kind = 'neg'; Raw = ''; KindNum = ''; Bin = ''
        Left = $child; Right = $null; Op = 'neg'; Val = $null; Done = $false
    }
}

function Parse-Additive($ctx) {
    $left = Parse-Multiplicative $ctx
    while ($ctx.Pos -lt $ctx.Tokens.Count) {
        $t = $ctx.Tokens[$ctx.Pos]
        if ($t.Type -ne 'op') { break }
        $op = Normalize-Op ([string]$t.Text)
        if ($op -ne '+' -and $op -ne '-') { break }
        $ctx.Pos = $ctx.Pos + 1
        $right = Parse-Multiplicative $ctx
        $left = New-Op-Node $ctx $op $left $right
    }
    return $left
}

function Parse-Multiplicative($ctx) {
    $left = Parse-Unary $ctx
    while ($ctx.Pos -lt $ctx.Tokens.Count) {
        $t = $ctx.Tokens[$ctx.Pos]
        if ($t.Type -ne 'op') { break }
        $op = Normalize-Op ([string]$t.Text)
        if ($op -ne '*' -and $op -ne '/') { break }
        $ctx.Pos = $ctx.Pos + 1
        $right = Parse-Unary $ctx
        $left = New-Op-Node $ctx $op $left $right
    }
    return $left
}

function Parse-Unary($ctx) {
    if ($ctx.Pos -ge $ctx.Tokens.Count) { throw 'выражение обрывается — не хватает числа' }
    $t = $ctx.Tokens[$ctx.Pos]
    if ($t.Type -eq 'op') {
        $op = Normalize-Op ([string]$t.Text)
        if ($op -eq '-' -or $op -eq '+') {
            $ctx.Pos = $ctx.Pos + 1
            $operand = Parse-Unary $ctx
            if ($op -eq '+') { return $operand }
            if ($operand.Kind -eq 'num') {
                # минус перед числом просто меняет знак литерала
                $ctx.NextId = $ctx.NextId + 1
                $raw = [string]$operand.Raw
                if ($raw.StartsWith('-')) { $raw = $raw.Substring(1) } else { $raw = '-' + $raw }
                return [pscustomobject]@{
                    Id = $ctx.NextId; Kind = 'num'; Raw = $raw; KindNum = $operand.KindNum
                    Bin = $operand.Bin; Val = (-1 * $operand.Val); Done = $false; Op = ''
                }
            }
            return (New-Neg-Node $ctx $operand)
        }
        throw ('неожиданный оператор "' + $t.Text + '"')
    }
    return Parse-Primary $ctx
}

function Parse-Primary($ctx) {
    if ($ctx.Pos -ge $ctx.Tokens.Count) { throw 'выражение обрывается — не хватает числа' }
    $t = $ctx.Tokens[$ctx.Pos]
    if ($t.Type -eq 'num') {
        $ctx.Pos = $ctx.Pos + 1
        return (New-Num-Node $ctx $t.Num)
    }
    if ($t.Type -eq 'lp') {
        $ctx.Pos = $ctx.Pos + 1
        $inner = Parse-Additive $ctx
        if ($ctx.Pos -ge $ctx.Tokens.Count -or $ctx.Tokens[$ctx.Pos].Type -ne 'rp') { throw 'не закрыта скобка' }
        $ctx.Pos = $ctx.Pos + 1
        return $inner
    }
    if ($t.Type -eq 'rp') { throw 'лишняя закрывающая скобка' }
    throw ('ожидалось число или "(", а встретилось "' + $t.Text + '"')
}

function Build-Ast([string]$text) {
    $tokens = @(Get-Tokens $text)
    if ($tokens.Count -eq 0) { throw 'пустое выражение' }
    $ctx = @{ Tokens = $tokens; Pos = 0; NextId = 0 }
    $ast = Parse-Additive $ctx
    if ($ctx.Pos -ne $tokens.Count) {
        throw ('лишний символ "' + $tokens[$ctx.Pos].Text + '"')
    }
    return $ast
}

# ==================== СЛОЖНЫЕ ВЫРАЖЕНИЯ: ВЫВОД ДЕРЕВА ======================
function Format-Tree {
    param(
        $Node,
        [string]$ParentOp = '',
        [string]$Side = 'L',
        [int]$HighlightId = -1
    )
    if ($Node.Kind -eq 'num') { return ($P.Wht + $Node.Raw + $P.R) }
    if ($Node.Done) { return ($P.Amb + (Format-Dec $Node.Val) + $P.R) }

    if ($Node.Kind -eq 'neg') {
        $myPrec = 3
        $childTxt = Format-Tree $Node.Left 'neg' 'R' $HighlightId
        $text = $P.Mag + '−' + $P.R + $childTxt
    }
    else {
        $myPrec = Get-Prec $Node.Op
        $ltxt = Format-Tree $Node.Left $Node.Op 'L' $HighlightId
        $rtxt = Format-Tree $Node.Right $Node.Op 'R' $HighlightId
        $text = $ltxt + ' ' + $P.Cyan + (Format-OpSym $Node.Op) + $P.R + ' ' + $rtxt
    }

    if ($ParentOp -ne '') {
        $parentPrec = Get-Prec $ParentOp
        $need = $false
        if ($myPrec -lt $parentPrec) { $need = $true }
        elseif ($myPrec -eq $parentPrec -and $Side -eq 'R' -and ($ParentOp -eq '-' -or $ParentOp -eq '/')) { $need = $true }
        if ($need) { $text = ($P.Gray + '(' + $P.R + $text + $P.Gray + ')' + $P.R) }
    }

    if ($Node.Id -eq $HighlightId) {
        $text = ($P.Amb + $P.B + '[' + $P.R + $text + $P.Amb + $P.B + ']' + $P.R)
    }
    return $text
}

function Out-Line([string]$line) {
    if ((Get-VisLen $line) -gt ($script:Cols - 2)) { WL (Trim-Msg $line ($script:Cols - 6)) }
    else { WL $line }
}

# ================== СЛОЖНЫЕ ВЫРАЖЕНИЯ: ВЫЧИСЛЕНИЕ ==========================
# Считаем дерево в порядке «снизу вверх, слева направо» и запоминаем шаги.
function Get-NodeValue($Node, $Steps) {
    if ($Node.Kind -eq 'num') { return $Node.Val }
    if ($Node.Kind -eq 'neg') {
        $childVal = Get-NodeValue $Node.Left $Steps
        $res = (-1 * $childVal)
        $Node.Val = $res
        [void]$Steps.Add([pscustomobject]@{ Node = $Node; Op = 'neg'; L = $childVal; R = $null; Result = $res })
        return $res
    }
    $l = Get-NodeValue $Node.Left $Steps
    $r = Get-NodeValue $Node.Right $Steps
    $res = [System.Numerics.BigInteger]::Zero
    switch ($Node.Op) {
        '+' { $res = $l + $r }
        '-' { $res = $l - $r }
        '*' { $res = $l * $r }
        '/' {
            if ($r.Sign -eq 0) { throw 'деление на ноль внутри выражения' }
            $rem = [System.Numerics.BigInteger]::Zero
            $res = [System.Numerics.BigInteger]::DivRem($l, $r, [ref]$rem)
        }
    }
    $Node.Val = $res
    [void]$Steps.Add([pscustomobject]@{ Node = $Node; Op = $Node.Op; L = $l; R = $r; Result = $res })
    return $res
}

# ================== СЛОЖНЫЕ ВЫРАЖЕНИЯ: АНИМАЦИЯ ШАГА ======================
function Show-StepNeg {
    param($L, [int]$Index, [int]$Total)
    $res = (-1 * $L)
    WL ''
    WL ('  ' + $P.Wht + $P.B + ('ШАГ ' + $Index + '/' + $Total + '  ·  смена знака') + $P.R + $P.Dim + '   меняем знак у ' + $P.R + $P.Wht + (Fmt-Num $L) + $P.R + $P.Dim + '  →  ' + $P.R + $P.Grn + $P.B + (Format-Dec $res) + $P.R)
    WL ''
    if ($res.Sign -lt 0) {
        Show-TwosComplement $res
    }
    else {
        WL ('  ' + $P.Dim + 'минус на минус даёт плюс → ' + $P.R + $P.Grn + $P.B + (Format-Dec $res) + $P.R + $P.Dim + '  =  ' + $P.R + $P.Grn + (Format-Bin (Trim-Bin (ToBinStr $res))) + '₂' + $P.R)
        WL ''
    }
}

function Show-StepOp {
    param(
        [System.Numerics.BigInteger]$L,
        $R,
        [string]$Op,
        [int]$Index,
        [int]$Total
    )
    if ($Op -eq 'neg') { Show-StepNeg -L $L -Index $Index -Total $Total; return }

    $opSym = Format-OpSym $Op
    $absL = [System.Numerics.BigInteger]::Abs($L)
    $absR = [System.Numerics.BigInteger]::Abs($R)
    $binL = Trim-Bin (ToBinStr $absL)
    $binR = Trim-Bin (ToBinStr $absR)
    $sL = Get-Sign $L
    $sR = Get-Sign $R
    $title = 'ШАГ ' + $Index + '/' + $Total + '  ·  ' + (Fmt-Num $L) + ' ' + $opSym + ' ' + (Fmt-Num $R)

    if ($Op -eq '+' -or $Op -eq '-') {
        $srEff = $sR
        if ($Op -eq '-') { $srEff = -1 * $sR }
        if ($sL -eq 0 -or $srEff -eq 0) {
            WL ''
            WL ('  ' + $P.Wht + $P.B + $title + $P.R)
            WL ('  ' + $P.Dim + 'один из операндов равен нулю — значение не меняется' + $P.R)
            WL ''
            return
        }
        if ($sL -eq $srEff) {
            $note = ''
            if ($sL -lt 0) { $note = 'оба операнда отрицательные → складываем модули, знак минус' }
            Show-Sum -Rows @($binL, $binR) -Ops @(' ', '+') -Title $title
            if ($note -ne '') { WL ('  ' + $P.Dim + $note + $P.R); WL '' }
        }
        else {
            if ($sL -lt 0 -or $sR -lt 0) {
                WL ''
                WL ('  ' + $P.Dim + 'знаки разные → из большего модуля вычитаем меньший' + $P.R)
            }
            if ($absL -ge $absR) { $bigBin = $binL; $smallBin = $binR }
            else { $bigBin = $binR; $smallBin = $binL }
            Show-Sub -A $bigBin -B $smallBin -Title $title
        }
        return
    }

    if ($Op -eq '*') {
        if ($sL -eq 0 -or $sR -eq 0) {
            WL ''
            WL ('  ' + $P.Wht + $P.B + $title + $P.R)
            WL ('  ' + $P.Dim + 'умножение на ноль → результат 0' + $P.R)
            WL ''
            return
        }
        Show-Mul -A $binL -B $binR -Product ($absL * $absR) -Title $title
        if (($sL * $sR) -lt 0) {
            WL ('  ' + $P.Dim + 'знак результата: ' + $P.R + $P.Red + 'минус' + $P.R)
            WL ''
        }
        return
    }

    if ($Op -eq '/') {
        if ($sR -eq 0) { throw 'деление на ноль' }
        $divInfo = Show-Div -A $binL -B $binR -Title $title
        if (($sL * $sR) -lt 0) {
            WL ('  ' + $P.Dim + 'знак результата: ' + $P.R + $P.Red + 'минус' + $P.R)
            WL ''
        }
        if ($null -ne $divInfo -and $divInfo.Remainder.Sign -ne 0) {
            WL ('  ' + $P.Dim + 'остаток ' + $P.R + $P.Amb + (Format-Dec $divInfo.Remainder) + $P.R + $P.Dim + ' отбрасывается — деление целочисленное' + $P.R)
            WL ''
        }
        return
    }
}

function Show-StepsLog($Steps) {
    if ($Steps.Count -eq 0) { return }
    $lines = @()
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $st = $Steps[$i]
        $binAbs = Trim-Bin (ToBinStr ([System.Numerics.BigInteger]::Abs([System.Numerics.BigInteger]$st.Result)))
        if ($st.Op -eq 'neg') {
            $txt = ([string]($i + 1) + ')  −(' + (Format-Dec $st.L) + ') = ' + (Format-Dec $st.Result))
        }
        else {
            $txt = ([string]($i + 1) + ')  ' + (Fmt-Num $st.L) + ' ' + (Format-OpSym $st.Op) + ' ' + (Fmt-Num $st.R) + ' = ' + (Format-Dec $st.Result))
        }
        $signPrefix = ''
        if ($st.Result.Sign -lt 0) { $signPrefix = '-' }
        $line = $P.Wht + $txt.PadRight(28) + $P.R + $P.Dim + '  ' + $P.R + $P.Grn + $signPrefix + (Format-Bin $binAbs) + '₂' + $P.R
        if ((Get-VisLen $line) -gt ($script:Cols - 8)) { $line = Trim-Msg $line ($script:Cols - 12) }
        $lines += $line
    }
    Show-Panel -Lines $lines -Title 'ХОД ВЫЧИСЛЕНИЙ' -Border $P.Blue
}

# ===================== СЛОЖНЫЕ ВЫРАЖЕНИЯ: ДВИЖОК ===========================
# Если после разбора получилась одна операция над двумя числами —
# отправляем в «красивый» одиночный путь (с таблицами перевода).
function Convert-AstToParsed($Ast) {
    if ($Ast.Kind -ne 'op') { return $null }
    if ($Ast.Left.Kind -ne 'num' -or $Ast.Right.Kind -ne 'num') { return $null }
    $la = $Ast.Left
    $ra = $Ast.Right
    $sa = 1
    if ($la.Val.Sign -lt 0) { $sa = -1 }
    $sb = 1
    if ($ra.Val.Sign -lt 0) { $sb = -1 }
    $numA = [pscustomobject]@{
        Raw = $la.Raw; Kind = $la.KindNum; Bin = $la.Bin
        Value = [System.Numerics.BigInteger]::Abs($la.Val)
    }
    $numB = [pscustomobject]@{
        Raw = $ra.Raw; Kind = $ra.KindNum; Bin = $ra.Bin
        Value = [System.Numerics.BigInteger]::Abs($ra.Val)
    }
    return [pscustomobject]@{
        A = $la.Val; B = $ra.Val; NumA = $numA; NumB = $numB
        SignA = $sa; SignB = $sb; Op = $Ast.Op
    }
}

function Invoke-ExprEngine([string]$text) {
    $ast = Build-Ast $text

    $simple = Convert-AstToParsed $ast
    if ($null -ne $simple) {
        Invoke-SimpleOp $simple
        return $simple.A
    }

    $steps = New-Object System.Collections.ArrayList
    $value = Get-NodeValue $ast $steps
    $n = $steps.Count

    WL ''
    Out-Line ('  ' + $P.Dim + 'выражение:  ' + $P.R + (Format-Tree $ast))
    if ($n -le 1) {
        Out-Line ('  ' + $P.Dim + 'порядок: скобки, затем × и ÷, потом + и −' + $P.R)
    }
    else {
        Out-Line ('  ' + $P.Dim + 'порядок: скобки, затем × и ÷, потом + и − слева направо' + $P.R)
    }
    Out-Line ('  ' + $P.Dim + 'шагов вычисления: ' + $P.R + $P.Wht + $n + $P.R)
    WL ''

    $hadDivisionWithRemainder = $false
    for ($k = 0; $k -lt $n; $k++) {
        $st = $steps[$k]
        Out-Line ('  ' + $P.Amb + $P.B + '▸ ' + $P.R + (Format-Tree $ast '' 'L' $st.Node.Id))
        if ($st.Op -eq 'neg') {
            Show-StepNeg -L $st.L -Index ($k + 1) -Total $n
        }
        else {
            Show-StepOp -L $st.L -R $st.R -Op $st.Op -Index ($k + 1) -Total $n
        }
        $st.Node.Done = $true

        if ($st.Op -eq '/' -and $st.Result.Sign -ne 0) {
            $remCheck = [System.Numerics.BigInteger]::Zero
            [void][System.Numerics.BigInteger]::DivRem($st.L, $st.R, [ref]$remCheck)
            if ($remCheck.Sign -ne 0) { $hadDivisionWithRemainder = $true }
        }

        $binAbs = Trim-Bin (ToBinStr ([System.Numerics.BigInteger]::Abs([System.Numerics.BigInteger]$st.Result)))
        $signPrefix = ''
        if ($st.Result.Sign -lt 0) { $signPrefix = '-' }
        Out-Line ('  ' + $P.Dim + 'после шага ' + ($k + 1) + ':  ' + $P.R + $P.Grn + $P.B + (Format-Dec $st.Result) + $P.R + $P.Dim + '  =  ' + $P.R + $P.Grn + $signPrefix + (Format-Bin $binAbs) + '₂' + $P.R)
        Out-Line ('  ' + $P.Dim + 'стало:  ' + $P.R + (Format-Tree $ast))
        WL ''
    }

    Show-StepsLog $steps

    if ($n -eq 0) {
        WL ('  ' + $P.Dim + 'это просто число, вычислять нечего' + $P.R)
        WL ''
    }

    $extra = ''
    if ($hadDivisionWithRemainder) { $extra = 'деление целочисленное — остатки отбрасывались' }
    Show-Result -ExprText $text -DecResult $value -BinResult (Trim-Bin (ToBinStr ([System.Numerics.BigInteger]::Abs($value)))) -Extra $extra
    if ($value.Sign -lt 0) { Show-TwosComplement $value }
    return $value
}

# ============================== ГЛАВНЫЙ ВЫЗОВ ==============================
function Invoke-SimpleOp($parsed) {
    switch ($parsed.Op) {
        '+' { Invoke-AddSub $parsed | Out-Null }
        '-' { Invoke-AddSub $parsed | Out-Null }
        '*' { Invoke-Mul $parsed | Out-Null }
        '/' { Invoke-Div $parsed | Out-Null }
        default { throw ('неизвестная операция "' + $parsed.Op + '"') }
    }
}

function Invoke-Calc([string]$text) {
    $script:PrevLines = 0
    WL ''
    WL ($P.Dim + ('─' * [Math]::Max(10, $script:Cols - 4)) + $P.R)
    $simple = $null
    try { $simple = Parse-Expr $text } catch { $simple = $null }
    if ($null -ne $simple) {
        Invoke-SimpleOp $simple
    }
    else {
        Invoke-ExprEngine $text | Out-Null
    }
    WL ($P.Dim + ('─' * [Math]::Max(10, $script:Cols - 4)) + $P.R)
    WL ''
}

# ================================ ЦИКЛ =====================================
$script:InputRedirected = $false
try { $script:InputRedirected = [Console]::IsInputRedirected } catch { }

function Read-Expression {
    W ('  ' + $P.Cyan + $P.B + '▸ ' + $P.R)
    $line = $null
    try {
        $line = Read-Host
    }
    catch {
        return $null
    }
    if ($null -eq $line) { return $null }
    # при перенаправленном вводе пустая строка означает конец потока
    if ($line -eq '' -and $script:InputRedirected) { return $null }
    return $line
}

# ---------------------------------- main -----------------------------------
if ($Demo) {
    Show-Banner
    foreach ($ex in @('2+5', '2+2*2-2+2', '(2+3)*4', '0b1011*0b110', '255/7')) {
        try { Invoke-Calc $ex } catch { Show-ErrorPanel $_.Exception.Message }
        if ($script:Interactive) { Start-Sleep -Milliseconds 250 }
    }
    Show-Bye
    return
}

if ($Expression -ne '') {
    Show-Banner
    try { Invoke-Calc $Expression } catch { Show-ErrorPanel $_.Exception.Message }
    Show-Bye
    return
}

Show-Banner
Show-Hints

while ($true) {
    $line = Read-Expression
    if ($null -eq $line) { break }
    $t = $line.Trim()
    if ($t -eq '') { continue }
    if ($t -match '^(q|quit|exit|выход|й|\.)$') { break }
    try {
        Invoke-Calc $t
    }
    catch {
        Show-ErrorPanel $_.Exception.Message
    }
}

Show-Bye
