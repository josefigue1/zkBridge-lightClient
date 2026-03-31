#!/usr/bin/env python3
"""
Circuit Compilation Dashboard
=============================
Real-time monitoring dashboard for circuit compilation.
Shows: CPU, Memory, Disk I/O, compilation stages, and progress.

Usage:
    ./dashboard.py                    # Monitor current/recent compilation
    ./dashboard.py --run-128          # Run and monitor 128-validator build
    ./dashboard.py --run-128-mini     # Run and monitor 128-mini build
    ./dashboard.py --run-mini         # Run and monitor mini (3-part) build
    ./dashboard.py --history          # Show compilation history
    ./dashboard.py --help             # Show help
"""

import os
import sys
import time
import shutil
import signal
import argparse
import subprocess
from pathlib import Path
from typing import Optional, Tuple, Dict

# Try to import psutil for better system metrics
try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR = Path(__file__).parent.absolute()
STATUS_FILE = SCRIPT_DIR / ".dashboard_status"
HISTORY_FILE = SCRIPT_DIR / ".dashboard_history"
METRICS_FILE = SCRIPT_DIR / ".dashboard_metrics"
PID_FILE = SCRIPT_DIR / ".dashboard_pid"

# =============================================================================
# Colors and Formatting (ANSI escape codes)
# =============================================================================

class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    MAGENTA = '\033[0;35m'
    WHITE = '\033[1;37m'
    GRAY = '\033[0;90m'
    NC = '\033[0m'  # No Color
    BOLD = '\033[1m'
    DIM = '\033[2m'


class Terminal:
    HIDE_CURSOR = '\033[?25l'
    SHOW_CURSOR = '\033[?25h'
    CLEAR_SCREEN = '\033[2J'
    HOME = '\033[H'
    CLEAR_LINE = '\033[K'


# =============================================================================
# System Metrics
# =============================================================================

def get_cpu_usage() -> float:
    """Get current CPU usage percentage."""
    if HAS_PSUTIL:
        return psutil.cpu_percent(interval=0.1)

    # Fallback for macOS/Linux without psutil
    if sys.platform == 'darwin':
        try:
            result = subprocess.run(
                ['top', '-l', '1', '-n', '0'],
                capture_output=True, text=True, timeout=5
            )
            for line in result.stdout.split('\n'):
                if 'CPU usage' in line:
                    parts = line.split()
                    for i, part in enumerate(parts):
                        if part.endswith('%') and i > 0:
                            return float(part.rstrip('%'))
        except Exception:
            pass
    return 0.0


def get_memory_info() -> Tuple[float, float]:
    """Get memory usage (used_gb, total_gb)."""
    if HAS_PSUTIL:
        mem = psutil.virtual_memory()
        used_gb = (mem.total - mem.available) / (1024 ** 3)
        total_gb = mem.total / (1024 ** 3)
        return used_gb, total_gb

    # Fallback for macOS
    if sys.platform == 'darwin':
        try:
            result = subprocess.run(
                ['sysctl', '-n', 'hw.memsize'],
                capture_output=True, text=True, timeout=5
            )
            total_bytes = int(result.stdout.strip())
            total_gb = total_bytes / (1024 ** 3)

            result = subprocess.run(['vm_stat'], capture_output=True, text=True, timeout=5)
            stats = {}
            for line in result.stdout.split('\n'):
                if ':' in line:
                    key, val = line.split(':', 1)
                    val = val.strip().rstrip('.')
                    if val.isdigit():
                        stats[key.strip()] = int(val)

            page_size = 16384  # Default page size
            active = stats.get('Pages active', 0)
            wired = stats.get('Pages wired down', 0)
            compressed = stats.get('Pages occupied by compressor', 0)
            used_pages = active + wired + compressed
            used_gb = (used_pages * page_size) / (1024 ** 3)

            return used_gb, total_gb
        except Exception:
            pass

    return 0.0, 0.0


