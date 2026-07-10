from pathlib import Path

main = Path("src/main.zig")
text = main.read_text()

marker = '''fn installFastSignalExit() void {
    _ = c.signal(c.SIGINT, fastExitFromSignal);
    _ = c.signal(c.SIGTERM, fastExitFromSignal);
}

fn killExistingInstance() !void {
    const my_pid = std.c.getpid();
'''
replacement = '''fn installFastSignalExit() void {
    _ = c.signal(c.SIGINT, fastExitFromSignal);
    _ = c.signal(c.SIGTERM, fastExitFromSignal);
}

fn shouldTerminateExistingFastTab(
    comm: []const u8,
    pid: i32,
    my_pid: i32,
    process_group: i32,
    my_process_group: i32,
) bool {
    if (!std.mem.eql(u8, comm, "fasttab")) return false;
    if (pid == my_pid) return false;

    // When the AppImage is launched through a symlink named `fasttab`, its
    // uruntime wrapper has the same process name. It belongs to this launch's
    // process group and must not be killed by --replace.
    return process_group < 0 or process_group != my_process_group;
}

fn killExistingInstance() !void {
    const my_pid: i32 = @intCast(std.c.getpid());
    const my_process_group: i32 = @intCast(c.getpgrp());
'''
if marker not in text:
    raise SystemExit("main.zig insertion marker not found")
text = text.replace(marker, replacement, 1)

old = '''        if (std.mem.eql(u8, comm, "fasttab")) {
            std.debug.print("Killing existing instance (PID {d})...\\n", .{pid});
            std.posix.kill(pid, std.posix.SIG.TERM) catch |err| {
                std.debug.print("Failed to kill PID {d}: {}\\n", .{ pid, err });
            };
        }
'''
new = '''        const process_group: i32 = @intCast(c.getpgid(pid));
        if (!shouldTerminateExistingFastTab(comm, pid, my_pid, process_group, my_process_group)) continue;

        std.debug.print("Killing existing instance (PID {d})...\\n", .{pid});
        std.posix.kill(pid, std.posix.SIG.TERM) catch |err| {
            std.debug.print("Failed to kill PID {d}: {}\\n", .{ pid, err });
        };
'''
if old not in text:
    raise SystemExit("main.zig replacement block not found")
text = text.replace(old, new, 1)

test_marker = 'test "idle Alt+Tab routes to all windows" {\n'
test_block = '''test "replacement ignores the current AppImage process group" {
    try std.testing.expect(!shouldTerminateExistingFastTab("fasttab", 100, 100, 20, 20));
    try std.testing.expect(!shouldTerminateExistingFastTab("fasttab", 101, 100, 20, 20));
    try std.testing.expect(shouldTerminateExistingFastTab("fasttab", 101, 100, 21, 20));
    try std.testing.expect(shouldTerminateExistingFastTab("fasttab", 101, 100, -1, 20));
    try std.testing.expect(!shouldTerminateExistingFastTab("other", 101, 100, 21, 20));
}

test "idle Alt+Tab routes to all windows" {
'''
if test_marker not in text:
    raise SystemExit("main.zig test marker not found")
main.write_text(text.replace(test_marker, test_block, 1))

Path("VERSION").write_text("1.0.6\n")

desktop = Path("packaging/fasttab.desktop")
text = desktop.read_text()
if "X-AppImage-Version=1.0.5" not in text:
    raise SystemExit("unexpected desktop version")
desktop.write_text(text.replace("X-AppImage-Version=1.0.5", "X-AppImage-Version=1.0.6"))

readme = Path("README.md")
text = readme.read_text().replace("1.0.5", "1.0.6")
old_note = "The AppImage automatically replaces an older running FastTab daemon. Version 1.0.6 keeps the single-window `Win+Tab` behavior and embeds `REUSE_CHECK_DELAY=0` in uruntime, removing the several-second delay after pressing `Ctrl+C` during a foreground AppImage run."
new_note = "The AppImage automatically replaces an older running FastTab daemon. Version 1.0.6 also supports launching through a symlink named `fasttab`; `--replace` no longer mistakes the current AppImage runtime wrapper for an older FastTab daemon."
if old_note not in text:
    raise SystemExit("README release note not found")
readme.write_text(text.replace(old_note, new_note, 1))

ci = Path(".github/workflows/ci.yml")
text = ci.read_text()
marker = "          grep -Fq 'Win+Tab single-window current-workspace switching started' src/main.zig\n"
addition = marker + "          grep -Fq 'fn shouldTerminateExistingFastTab' src/main.zig\n          grep -Fq 'process_group != my_process_group' src/main.zig\n"
if marker not in text:
    raise SystemExit("CI source validation marker not found")
text = text.replace(marker, addition, 1)
text = text.replace(
    'echo "FastTab ${VERSION} removes the AppImage Ctrl+C shutdown delay."',
    'echo "FastTab ${VERSION} fixes AppImage launches through a fasttab symlink."',
)
text = text.replace(
    'echo "The AppImage now embeds REUSE_CHECK_DELAY=0 for uruntime, eliminating the several-second mount-reuse wait after Ctrl+C. The zsync metadata is regenerated after the runtime environment is patched."',
    'echo "The --replace scan now ignores processes in the current launch process group, preventing an AppImage runtime invoked through a symlink named fasttab from killing its own wrapper."',
)
ci.write_text(text)

for path in (
    Path(".github/workflows/patch-appimage-symlink-1.0.6.yml"),
    Path(".github/workflows/apply-symlink-fix.yml"),
    Path(".github/scripts/apply_symlink_fix.py"),
    Path(".github/trigger-symlink-fix"),
):
    path.unlink(missing_ok=True)
