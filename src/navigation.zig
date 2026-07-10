/// Pure navigation functions for grid selection movement.
/// These functions handle index calculations without any UI dependencies.

fn normalizeIndex(current: usize, count: usize) usize {
    if (count == 0) return 0;
    return current % count;
}

/// Move selection right with wrap-around.
pub fn moveSelectionRight(current: usize, count: usize) usize {
    if (count == 0) return 0;
    const normalized = normalizeIndex(current, count);
    return if (normalized == count - 1) 0 else normalized + 1;
}

/// Move selection left with wrap-around.
pub fn moveSelectionLeft(current: usize, count: usize) usize {
    if (count == 0) return 0;
    const normalized = normalizeIndex(current, count);
    return if (normalized == 0) count - 1 else normalized - 1;
}

/// Move selection down by one row (`columns` items), clamped to the last item.
pub fn moveSelectionDown(current: usize, columns: usize, count: usize) usize {
    if (count == 0) return 0;

    const normalized = normalizeIndex(current, count);
    if (columns == 0) return normalized;

    const remaining = count - 1 - normalized;
    return normalized + @min(columns, remaining);
}

/// Move selection up by one row (`columns` items), staying in the top row.
pub fn moveSelectionUp(current: usize, columns: usize) usize {
    if (columns == 0) return current;
    if (current >= columns) return current - columns;
    return current;
}