def get_swap_info() -> Tuple[float, float]:
    """Get swap usage (used_mb, total_mb)."""
    if HAS_PSUTIL:
        swap = psutil.swap_memory()
        return swap.used / (1024 ** 2), swap.total / (1024 ** 2)

    if sys.platform == 'darwin':
        try:
            result = subprocess.run(
                ['sysctl', '-n', 'vm.swapusage'],
                capture_output=True, text=True, timeout=5
            )
            parts = result.stdout.split()
            total_mb = used_mb = 0.0
            for i, p in enumerate(parts):
                if p == 'total' and i + 2 < len(parts):
                    total_mb = float(parts[i + 2].rstrip('M'))
                elif p == 'used' and i + 2 < len(parts):
                    used_mb = float(parts[i + 2].rstrip('M'))
            return used_mb, total_mb
        except Exception:
            pass

    return 0.0, 0.0


def get_load_average() -> float:
    """Get 1-minute load average."""
    try:
        return os.getloadavg()[0]
    except (OSError, AttributeError):
        return 0.0


# =============================================================================
# Status File Functions
# =============================================================================

def read_status() -> Dict[str, str]:
    """Read the dashboard status file."""
    status = {}
    if STATUS_FILE.exists():
        try:
            with open(STATUS_FILE, 'r') as f:
                for line in f:
                    line = line.strip()
                    if '=' in line:
                        key, value = line.split('=', 1)
                        status[key] = value
        except Exception:
            pass
    return status


def write_status(status: Dict[str, str]) -> None:
    """Write the dashboard status file."""
    try:
        with open(STATUS_FILE, 'w') as f:
            for key, value in status.items():
                f.write(f"{key}={value}\n")
    except Exception:
        pass


def update_status(key: str, value: str) -> None:
    """Update a single key in the status file."""
    status = read_status()
    status[key] = value
    write_status(status)


def init_status(mode: str, total_parts: int = 8) -> None:
    """Initialize the dashboard status."""
    status = {
        'MODE': mode,
        'STAGE': 'initializing',
        'PART': '',
        'STEP': '',
        'START_TIME': str(int(time.time())),
        'TOTAL_PARTS': str(total_parts),
        'COMPLETED_PARTS': '0',
        'CURRENT_CONSTRAINTS': '0',
        'PEAK_MEMORY': '0',
        'ERRORS': '0',
        'WARNINGS': '0',
        'LOG_FILE': str(SCRIPT_DIR / 'logs' / 'current.log'),
    }
    write_status(status)


# =============================================================================
# Terminal Size
# =============================================================================

def get_terminal_size() -> Tuple[int, int]:
    """Get terminal size (columns, rows)."""
    try:
        size = shutil.get_terminal_size()
        return size.columns, size.lines
    except Exception:
        return 80, 24  # Default fallback


# =============================================================================
# UI Drawing Functions
# =============================================================================

def draw_progress_bar(current: int, total: int, width: int = 40) -> str:
    """Draw a text-based progress bar."""
    if total == 0:
        total = 1
    percent = current * 100 // total
    filled = current * width // total
    empty = width - filled
    bar = '\u2588' * filled + '\u2591' * empty
    return f"[{bar}] {percent:3d}%"


def draw_metric_bar(value: float, max_val: float, width: int = 25, color: str = "") -> str:
    """Draw a metric bar with color."""
    if max_val == 0:
        max_val = 1
    filled = int(value * width / max_val)
    filled = min(filled, width)
    empty = width - filled
    bar = '\u2593' * filled + '\u2591' * empty
    if color:
        return f"{color}{bar}{Colors.NC}"
    return bar


def format_duration(seconds: int) -> str:
    """Format seconds as HH:MM:SS."""
    hours = seconds // 3600
    mins = (seconds % 3600) // 60
    secs = seconds % 60
    return f"{hours:02d}:{mins:02d}:{secs:02d}"


def get_color_for_percent(percent: float, warn: float = 70, crit: float = 90) -> str:
    """Get color based on percentage thresholds."""
    if percent > crit:
        return Colors.RED
    elif percent > warn:
        return Colors.YELLOW
    return Colors.GREEN


# =============================================================================
# Dashboard Sections
# =============================================================================

def visible_len(s: str) -> int:
    """Get visible length of string (excluding ANSI escape codes)."""
    import re
    ansi_escape = re.compile(r'\x1b\[[0-9;]*m')
    return len(ansi_escape.sub('', s))


def pad_line(content: str, width: int, left_border: str = "", right_border: str = "") -> str:
    """Pad a line to fill the width, accounting for ANSI codes."""
    visible = visible_len(content)
    padding = width - visible - visible_len(left_border) - visible_len(right_border)
    if padding < 0:
        padding = 0
    return f"{left_border}{content}{' ' * padding}{right_border}"


def draw_header(status: Dict[str, str], width: int = 70) -> str:
    """Draw the dashboard header."""
    mode = status.get('MODE', 'N/A')
    stage = status.get('STAGE', 'idle')

    inner_width = width - 2  # Account for border characters
    title = "\u26a1 CIRCUIT COMPILATION DASHBOARD"

    title_content = f"  {Colors.BOLD}{Colors.WHITE}{title}{Colors.NC}"
    info_content = f"  {Colors.GRAY}Mode: {Colors.CYAN}{mode}{Colors.NC}  {Colors.GRAY}Stage: {Colors.YELLOW}{stage}{Colors.NC}"

    lines = [
        f"{Colors.BLUE}\u2554{'═' * inner_width}\u2557{Colors.NC}",
        pad_line(title_content, inner_width, f"{Colors.BLUE}\u2551{Colors.NC}", f"{Colors.BLUE}\u2551{Colors.NC}"),
        pad_line(info_content, inner_width, f"{Colors.BLUE}\u2551{Colors.NC}", f"{Colors.BLUE}\u2551{Colors.NC}"),
        f"{Colors.BLUE}\u255a{'═' * inner_width}\u255d{Colors.NC}",
    ]
    return '\n'.join(lines)


def draw_system_metrics(status: Dict[str, str], width: int = 70) -> str:
    """Draw system metrics section."""
    cpu = get_cpu_usage()
    mem_used, mem_total = get_memory_info()
    swap_used, swap_total = get_swap_info()
    load = get_load_average()

    # Update peak memory
    peak_mem = float(status.get('PEAK_MEMORY', '0'))
    if mem_used > peak_mem:
        update_status('PEAK_MEMORY', f"{mem_used:.1f}")
        peak_mem = mem_used

    inner_width = width - 2
    title = " SYSTEM METRICS "
    title_dashes = inner_width - len(title) - 1
    bar_width = max(15, min(40, width - 35))  # Adaptive bar width

    left_border = f"{Colors.WHITE}\u2502{Colors.NC}"
    right_border = f"{Colors.WHITE}\u2502{Colors.NC}"

    lines = [
        "",
        f"{Colors.WHITE}{Colors.BOLD}\u250c\u2500{title}{'─' * title_dashes}\u2510{Colors.NC}",
        pad_line("", inner_width, left_border, right_border),
    ]

    # CPU
    cpu_color = get_color_for_percent(cpu, 50, 80)
    cpu_bar = draw_metric_bar(cpu, 100, bar_width, cpu_color)
    cpu_line = f"  {Colors.CYAN}CPU:{Colors.NC}    {cpu_bar} {cpu_color}{cpu:5.1f}%{Colors.NC}"
    lines.append(pad_line(cpu_line, inner_width, left_border, right_border))

    # Memory
    mem_percent = (mem_used / mem_total * 100) if mem_total > 0 else 0
    mem_color = get_color_for_percent(mem_percent)
    mem_bar = draw_metric_bar(mem_percent, 100, bar_width, mem_color)
    mem_line = f"  {Colors.CYAN}Memory:{Colors.NC} {mem_bar} {mem_color}{mem_used:5.1f}{Colors.NC}/{Colors.WHITE}{mem_total:.0f} GB{Colors.NC}"
    lines.append(pad_line(mem_line, inner_width, left_border, right_border))

    # Swap (only if used)
    if swap_total > 0:
        swap_percent = (swap_used / swap_total * 100) if swap_total > 0 else 0
        swap_color = get_color_for_percent(swap_percent, 50, 80)
        swap_bar = draw_metric_bar(swap_percent, 100, bar_width, swap_color)
        swap_line = f"  {Colors.CYAN}Swap:{Colors.NC}   {swap_bar} {swap_color}{swap_used:5.0f}{Colors.NC}/{Colors.WHITE}{swap_total:.0f} MB{Colors.NC}"
        lines.append(pad_line(swap_line, inner_width, left_border, right_border))

    # Load and peak memory
    load_line = f"  {Colors.CYAN}Load:{Colors.NC}   {Colors.WHITE}{load:.2f}{Colors.NC}  {Colors.GRAY}Peak Mem: {Colors.MAGENTA}{peak_mem:.1f} GB{Colors.NC}"
    lines.append(pad_line(load_line, inner_width, left_border, right_border))

    lines.extend([
        pad_line("", inner_width, left_border, right_border),
        f"{Colors.WHITE}\u2514{'─' * inner_width}\u2518{Colors.NC}",
    ])

    return '\n'.join(lines)


def draw_compilation_progress(status: Dict[str, str], width: int = 70) -> str:
    """Draw compilation progress section."""
    stage = status.get('STAGE', 'idle')
    part = status.get('PART', '')
    step = status.get('STEP', '')
    total_parts = int(status.get('TOTAL_PARTS', '8'))
    completed_parts = int(status.get('COMPLETED_PARTS', '0'))
    start_time = int(status.get('START_TIME', '0'))
    constraints = status.get('CURRENT_CONSTRAINTS', '0')

    inner_width = width - 2
    title = " COMPILATION PROGRESS "
    title_dashes = inner_width - len(title) - 1
    progress_bar_width = max(30, min(60, width - 20))

    left_border = f"{Colors.WHITE}\u2502{Colors.NC}"
    right_border = f"{Colors.WHITE}\u2502{Colors.NC}"

    lines = [
        "",
        f"{Colors.WHITE}{Colors.BOLD}\u250c\u2500{title}{'─' * title_dashes}\u2510{Colors.NC}",
        pad_line("", inner_width, left_border, right_border),
    ]

    # Overall progress bar
    progress_bar = draw_progress_bar(completed_parts, total_parts, progress_bar_width)
    lines.append(pad_line(f"  Overall {progress_bar}", inner_width, left_border, right_border))
    lines.append(pad_line("", inner_width, left_border, right_border))

    # Parts status
    lines.append(pad_line(f"  {Colors.BOLD}Parts Status:{Colors.NC}", inner_width, left_border, right_border))

    parts = ["1A", "1B", "1C", "1D", "1E", "2", "3A", "3B"]
    part_symbols = []

    # Normalize part name for comparison (e.g., "part1c" -> "1C")
    current_part_normalized = part.lower().replace('part', '').upper() if part else ''

    for i, p in enumerate(parts):
        if i < completed_parts:
            part_symbols.append(f"{Colors.GREEN}\u2713{Colors.NC}")
        elif p == current_part_normalized or (part and p.lower() in part.lower()):
            part_symbols.append(f"{Colors.YELLOW}\u25cf{Colors.NC}")
        else:
            part_symbols.append(f"{Colors.GRAY}\u25cb{Colors.NC}")

    # Extract Unicode strings to avoid backslash issues in f-strings (Python 3.8 compatibility)
    top_segment = '──────\u252c'
    bottom_segment = '──────\u2534'
    lines.append(pad_line(f"  \u250c{top_segment * 7}──────\u2510", inner_width, left_border, right_border))
    parts_row = "  \u2502"
    for i, p in enumerate(parts):
        parts_row += f" {part_symbols[i]} {p:<2} \u2502"
    lines.append(pad_line(parts_row, inner_width, left_border, right_border))
    lines.append(pad_line(f"  \u2514{bottom_segment * 7}──────\u2518", inner_width, left_border, right_border))

    lines.append(pad_line("", inner_width, left_border, right_border))

    # Current activity
    if stage and stage not in ('idle', 'complete'):
        lines.append(pad_line(f"  {Colors.BOLD}Current Activity:{Colors.NC}", inner_width, left_border, right_border))
        lines.append(pad_line(f"    Stage: {Colors.CYAN}{stage}{Colors.NC}", inner_width, left_border, right_border))
        if part:
            # Format part name nicely (e.g., "part1c" -> "Part 1C")
            part_display = part.replace('part', 'Part ').replace('Part ', 'Part ').upper()
            if 'PART' in part_display:
                part_display = 'Part ' + part_display.replace('PART ', '').replace('PART', '')
            lines.append(pad_line(f"    Part:  {Colors.YELLOW}{part_display}{Colors.NC}", inner_width, left_border, right_border))
        if step:
            lines.append(pad_line(f"    Step:  {Colors.WHITE}{step}{Colors.NC}", inner_width, left_border, right_border))
        if constraints and constraints != '0':
            try:
                constraints_formatted = f"{int(constraints):,}"
                lines.append(pad_line(f"    Constraints: {Colors.MAGENTA}{constraints_formatted}{Colors.NC}", inner_width, left_border, right_border))
            except ValueError:
                pass
    elif stage == 'complete':
        lines.append(pad_line(f"  {Colors.GREEN}{Colors.BOLD}\u2713 COMPILATION COMPLETE{Colors.NC}", inner_width, left_border, right_border))
    else:
        lines.append(pad_line(f"  {Colors.GRAY}Waiting for compilation to start...{Colors.NC}", inner_width, left_border, right_border))

    lines.append(pad_line("", inner_width, left_border, right_border))

    # Elapsed time
    if start_time > 0:
        elapsed = int(time.time()) - start_time
        lines.append(pad_line(f"  {Colors.BOLD}Elapsed:{Colors.NC} {format_duration(elapsed)}", inner_width, left_border, right_border))

    lines.extend([
        pad_line("", inner_width, left_border, right_border),
        f"{Colors.WHITE}\u2514{'─' * inner_width}\u2518{Colors.NC}",
    ])

    return '\n'.join(lines)


def draw_log_tail(status: Dict[str, str], width: int = 70, num_lines: int = 10) -> str:
    """Draw recent log output section."""
    log_file = status.get('LOG_FILE', '')

    inner_width = width - 2
    title = " RECENT LOG OUTPUT "
    title_dashes = inner_width - len(title) - 1
    max_line_len = inner_width - 4  # Account for border and padding

    left_border = f"{Colors.WHITE}\u2502{Colors.NC}"
    right_border = f"{Colors.WHITE}\u2502{Colors.NC}"

    lines = [
        "",
        f"{Colors.WHITE}{Colors.BOLD}\u250c\u2500{title}{'─' * title_dashes}\u2510{Colors.NC}",
    ]

    if log_file and Path(log_file).exists():
        try:
            with open(log_file, 'r') as f:
                log_lines = f.readlines()[-num_lines:]
            for line in log_lines:
                line = line.strip()
                if len(line) > max_line_len:
                    line = line[:max_line_len - 3] + "..."
                lines.append(pad_line(f"  {Colors.GRAY}{line}{Colors.NC}", inner_width, left_border, right_border))
            # Pad with empty lines if needed
            for _ in range(num_lines - len(log_lines)):
                lines.append(pad_line("", inner_width, left_border, right_border))
        except Exception:
            lines.append(pad_line(f"  {Colors.GRAY}Error reading log file{Colors.NC}", inner_width, left_border, right_border))
            for _ in range(num_lines - 1):
                lines.append(pad_line("", inner_width, left_border, right_border))
    else:
        lines.append(pad_line(f"  {Colors.GRAY}No log file available{Colors.NC}", inner_width, left_border, right_border))
        for _ in range(num_lines - 1):
            lines.append(pad_line("", inner_width, left_border, right_border))

    lines.append(f"{Colors.WHITE}\u2514{'─' * inner_width}\u2518{Colors.NC}")

    return '\n'.join(lines)


def draw_help() -> str:
    """Draw help text."""
    return f"\n{Colors.GRAY}  Press {Colors.WHITE}q{Colors.GRAY} to quit | {Colors.WHITE}r{Colors.GRAY} to refresh | {Colors.WHITE}h{Colors.GRAY} for help{Colors.NC}"


# =============================================================================
# Main Dashboard
# =============================================================================

class Dashboard:
    def __init__(self):
        self.running = True
        signal.signal(signal.SIGINT, self._handle_signal)
        signal.signal(signal.SIGTERM, self._handle_signal)
        self.old_settings = None

    def _handle_signal(self, _signum, _frame):
        self.running = False

    def _setup_terminal(self):
        """Setup terminal for dashboard display."""
        print(Terminal.HIDE_CURSOR, end='', flush=True)
        try:
            import tty
            import termios
            self.old_settings = termios.tcgetattr(sys.stdin)
            tty.setcbreak(sys.stdin.fileno())
        except Exception:
            self.old_settings = None

    def _restore_terminal(self):
        """Restore terminal settings."""
        print(Terminal.SHOW_CURSOR, end='', flush=True)
        if self.old_settings:
            try:
                import termios
                termios.tcsetattr(sys.stdin, termios.TCSADRAIN, self.old_settings)
            except Exception:
                pass

    def _check_input(self) -> Optional[str]:
        """Check for keyboard input (non-blocking)."""
        try:
            import select
            if select.select([sys.stdin], [], [], 0)[0]:
                return sys.stdin.read(1)
        except Exception:
            pass
        return None

    def draw(self) -> str:
        """Draw the complete dashboard."""
        status = read_status()
        term_cols, term_rows = get_terminal_size()

        # Calculate adaptive width (min 60, max terminal width - 2)
        width = max(60, min(term_cols - 2, 120))

        # Calculate log lines based on terminal height
        # Header ~4, Metrics ~8, Progress ~18, Help ~2 = ~32 fixed lines
        log_lines = max(5, term_rows - 35)

        output = []
        output.append(Terminal.HOME + Terminal.CLEAR_SCREEN)
        output.append(draw_header(status, width))
        output.append(draw_system_metrics(status, width))
        output.append(draw_compilation_progress(status, width))
        output.append(draw_log_tail(status, width, log_lines))
        output.append(draw_help())

        return '\n'.join(output)

    def run(self):
        """Run the dashboard loop."""
        self._setup_terminal()

        try:
            while self.running:
                print(self.draw(), flush=True)

                # Check for input with timeout
                for _ in range(10):  # 1 second total (10 x 0.1s)
                    key = self._check_input()
                    if key:
                        if key.lower() == 'q':
                            self.running = False
                            break
                        elif key.lower() == 'r':
                            break  # Force refresh
                        elif key.lower() == 'h':
                            print(f"\n{Colors.CYAN}Dashboard Help:{Colors.NC}")
                            print(f"  {Colors.WHITE}q{Colors.NC} - Quit dashboard")
                            print(f"  {Colors.WHITE}r{Colors.NC} - Force refresh")
                            print(f"  {Colors.WHITE}h{Colors.NC} - Show this help")
                            time.sleep(2)
                            break
                    time.sleep(0.1)
        finally:
            self._restore_terminal()


# =============================================================================
# Build Wrapper Functions
# =============================================================================

def run_with_monitoring(script: str, mode: str):
    """Run a build script while monitoring with the dashboard."""
    import threading
    import re

    init_status(mode)

    script_path = SCRIPT_DIR / script
    if not script_path.exists():
        print(f"Error: Script not found: {script_path}")
        sys.exit(1)

    # Create logs directory
    (SCRIPT_DIR / 'logs').mkdir(exist_ok=True)
    log_file = SCRIPT_DIR / 'logs' / 'current.log'

    print(f"Starting build: {script}")

    # Start build in background
    process = subprocess.Popen(
        [str(script_path), '--compile-only'],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    # Save PID
    with open(PID_FILE, 'w') as f:
        f.write(str(process.pid))

    update_status('STAGE', 'starting')
    update_status('LOG_FILE', str(log_file))

    def read_output():
        with open(log_file, 'w') as log:
            for line in process.stdout:
                log.write(line)
                log.flush()

                # Parse output to update status
                # Look for part names like "part1a", "part1c", "Part 1C", etc.
                part_match = re.search(r'[Pp]art\s*(\d+[a-eA-E]?)', line)
                if part_match:
                    update_status('STAGE', 'compiling')
                    part_name = 'part' + part_match.group(1).lower()
                    update_status('PART', part_name)

                if 'constraints' in line.lower():
                    match = re.search(r'(\d+)\s*constraints', line)
                    if match:
                        update_status('CURRENT_CONSTRAINTS', match.group(1))

                if 'compiled' in line.lower() or 'Compiled' in line:
                    status = read_status()
                    completed = int(status.get('COMPLETED_PARTS', '0'))
                    update_status('COMPLETED_PARTS', str(completed + 1))

                if 'Generating witness' in line:
                    update_status('STAGE', 'witness')
                    update_status('STEP', 'generating witness')

                if 'zkey' in line.lower():
                    update_status('STAGE', 'trusted_setup')
                    update_status('STEP', 'generating zkey')

                if 'proof' in line.lower():
                    update_status('STAGE', 'proving')
                    update_status('STEP', 'generating proof')

                if 'Done' in line or 'success' in line.lower():
                    update_status('STAGE', 'complete')

        update_status('STAGE', 'complete')

    reader_thread = threading.Thread(target=read_output, daemon=True)
    reader_thread.start()

    # Run dashboard
    dashboard = Dashboard()
    dashboard.run()

    # Cleanup
    process.terminate()
    if PID_FILE.exists():
        PID_FILE.unlink()


# =============================================================================
# History Functions
# =============================================================================

def show_history():
    """Show compilation history."""
    print(f"{Colors.BLUE}{Colors.BOLD}Compilation History{Colors.NC}")
    separator = '\u2500' * 45
    print(f"{Colors.GRAY}{separator}{Colors.NC}")

    if HISTORY_FILE.exists():
        with open(HISTORY_FILE, 'r') as f:
            lines = f.readlines()[-20:]
            for line in lines:
                print(line.rstrip())
    else:
        print(f"{Colors.GRAY}No compilation history available{Colors.NC}")


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Circuit Compilation Dashboard',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Controls (during monitoring):
  q - Quit dashboard
  r - Force refresh
  h - Show help

Examples:
  %(prog)s                    # Monitor current compilation
  %(prog)s --run-128-mini     # Run and monitor 128-mini build
"""
    )

    parser.add_argument('--run-128', action='store_true',
                        help='Run and monitor 128-validator build')
    parser.add_argument('--run-128-mini', action='store_true',
                        help='Run and monitor 128-mini (8 validators) build')
    parser.add_argument('--run-mini', action='store_true',
                        help='Run and monitor mini (3-part) build')
    parser.add_argument('--history', action='store_true',
                        help='Show compilation history')
    parser.add_argument('--reset', action='store_true',
                        help='Reset dashboard status')

    args = parser.parse_args()

    if args.run_128:
        run_with_monitoring('run_128_split.sh', '128-validator')
    elif args.run_128_mini:
        run_with_monitoring('run_128_mini.sh', '128-mini')
    elif args.run_mini:
        run_with_monitoring('run_mini.sh', 'mini-3part')
    elif args.history:
        show_history()
    elif args.reset:
        if STATUS_FILE.exists():
            STATUS_FILE.unlink()
        if METRICS_FILE.exists():
            METRICS_FILE.unlink()
        print("Dashboard status reset")
    else:
        # Just run the monitoring dashboard
        if not STATUS_FILE.exists():
            init_status('monitoring')
        dashboard = Dashboard()
        dashboard.run()


if __name__ == '__main__':
    main()
